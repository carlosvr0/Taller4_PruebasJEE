param(
    [string]$Service = "content-service",
    [int]$TimeoutSeconds = 120,
    [int]$PollIntervalSeconds = 2,
    [string]$OutputDir = "docs/evidencias"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}

$readinessUrls = @{
    "simulation-service" = "http://localhost:9990/health/ready"
    "content-service" = "http://localhost:9991/health/ready"
    "user-service" = "http://localhost:9992/health/ready"
    "recommendation-service" = "http://localhost:9993/health/ready"
    "presentacion" = "http://localhost:9995/health/ready"
}

if (-not $readinessUrls.ContainsKey($Service)) {
    throw "Servicio no soportado para esta prueba: $Service"
}

$readinessUrl = $readinessUrls[$Service]
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = Join-Path $OutputDir "recuperacion-$Service-$timestamp.csv"
$summaryPath = Join-Path $OutputDir "recuperacion-$Service-resumen-$timestamp.md"

$events = New-Object System.Collections.Generic.List[object]
$testStartedAt = Get-Date

Write-Host "Reiniciando $Service..."
docker compose restart $Service | Out-Host

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$available = $false
$attempt = 0

while ($sw.Elapsed.TotalSeconds -le $TimeoutSeconds -and -not $available) {
    $attempt++
    $checkedAt = Get-Date
    $probeSw = [System.Diagnostics.Stopwatch]::StartNew()
    $statusCode = $null
    $errorMessage = ""

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $readinessUrl -Method GET -TimeoutSec 5
        $probeSw.Stop()
        $statusCode = [int]$response.StatusCode
        $available = @(200, 201, 204) -contains $statusCode
    }
    catch {
        $probeSw.Stop()
        $errorMessage = $_.Exception.Message

        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
    }

    $events.Add([pscustomobject]@{
        Timestamp = $checkedAt.ToString("yyyy-MM-dd HH:mm:ss")
        Service = $Service
        ReadinessUrl = $readinessUrl
        Attempt = $attempt
        ElapsedSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        StatusCode = $statusCode
        ResponseTimeMs = [Math]::Round($probeSw.Elapsed.TotalMilliseconds, 2)
        Available = $available
        Error = $errorMessage
    })

    if (-not $available) {
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

$sw.Stop()
$events | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$recoverySeconds = if ($available) { [Math]::Round($sw.Elapsed.TotalSeconds, 2) } else { "No recuperado en $TimeoutSeconds segundos" }
$result = if ($available) { "Aprobado" } else { "No aprobado" }

$summary = @(
    "# Resumen de prueba de recuperacion",
    "",
    "- Fecha de ejecucion: $($testStartedAt.ToString('yyyy-MM-dd HH:mm:ss'))",
    "- Servicio reiniciado: $Service",
    "- URL readiness: $readinessUrl",
    "- Timeout maximo: $TimeoutSeconds segundos",
    "- Intervalo de sondeo: $PollIntervalSeconds segundos",
    "- Intentos realizados: $attempt",
    "- Tiempo de recuperacion: $recoverySeconds segundos",
    "- Resultado: $result",
    "- Evidencia CSV: $csvPath"
)

$summary | Out-File -FilePath $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "Evidencia generada:"
Write-Host "  $csvPath"
Write-Host "  $summaryPath"
