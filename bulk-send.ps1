<#
.SYNOPSIS
    Envio massivo de XMLs fiscais para a XML Ingest API.

.DESCRIPTION
    Envia todos os arquivos .xml de um diretorio para a API, com paralelismo
    configuravel, relatorio de resultados e organizacao automatica dos arquivos.
    Equivalente PowerShell do bulk-send.sh. Compativel com PowerShell 5.1+.

.EXAMPLE
    .\bulk-send.ps1 emb_abc123... C:\notas -Env prod
    .\bulk-send.ps1 emb_abc123... C:\notas -Env stage -Recursive -Parallel 20 -VerboseOutput
    .\bulk-send.ps1 emb_abc123... C:\notas -Env prod -Organize
    .\bulk-send.ps1 emb_abc123... C:\notas\nota.xml -Env prod
    .\bulk-send.ps1 emb_abc123... C:\notas -Env stage -DryRun
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ApiKey,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$XmlPath,

    [int]$Parallel = 10,
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

$XmlFiles = @($AllXmlFiles | Where-Object { -not $AlreadySentSet.ContainsKey($_.FullName.ToLower()) })
$Skipped = $AllXmlFiles.Count - $XmlFiles.Count
$Total = $XmlFiles.Count
$TotalFound = $AllXmlFiles.Count

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
Write-Host " Paralelo:   $Parallel"
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

# ── Funcao de envio (sequencial, chamada por cada job) ───────────────────
function Send-Xml {
    param([string]$FilePath, [string]$Url, [string]$Key)

    $fname = [System.IO.Path]::GetFileName($FilePath)
    $encoded = [System.Uri]::EscapeDataString($fname)
    $fullUrl = "${Url}?filename=${encoded}"

    $res = @{ Status = "ERRO"; FilePath = $FilePath; HttpCode = 0; Info = "" }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("X-Api-Key", $Key)
        $wc.Headers.Add("Content-Type", "application/xml")
        $responseBytes = $wc.UploadData($fullUrl, "POST", $bytes)
        $body = [System.Text.Encoding]::UTF8.GetString($responseBytes)
        $res.HttpCode = 200
        $res.Status = "OK"
        try { $res.Info = ($body | ConvertFrom-Json).hash } catch { $res.Info = "" }
        $wc.Dispose()
    } catch [System.Net.WebException] {
        $we = $_.Exception
        if ($we.Response) {
            $res.HttpCode = [int]$we.Response.StatusCode
            $sr = New-Object System.IO.StreamReader($we.Response.GetResponseStream())
            $body = $sr.ReadToEnd()
            $sr.Close()
            try {
                $j = $body | ConvertFrom-Json
                if ($j.error) { $res.Info = $j.error }
                elseif ($j.message) { $res.Info = $j.message }
                else { $res.Info = $body }
            } catch { $res.Info = $body }
        } else {
            $res.Info = $we.Message
        }
    } catch {
        $res.Info = $_.Exception.Message
    }
    return $res
}

# ── Envio com paralelismo via runspace pool ──────────────────────────────
Write-Host "Enviando $Total arquivo(s) com $Parallel thread(s)..."
Write-Host ""

$pool = [RunspaceFactory]::CreateRunspacePool(1, $Parallel)
$pool.Open()

$jobs = [System.Collections.ArrayList]::new()

foreach ($file in $XmlFiles) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript({
        param($FilePath, $Url, $Key)
        $fname = [System.IO.Path]::GetFileName($FilePath)
        $encoded = [System.Uri]::EscapeDataString($fname)
        $fullUrl = "${Url}?filename=${encoded}"
        $res = @{ Status = "ERRO"; FilePath = $FilePath; HttpCode = 0; Info = "" }
        try {
            $bytes = [System.IO.File]::ReadAllBytes($FilePath)
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("X-Api-Key", $Key)
            $wc.Headers.Add("Content-Type", "application/xml")
            $responseBytes = $wc.UploadData($fullUrl, "POST", $bytes)
            $body = [System.Text.Encoding]::UTF8.GetString($responseBytes)
            $res.HttpCode = 200
            $res.Status = "OK"
            try { $res.Info = ($body | ConvertFrom-Json).hash } catch { $res.Info = "" }
            $wc.Dispose()
        } catch [System.Net.WebException] {
            $we = $_.Exception
            if ($we.Response) {
                $res.HttpCode = [int]$we.Response.StatusCode
                $sr = New-Object System.IO.StreamReader($we.Response.GetResponseStream())
                $body = $sr.ReadToEnd()
                $sr.Close()
                try {
                    $j = $body | ConvertFrom-Json
                    if ($j.error) { $res.Info = $j.error }
                    elseif ($j.message) { $res.Info = $j.message }
                    else { $res.Info = $body }
                } catch { $res.Info = $body }
            } else {
                $res.Info = $we.Message
            }
        } catch {
            $res.Info = $_.Exception.Message
        }
        return $res
    })
    [void]$ps.AddArgument($file.FullName)
    [void]$ps.AddArgument($ApiUrl)
    [void]$ps.AddArgument($ApiKey)

    $handle = $ps.BeginInvoke()
    [void]$jobs.Add(@{ PS = $ps; Handle = $handle; File = $file })
}

# Collect results
$ResultList = [System.Collections.ArrayList]::new()
$doneCount = 0

foreach ($job in $jobs) {
    $result = $job.PS.EndInvoke($job.Handle)
    $job.PS.Dispose()

    if ($result -and $result.Count -gt 0) {
        $r = $result[0]
    } else {
        $r = @{ Status = "ERRO"; FilePath = $job.File.FullName; HttpCode = 0; Info = "Sem resposta" }
    }

    [void]$ResultList.Add($r)
    $doneCount++

    # Sent-log
    if ($r.Status -eq "OK") {
        Add-Content -Path $SentLog -Value $r.FilePath
    }

    # Progress
    if ($VerboseOutput) {
        $label = if ($r.Status -eq "OK") { "OK   " } else { "ERRO " }
        $info = if ($r.Status -eq "OK") { $r.Info } else { "HTTP $($r.HttpCode): $($r.Info)" }
        Write-Host "  ($doneCount/$Total) $label $($job.File.Name) -> $info"
    } elseif ($Total -ge 20) {
        $step = [Math]::Max(1, [Math]::Floor($Total / 10))
        if (($doneCount % $step) -eq 0) {
            $pct = [Math]::Floor($doneCount * 100 / $Total)
            Write-Host "  Progresso: $doneCount / $Total ($pct%)"
        }
    }
}

$pool.Close()
$pool.Dispose()
Write-Host ""

# ── Contagens ────────────────────────────────────────────────────────────
$OkCount = @($ResultList | Where-Object { $_.Status -eq "OK" }).Count
$ErroCount = @($ResultList | Where-Object { $_.Status -eq "ERRO" }).Count

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
Write-Host "  Sucesso:    $OkCount"
Write-Host "  Erros:      $ErroCount"
Write-Host "  Pulados:    $Skipped (ja enviados anteriormente)"
Write-Host "  Inicio:     $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  Fim:        $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  Duracao:    ${ElapsedMin}m ${ElapsedSec}s"
Write-Host "  Sent-log:   $SentLog"
Write-Host ""

if ($ErroCount -gt 0) {
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
    "Paralelo:    $Parallel",
    "Organize:    $Organize",
    "Sent-log:    $SentLog",
    "Inicio:      $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))",
    "Fim:         $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))",
    "Duracao:     ${ElapsedMin}m ${ElapsedSec}s",
    "Enviados:    $Total",
    "Pulados:     $Skipped",
    "Sucesso:     $OkCount",
    "Erros:       $ErroCount",
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

if ($ErroCount -gt 0) { exit 1 }
