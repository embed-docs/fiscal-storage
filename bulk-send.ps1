<#
.SYNOPSIS
    Envio massivo de XMLs fiscais para a XML Ingest API.

.DESCRIPTION
    Envia todos os arquivos .xml de um diretorio para a API, com paralelismo
    configuravel, relatorio de resultados e organizacao automatica dos arquivos.
    Equivalente PowerShell do bulk-send.sh.

.PARAMETER ApiKey
    Chave de autenticacao (formato emb_...).

.PARAMETER XmlPath
    Diretorio contendo os XMLs a enviar.

.PARAMETER Parallel
    Numero de envios simultaneos (default: 10).

.PARAMETER Env
    Ambiente alvo: dev | prod (default: dev).

.PARAMETER Recursive
    Varre subdiretorios recursivamente buscando XMLs.

.PARAMETER Organize
    Move XMLs para subpastas processed/ e errors/ apos envio.

.PARAMETER SentLog
    Caminho do arquivo de controle de enviados (default: <XmlPath>\.bulk-send-sent.log).

.PARAMETER DryRun
    Apenas lista os arquivos sem enviar.

.PARAMETER Verbose
    Mostra detalhes de cada envio.

.EXAMPLE
    .\scripts\bulk-send.ps1 emb_abc123... C:\notas
    .\scripts\bulk-send.ps1 emb_abc123... C:\notas -Recursive
    .\scripts\bulk-send.ps1 emb_abc123... C:\notas -Recursive -Parallel 20
    .\scripts\bulk-send.ps1 emb_abc123... C:\notas -Env prod
    .\scripts\bulk-send.ps1 emb_abc123... C:\notas -Organize
    .\scripts\bulk-send.ps1 emb_abc123... C:\notas -Recursive -Parallel 20 -Verbose
    .\scripts\bulk-send.ps1 emb_abc123... C:\notas -SentLog C:\temp\controle.log
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ApiKey,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$XmlPath,

    [int]$Parallel = 10,
    [ValidateSet("dev", "prod")]
    [string]$Env = "dev",
    [switch]$Recursive,
    [switch]$Organize,
    [string]$SentLog,
    [switch]$DryRun,
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

# ── URLs por ambiente ────────────────────────────────────────────────────
$ApiUrls = @{
    "dev"  = "https://storage-api.embed.zone/v1/ingest"
    "prod" = "https://storage-api.embed.it/v1/ingest"
}

# ── Validacoes ───────────────────────────────────────────────────────────
if (-not $ApiKey.StartsWith("emb_")) {
    Write-Host "ERRO: API key deve comecar com 'emb_'" -ForegroundColor Red
    exit 1
}

$XmlPath = $XmlPath.TrimEnd('\', '/')
if (-not (Test-Path $XmlPath -PathType Container)) {
    Write-Host "ERRO: Diretorio nao encontrado: $XmlPath" -ForegroundColor Red
    exit 1
}

$ApiUrl = $ApiUrls[$Env]
if (-not $ApiUrl) {
    Write-Host "ERRO: URL para ambiente '$Env' nao configurada." -ForegroundColor Red
    exit 1
}

# ── Paths de organizacao ─────────────────────────────────────────────────
$ProcessedDir = Join-Path $XmlPath "processed"
$ErrorsDir = Join-Path $XmlPath "errors"
$LogsDir = Join-Path $XmlPath "logs"

# ── Sent-log (controle de retomada) ──────────────────────────────────────
if (-not $SentLog) {
    $SentLog = Join-Path $XmlPath ".bulk-send-sent.log"
}

$AlreadySent = @()
if (Test-Path $SentLog) {
    $AlreadySent = @(Get-Content $SentLog -ErrorAction SilentlyContinue)
    if ($AlreadySent.Count -gt 0) {
        Write-Host "Retomando: $($AlreadySent.Count) arquivo(s) ja enviado(s) serao pulados."
        Write-Host "  (sent-log: $SentLog)"
        Write-Host ""
    }
}
$AlreadySentSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$AlreadySent,
    [System.StringComparer]::OrdinalIgnoreCase
)

# ── Listar XMLs ──────────────────────────────────────────────────────────
$findParams = @{ Path = $XmlPath; Filter = "*.xml" }
if ($Recursive) {
    $findParams["Recurse"] = $true
}

$AllXmlFiles = @(Get-ChildItem @findParams -File |
    Where-Object {
        $_.FullName -notmatch '\\(processed|errors|logs)\\' -and
        $_.FullName -notmatch '/(processed|errors|logs)/'
    } |
    Sort-Object FullName)

$XmlFiles = @($AllXmlFiles | Where-Object { -not $AlreadySentSet.Contains($_.FullName) })
$Skipped = $AllXmlFiles.Count - $XmlFiles.Count
$Total = $XmlFiles.Count
$TotalFound = $AllXmlFiles.Count

if ($TotalFound -eq 0) {
    Write-Host "Nenhum arquivo .xml encontrado em: $XmlPath"
    if ($Recursive) {
        Write-Host "(Busca recursiva ativada. Subpastas processed/, errors/ e logs/ sao ignoradas)"
    } else {
        Write-Host "(Nota: subpastas nao foram varridas. Use -Recursive para busca em subdiretorios)"
    }
    exit 0
}

if ($Total -eq 0) {
    Write-Host "Todos os $TotalFound arquivo(s) .xml ja foram enviados anteriormente."
    Write-Host "  (sent-log: $SentLog)"
    Write-Host ""
    Write-Host "Para reenviar, remova ou renomeie o arquivo de controle."
    exit 0
}

# ── Banner ───────────────────────────────────────────────────────────────
$StartTime = Get-Date

Write-Host "============================================"
Write-Host " Envio Massivo — XML Ingest API"
Write-Host " Ambiente:   $Env"
Write-Host " Endpoint:   $ApiUrl"
Write-Host " Diretorio:  $XmlPath"
Write-Host " Recursivo:  $(if ($Recursive) { 'sim' } else { 'nao' })"
Write-Host " Arquivos:   $Total (de $TotalFound encontrados, $Skipped ja enviados)"
Write-Host " Paralelo:   $Parallel"
Write-Host " Organizar:  $(if ($Organize) { 'sim (processed/, errors/, logs/)' } else { 'nao' })"
Write-Host " Sent-log:   $SentLog"
Write-Host " Inicio:     $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "============================================"
Write-Host ""

# ── Dry-run ──────────────────────────────────────────────────────────────
if ($DryRun) {
    Write-Host "[DRY-RUN] Arquivos que seriam enviados ($Total):"
    foreach ($f in $XmlFiles) {
        Write-Host "  $($f.FullName)"
    }
    Write-Host ""
    if ($Skipped -gt 0) {
        Write-Host "[DRY-RUN] Arquivos ja enviados (pulados): $Skipped"
    }
    if ($Organize) {
        Write-Host "[DRY-RUN] Com -Organize, arquivos seriam movidos para:"
        Write-Host "  Sucesso: $ProcessedDir\"
        Write-Host "  Erro:    $ErrorsDir\"
        Write-Host "  Log:     $LogsDir\"
    }
    Write-Host ""
    Write-Host "[DRY-RUN] Nenhum envio realizado."
    exit 0
}

# ── Funcao de envio ──────────────────────────────────────────────────────
$SendXml = {
    param($XmlFile, $Index, $Total, $ApiUrl, $ApiKey, $VerboseOutput)

    $filename = [System.IO.Path]::GetFileName($XmlFile)
    $encodedName = [System.Uri]::EscapeDataString($filename)
    $url = "${ApiUrl}?filename=${encodedName}"

    $result = @{
        Status   = "ERRO"
        FilePath = $XmlFile
        HttpCode = 0
        Info     = ""
    }

    try {
        $xmlBytes = [System.IO.File]::ReadAllBytes($XmlFile)
        $webClient = [System.Net.Http.HttpClient]::new()
        $webClient.Timeout = [TimeSpan]::FromSeconds(30)
        $webClient.DefaultRequestHeaders.Add("X-Api-Key", $ApiKey)

        $content = [System.Net.Http.ByteArrayContent]::new($xmlBytes)
        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("application/xml")

        $response = $webClient.PostAsync($url, $content).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $result.HttpCode = [int]$response.StatusCode

        if ($response.IsSuccessStatusCode) {
            $result.Status = "OK"
            try {
                $json = $body | ConvertFrom-Json
                $result.Info = $json.hash
            } catch {
                $result.Info = ""
            }
        } else {
            try {
                $json = $body | ConvertFrom-Json
                $result.Info = if ($json.error) { $json.error } elseif ($json.message) { $json.message } else { $body }
            } catch {
                $result.Info = $body
            }
        }

        $webClient.Dispose()
    } catch {
        $result.HttpCode = 0
        $result.Info = $_.Exception.Message
    }

    return $result
}

# ── Envio em paralelo ────────────────────────────────────────────────────
Write-Host "Enviando $Total arquivo(s) com $Parallel thread(s)..."
Write-Host ""

$Results = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
$SentLogLock = [System.Object]::new()
$ProgressCount = [ref]0

$XmlFiles | ForEach-Object -ThrottleLimit $Parallel -Parallel {
    $result = & $using:SendXml $_.FullName $null $using:Total $using:ApiUrl $using:ApiKey $using:VerboseOutput

    ($using:Results).Add($result)

    # Sent-log
    if ($result.Status -eq "OK") {
        [System.Threading.Monitor]::Enter($using:SentLogLock)
        try {
            Add-Content -Path $using:SentLog -Value $_.FullName -NoNewline:$false
        } finally {
            [System.Threading.Monitor]::Exit($using:SentLogLock)
        }
    }

    # Progress
    $count = [System.Threading.Interlocked]::Increment($using:ProgressCount)
    if ($using:VerboseOutput) {
        $statusLabel = if ($result.Status -eq "OK") { "OK   " } else { "ERRO " }
        $info = if ($result.Status -eq "OK") { $result.Info } else { "HTTP $($result.HttpCode): $($result.Info)" }
        Write-Host "  [$count/$($using:Total)] $statusLabel $($_.Name) -> $info"
    } elseif ($using:Total -ge 50 -and ($count % [Math]::Max(1, [Math]::Floor($using:Total / 10)) -eq 0)) {
        $pct = [Math]::Floor($count * 100 / $using:Total)
        Write-Host "  Progresso: $count / $($using:Total) ($pct%)"
    }
}

Write-Host ""

# ── Timestamp de fim ─────────────────────────────────────────────────────
$EndTime = Get-Date
$Elapsed = $EndTime - $StartTime

# ── Contagens ────────────────────────────────────────────────────────────
$ResultList = @($Results.ToArray())
$OkCount = @($ResultList | Where-Object { $_.Status -eq "OK" }).Count
$ErroCount = @($ResultList | Where-Object { $_.Status -eq "ERRO" }).Count

# ── Organizar arquivos ───────────────────────────────────────────────────
if ($Organize) {
    $MovedOk = 0
    $MovedErr = 0

    $okResults = @($ResultList | Where-Object { $_.Status -eq "OK" })
    if ($okResults.Count -gt 0) {
        New-Item -ItemType Directory -Path $ProcessedDir -Force | Out-Null
        foreach ($r in $okResults) {
            if (Test-Path $r.FilePath) {
                Move-Item -Path $r.FilePath -Destination $ProcessedDir -Force
                $MovedOk++
            }
        }
    }

    $errResults = @($ResultList | Where-Object { $_.Status -eq "ERRO" })
    if ($errResults.Count -gt 0) {
        New-Item -ItemType Directory -Path $ErrorsDir -Force | Out-Null
        foreach ($r in $errResults) {
            if (Test-Path $r.FilePath) {
                Move-Item -Path $r.FilePath -Destination $ErrorsDir -Force
                $MovedErr++
            }
        }
    }

    Write-Host "Arquivos organizados:"
    if ($MovedOk -gt 0) { Write-Host "  $MovedOk movido(s) para $ProcessedDir\" }
    if ($MovedErr -gt 0) { Write-Host "  $MovedErr movido(s) para $ErrorsDir\" }
    Write-Host ""
}

# ── Relatorio ────────────────────────────────────────────────────────────
Write-Host "============================================"
Write-Host " Resultado"
Write-Host "============================================"
Write-Host "  Enviados:   $Total"
Write-Host "  Sucesso:    $OkCount"
Write-Host "  Erros:      $ErroCount"
Write-Host "  Pulados:    $Skipped (ja enviados anteriormente)"
Write-Host "  Inicio:     $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  Fim:        $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  Duracao:    $([Math]::Floor($Elapsed.TotalMinutes))m $($Elapsed.Seconds)s"
Write-Host "  Sent-log:   $SentLog"
Write-Host ""

if ($ErroCount -gt 0) {
    Write-Host "Arquivos com erro:" -ForegroundColor Yellow
    foreach ($r in @($ResultList | Where-Object { $_.Status -eq "ERRO" })) {
        $fname = [System.IO.Path]::GetFileName($r.FilePath)
        Write-Host "  $fname — HTTP $($r.HttpCode): $($r.Info)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ── Salvar log ───────────────────────────────────────────────────────────
$LogFilename = "bulk-send_$((Get-Date).ToString('yyyyMMdd_HHmmss')).log"

if ($Organize) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
    $LogFile = Join-Path $LogsDir $LogFilename
} else {
    $LogFile = Join-Path ([System.IO.Path]::GetTempPath()) $LogFilename
}

$logContent = @"
============================================
 Relatorio — bulk-send.ps1
============================================
Ambiente:    $Env
Endpoint:    $ApiUrl
Diretorio:   $XmlPath
Recursivo:   $Recursive
Paralelo:    $Parallel
Organize:    $Organize
Sent-log:    $SentLog
Inicio:      $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
Fim:         $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))
Duracao:     $([Math]::Floor($Elapsed.TotalMinutes))m $($Elapsed.Seconds)s
Enviados:    $Total
Pulados:     $Skipped
Sucesso:     $OkCount
Erros:       $ErroCount
============================================

DETALHES (status|arquivo|http_code|info):
--------------------------------------------
"@

foreach ($r in $ResultList) {
    $logContent += "`n$($r.Status)|$($r.FilePath)|$($r.HttpCode)|$($r.Info)"
}

Set-Content -Path $LogFile -Value $logContent -Encoding UTF8

Write-Host "Relatorio salvo em: $LogFile"

if ($ErroCount -gt 0) {
    exit 1
}
