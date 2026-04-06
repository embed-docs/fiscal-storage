<#
.SYNOPSIS
    Envio massivo de XMLs fiscais para a XML Ingest API.

.DESCRIPTION
    Envia todos os arquivos .xml de um diretorio para a API, com paralelismo
    configuravel, relatorio de resultados e organizacao automatica dos arquivos.
    Equivalente PowerShell do bulk-send.sh. Compativel com PowerShell 5.1+.

.EXAMPLE
    .\bulk-send.ps1 emb_abc123... C:\notas -Env prod
    .\bulk-send.ps1 emb_abc123... C:\notas -Env stage -Recursive -Parallel auto -VerboseOutput
    .\bulk-send.ps1 emb_abc123... C:\notas -Env prod -Parallel 20 -Organize
    .\bulk-send.ps1 emb_abc123... C:\notas\nota.xml -Env prod
    .\bulk-send.ps1 emb_abc123... C:\notas -Env stage -DryRun
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ApiKey,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$XmlPath,

    [string]$Parallel = "auto",
    [Parameter(Mandatory = $true)]
    [ValidateSet("stage", "prod")]
    [string]$Env,
    [switch]$Recursive,
    [switch]$Organize,
    [string]$SentLog,
    [switch]$DryRun,
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

# ── URLs por ambiente ────────────────────────────────────────────────────
$ApiUrls = @{
    "stage" = "https://storage-api.embed.zone/v1/ingest"
    "prod"  = "https://storage-api.embed.it/v1/ingest"
}

# ── Validacoes ───────────────────────────────────────────────────────────
if (-not $ApiKey.StartsWith("emb_")) {
    Write-Host "ERRO: API key deve comecar com 'emb_'" -ForegroundColor Red
    exit 1
}

$XmlPath = $XmlPath.TrimEnd('\', '/')
$SingleFile = $false
if (Test-Path $XmlPath -PathType Leaf) {
    $SingleFile = $true
} elseif (-not (Test-Path $XmlPath -PathType Container)) {
    Write-Host "ERRO: Arquivo ou diretorio nao encontrado: $XmlPath" -ForegroundColor Red
    exit 1
}

$ApiUrl = $ApiUrls[$Env]

# ── Auto-deteccao de paralelismo ─────────────────────────────────────────
if ($Parallel -eq "auto") {
    $cpuCores = 0
    $memAvailMB = 0
    try {
        $cpuCores = (Get-WmiObject Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    } catch {
        try { $cpuCores = [System.Environment]::ProcessorCount } catch { $cpuCores = 2 }
    }
    try {
        $os = Get-WmiObject Win32_OperatingSystem
        $memAvailMB = [Math]::Floor([long]$os.FreePhysicalMemory / 1024)
    } catch {
        $memAvailMB = 1024
    }

    # Cada thread usa ~20MB (bytes do XML + objetos .NET + HTTP buffers)
    $maxByMem = [Math]::Max(2, [Math]::Floor($memAvailMB / 30))
    # Limitar por CPU: 2 threads por core (IO-bound, nao CPU-bound)
    $maxByCpu = [Math]::Max(2, $cpuCores * 2)
    # Teto maximo de 50 threads
    $ParallelInt = [Math]::Min(50, [Math]::Min($maxByCpu, $maxByMem))

    Write-Host "Auto-deteccao de paralelismo:"
    Write-Host "  CPU cores:       $cpuCores"
    Write-Host "  Memoria livre:   ${memAvailMB} MB"
    Write-Host "  Max por CPU:     $maxByCpu"
    Write-Host "  Max por memoria: $maxByMem"
    Write-Host "  Paralelo final:  $ParallelInt thread(s)"
    Write-Host ""
} else {
    $ParallelInt = [int]$Parallel
    if ($ParallelInt -lt 1) { $ParallelInt = 1 }
}

# ── Configuracao de rede (.NET) ──────────────────────────────────────────
# TLS 1.2 obrigatorio (Windows antigos usam TLS 1.0 por padrao)
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
} catch {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}
# Limite de conexoes simultaneas por host (padrao .NET = 2)
[System.Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max($ParallelInt * 2, 20)
# Desabilitar Expect: 100-Continue (causa delay de 350ms em alguns servidores)
[System.Net.ServicePointManager]::Expect100Continue = $false
# Keepalive no pool de conexoes
[System.Net.ServicePointManager]::MaxServicePointIdleTime = 60000

# ── Paths de organizacao ─────────────────────────────────────────────────
$BaseDir = if ($SingleFile) { Split-Path $XmlPath -Parent } else { $XmlPath }
$ProcessedDir = Join-Path $BaseDir "processed"
$ErrorsDir = Join-Path $BaseDir "errors"
$LogsDir = Join-Path $BaseDir "logs"

# ── Sent-log ─────────────────────────────────────────────────────────────
if (-not $SentLog) {
    $SentLog = Join-Path $BaseDir ".bulk-send-sent.log"
}

$AlreadySentSet = @{}
if (Test-Path $SentLog) {
    Get-Content $SentLog -ErrorAction SilentlyContinue | ForEach-Object {
        $AlreadySentSet[$_.ToLower()] = $true
    }
    if ($AlreadySentSet.Count -gt 0) {
        Write-Host "Retomando: $($AlreadySentSet.Count) arquivo(s) ja enviado(s) serao pulados."
        Write-Host "  (sent-log: $SentLog)"
        Write-Host ""
    }
}

# ── Listar XMLs ──────────────────────────────────────────────────────────
Write-Host "Listando arquivos XML..." -NoNewline
if ($SingleFile) {
    $AllXmlFiles = @(Get-Item $XmlPath)
} else {
    $findParams = @{ Path = $XmlPath; Filter = "*.xml" }
    if ($Recursive) { $findParams["Recurse"] = $true }
    $AllXmlFiles = @(Get-ChildItem @findParams -File |
        Where-Object {
            $_.FullName -notmatch '\\(processed|errors|logs)\\'
        } |
        Sort-Object FullName)
}
Write-Host " $($AllXmlFiles.Count) encontrado(s)"

$XmlFiles = @($AllXmlFiles | Where-Object { -not $AlreadySentSet.ContainsKey($_.FullName.ToLower()) })
$Skipped = $AllXmlFiles.Count - $XmlFiles.Count
$Total = $XmlFiles.Count
$TotalFound = $AllXmlFiles.Count

# Liberar lista completa da memoria
$AllXmlFiles = $null
[System.GC]::Collect()

if ($TotalFound -eq 0) {
    Write-Host "Nenhum arquivo .xml encontrado em: $XmlPath"
    exit 0
}
if ($Total -eq 0) {
    Write-Host "Todos os $TotalFound arquivo(s) ja foram enviados. Para reenviar, remova: $SentLog"
    exit 0
}

# ── Banner ───────────────────────────────────────────────────────────────
$StartTime = Get-Date
Write-Host "============================================"
Write-Host " Envio Massivo - XML Ingest API"
Write-Host " Ambiente:   $Env"
Write-Host " Endpoint:   $ApiUrl"
Write-Host " Diretorio:  $XmlPath"
Write-Host " Recursivo:  $(if ($Recursive) {'sim'} else {'nao'})"
Write-Host " Arquivos:   $Total (de $TotalFound encontrados, $Skipped ja enviados)"
Write-Host " Paralelo:   $ParallelInt $(if ($Parallel -eq 'auto') {'(auto)'} else {''})"
Write-Host " Organizar:  $(if ($Organize) {'sim'} else {'nao'})"
Write-Host " Sent-log:   $SentLog"
Write-Host " Inicio:     $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "============================================"
Write-Host ""

if ($DryRun) {
    Write-Host "(DRY-RUN) Arquivos que seriam enviados ($Total):"
    foreach ($f in $XmlFiles) { Write-Host "  $($f.FullName)" }
    Write-Host ""
    Write-Host "(DRY-RUN) Nenhum envio realizado."
    exit 0
}

# ── Script block para envio (executado dentro do runspace) ───────────────
$SendScript = {
    param($FilePath, $Url, $Key)

    $fname = [System.IO.Path]::GetFileName($FilePath)
    $encoded = [System.Uri]::EscapeDataString($fname)
    $fullUrl = "${Url}?filename=${encoded}"
    $res = @{ Status = "ERRO"; FilePath = $FilePath; HttpCode = 0; Info = "" }

    $maxRetries = 3
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            # Ler arquivo com FileShare.ReadWrite (evita lock se outro processo usa o arquivo)
            $fs = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $bytes = New-Object byte[] $fs.Length
            [void]$fs.Read($bytes, 0, $fs.Length)
            $fs.Close()
            $fs.Dispose()

            $req = [System.Net.HttpWebRequest]::Create($fullUrl)
            $req.Method = "POST"
            $req.ContentType = "application/xml"
            $req.ContentLength = $bytes.Length
            $req.Headers.Add("X-Api-Key", $Key)
            $req.Timeout = 30000            # 30s para conectar
            $req.ReadWriteTimeout = 30000   # 30s para ler resposta
            $req.KeepAlive = $true
            $req.AllowAutoRedirect = $false
            $req.ServicePoint.Expect100Continue = $false

            $stream = $req.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $stream.Close()
            $stream.Dispose()
            $bytes = $null  # liberar memoria

            $resp = $req.GetResponse()
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Close()
            $reader.Dispose()
            $resp.Close()

            $res.HttpCode = [int]$resp.StatusCode
            $res.Status = "OK"
            try { $res.Info = ($body | ConvertFrom-Json).hash } catch { $res.Info = "" }
            break  # sucesso
        } catch [System.Net.WebException] {
            $we = $_.Exception
            if ($we.Response) {
                $res.HttpCode = [int]$we.Response.StatusCode
                try {
                    $sr = New-Object System.IO.StreamReader($we.Response.GetResponseStream())
                    $body = $sr.ReadToEnd()
                    $sr.Close()
                    $sr.Dispose()
                    $we.Response.Close()
                    $j = $body | ConvertFrom-Json
                    if ($j.error) { $res.Info = $j.error }
                    elseif ($j.message) { $res.Info = $j.message }
                    else { $res.Info = $body }
                } catch {
                    $res.Info = $we.Message
                }
                # Erro HTTP (400, 401, 500) — nao retry, erro real
                break
            } else {
                # Timeout, rede, DNS — retry com backoff
                $res.Info = "Tentativa $attempt/$maxRetries - $($we.Status): $($we.Message)"
                if ($attempt -lt $maxRetries) {
                    Start-Sleep -Milliseconds (1000 * $attempt * $attempt)  # 1s, 4s, 9s
                }
            }
        } catch {
            $res.Info = "Tentativa $attempt/$maxRetries - $($_.Exception.Message)"
            if ($attempt -lt $maxRetries) {
                Start-Sleep -Milliseconds (1000 * $attempt * $attempt)
            }
        }
    }
    return $res
}

# ── Envio em batches com runspace pool ──────────────────────────────────
Write-Host "Enviando $Total arquivo(s) com $ParallelInt thread(s)..."
Write-Host ""

$ResultList = [System.Collections.ArrayList]::new()
$doneCount = 0
$okCount = 0
$errCount = 0
$batchSize = [Math]::Min($ParallelInt * 3, 100)  # batches moderados

# Buffer para sent-log (flush a cada batch em vez de a cada arquivo)
$sentLogBuffer = [System.Collections.ArrayList]::new()

for ($batchStart = 0; $batchStart -lt $Total; $batchStart += $batchSize) {
    $batchEnd = [Math]::Min($batchStart + $batchSize, $Total) - 1
    $batchFiles = $XmlFiles[$batchStart..$batchEnd]

    $pool = [RunspaceFactory]::CreateRunspacePool(1, $ParallelInt)
    $pool.Open()
    $jobs = [System.Collections.ArrayList]::new()

    foreach ($file in $batchFiles) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($SendScript)
        [void]$ps.AddArgument($file.FullName)
        [void]$ps.AddArgument($ApiUrl)
        [void]$ps.AddArgument($ApiKey)

        $handle = $ps.BeginInvoke()
        [void]$jobs.Add(@{ PS = $ps; Handle = $handle; File = $file })
    }

    # Coletar resultados do batch
    foreach ($job in $jobs) {
        try {
            # Timeout de 90s para job completar (30s request + retries + margem)
            if (-not $job.Handle.AsyncWaitHandle.WaitOne(90000)) {
                $job.PS.Stop()
                $r = @{ Status = "ERRO"; FilePath = $job.File.FullName; HttpCode = 0; Info = "Timeout total (90s)" }
            } else {
                $result = $job.PS.EndInvoke($job.Handle)
                if ($result -and $result.Count -gt 0) {
                    $r = $result[0]
                } else {
                    $r = @{ Status = "ERRO"; FilePath = $job.File.FullName; HttpCode = 0; Info = "Sem resposta do runspace" }
                }
            }
        } catch {
            $r = @{ Status = "ERRO"; FilePath = $job.File.FullName; HttpCode = 0; Info = $_.Exception.Message }
        } finally {
            $job.Handle.AsyncWaitHandle.Close()
            $job.PS.Dispose()
        }

        [void]$ResultList.Add($r)
        $doneCount++

        if ($r.Status -eq "OK") {
            $okCount++
            [void]$sentLogBuffer.Add($r.FilePath)
        } else {
            $errCount++
        }

        # Progress
        if ($VerboseOutput) {
            $label = if ($r.Status -eq "OK") { "OK   " } else { "ERRO " }
            $info = if ($r.Status -eq "OK") { $r.Info } else { "HTTP $($r.HttpCode): $($r.Info)" }
            Write-Host "  ($doneCount/$Total) $label $($job.File.Name) -> $info"
        } elseif ($Total -ge 20 -and ($doneCount % [Math]::Max(1, [Math]::Floor($Total / 20)) -eq 0 -or $doneCount -eq $Total)) {
            $pct = [Math]::Floor($doneCount * 100 / $Total)
            $elapsed = (Get-Date) - $StartTime
            $rate = if ($elapsed.TotalSeconds -gt 0) { [Math]::Round($doneCount / $elapsed.TotalSeconds, 1) } else { 0 }
            Write-Host "  Progresso: $doneCount / $Total ($pct%) - $rate docs/s - OK: $okCount Erros: $errCount"
        }
    }

    # Flush sent-log buffer a cada batch
    if ($sentLogBuffer.Count -gt 0) {
        $sentLogBuffer | Out-File -FilePath $SentLog -Append -Encoding UTF8
        $sentLogBuffer.Clear()
    }

    # Liberar recursos do batch
    $pool.Close()
    $pool.Dispose()
    $jobs.Clear()

    # GC a cada 10 batches para evitar acumulo de memoria
    if (($batchStart / $batchSize) % 10 -eq 0) {
        [System.GC]::Collect()
    }
}

Write-Host ""

# ── Organizar arquivos ───────────────────────────────────────────────────
if ($Organize) {
    $MovedOk = 0; $MovedErr = 0

    foreach ($r in $ResultList) {
        if ($r.Status -eq "OK" -and (Test-Path $r.FilePath)) {
            New-Item -ItemType Directory -Path $ProcessedDir -Force -ErrorAction SilentlyContinue | Out-Null
            Move-Item -Path $r.FilePath -Destination $ProcessedDir -Force
            $MovedOk++
        } elseif ($r.Status -eq "ERRO" -and (Test-Path $r.FilePath)) {
            New-Item -ItemType Directory -Path $ErrorsDir -Force -ErrorAction SilentlyContinue | Out-Null
            Move-Item -Path $r.FilePath -Destination $ErrorsDir -Force
            $MovedErr++
        }
    }

    Write-Host "Arquivos organizados:"
    if ($MovedOk -gt 0) { Write-Host "  $MovedOk movido(s) para $ProcessedDir" }
    if ($MovedErr -gt 0) { Write-Host "  $MovedErr movido(s) para $ErrorsDir" }
    Write-Host ""
}

# ── Relatorio ────────────────────────────────────────────────────────────
$EndTime = Get-Date
$Elapsed = $EndTime - $StartTime
$ElapsedMin = [Math]::Floor($Elapsed.TotalMinutes)
$ElapsedSec = $Elapsed.Seconds

Write-Host "============================================"
Write-Host " Resultado"
Write-Host "============================================"
Write-Host "  Enviados:   $Total"
Write-Host "  Sucesso:    $okCount"
Write-Host "  Erros:      $errCount"
Write-Host "  Pulados:    $Skipped (ja enviados anteriormente)"
Write-Host "  Inicio:     $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  Fim:        $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  Duracao:    ${ElapsedMin}m ${ElapsedSec}s"
Write-Host "  Sent-log:   $SentLog"
Write-Host ""

if ($errCount -gt 0) {
    Write-Host "Arquivos com erro:" -ForegroundColor Yellow
    foreach ($r in @($ResultList | Where-Object { $_.Status -eq "ERRO" })) {
        $fname = [System.IO.Path]::GetFileName($r.FilePath)
        Write-Host "  $fname - HTTP $($r.HttpCode): $($r.Info)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ── Salvar log ───────────────────────────────────────────────────────────
$LogFilename = "bulk-send_$((Get-Date).ToString('yyyyMMdd_HHmmss')).log"
if ($Organize) {
    New-Item -ItemType Directory -Path $LogsDir -Force -ErrorAction SilentlyContinue | Out-Null
    $LogFile = Join-Path $LogsDir $LogFilename
} else {
    $LogFile = Join-Path ([System.IO.Path]::GetTempPath()) $LogFilename
}

$logLines = @(
    "============================================",
    " Relatorio - bulk-send.ps1",
    "============================================",
    "Ambiente:    $Env",
    "Endpoint:    $ApiUrl",
    "Diretorio:   $XmlPath",
    "Recursivo:   $Recursive",
    "Paralelo:    $ParallelInt",
    "Organize:    $Organize",
    "Sent-log:    $SentLog",
    "Inicio:      $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))",
    "Fim:         $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))",
    "Duracao:     ${ElapsedMin}m ${ElapsedSec}s",
    "Enviados:    $Total",
    "Pulados:     $Skipped",
    "Sucesso:     $okCount",
    "Erros:       $errCount",
    "============================================",
    "",
    "DETALHES (status|arquivo|http_code|info):",
    "--------------------------------------------"
)
foreach ($r in $ResultList) {
    $logLines += "$($r.Status)|$($r.FilePath)|$($r.HttpCode)|$($r.Info)"
}
$logLines | Set-Content -Path $LogFile -Encoding UTF8

Write-Host "Relatorio salvo em: $LogFile"

if ($errCount -gt 0) { exit 1 }
