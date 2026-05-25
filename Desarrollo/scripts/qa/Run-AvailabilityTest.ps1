param(
    [int]$Iterations = 12,
    [int]$IntervalSeconds = 5,
    [int]$TimeoutSeconds = 5,
    [string]$OutputDir = "docs/evidencias"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = Join-Path $OutputDir "disponibilidad-$timestamp.csv"
$summaryPath = Join-Path $OutputDir "disponibilidad-resumen-$timestamp.md"
$composePath = Join-Path $OutputDir "docker-compose-ps-$timestamp.txt"

$successCodes = @(200, 201, 204)
$probes = @(
    [pscustomobject]@{ Component = "Presentacion"; Service = "presentacion"; Method = "GET"; Url = "http://localhost:8085"; SuccessCodes = $successCodes; Type = "Funcional" },
    [pscustomobject]@{ Component = "Contenido"; Service = "content-service"; Method = "GET"; Url = "http://localhost:8081/api/courses/1"; SuccessCodes = $successCodes; Type = "Funcional" },
    [pscustomobject]@{ Component = "Usuarios"; Service = "user-service"; Method = "GET"; Url = "http://localhost:8082/api/enrollments/1"; SuccessCodes = $successCodes; Type = "Funcional" },
    [pscustomobject]@{ Component = "Recomendaciones"; Service = "recommendation-service"; Method = "GET"; Url = "http://localhost:8083/api/recommendations/user/1"; SuccessCodes = $successCodes; Type = "Funcional" },
    [pscustomobject]@{ Component = "Simulacion"; Service = "simulation-service"; Method = "GET"; Url = "http://localhost:9990/health/ready"; SuccessCodes = $successCodes; Type = "Tecnica" },
    [pscustomobject]@{ Component = "Contenido readiness"; Service = "content-service"; Method = "GET"; Url = "http://localhost:9991/health/ready"; SuccessCodes = $successCodes; Type = "Tecnica" },
    [pscustomobject]@{ Component = "Usuarios readiness"; Service = "user-service"; Method = "GET"; Url = "http://localhost:9992/health/ready"; SuccessCodes = $successCodes; Type = "Tecnica" },
    [pscustomobject]@{ Component = "Recomendaciones readiness"; Service = "recommendation-service"; Method = "GET"; Url = "http://localhost:9993/health/ready"; SuccessCodes = $successCodes; Type = "Tecnica" },
    [pscustomobject]@{ Component = "Presentacion readiness"; Service = "presentacion"; Method = "GET"; Url = "http://localhost:9995/health/ready"; SuccessCodes = $successCodes; Type = "Tecnica" }
)

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if (-not $Values -or $Values.Count -eq 0) {
        return 0
    }

    $sorted = $Values | Sort-Object
    $index = [Math]::Ceiling(($Percentile / 100) * $sorted.Count) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Count) { $index = $sorted.Count - 1 }
    return [Math]::Round([double]$sorted[$index], 2)
}

function Invoke-Probe {
    param(
        [pscustomobject]$Probe,
        [int]$Iteration,
        [int]$TimeoutSeconds
    )

    $startedAt = Get-Date
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $statusCode = $null
    $errorMessage = ""
    $available = $false

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Probe.Url -Method $Probe.Method -TimeoutSec $TimeoutSeconds
        $sw.Stop()
        $statusCode = [int]$response.StatusCode
        $available = $Probe.SuccessCodes -contains $statusCode
    }
    catch {
        $sw.Stop()
        $errorMessage = $_.Exception.Message

        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
    }

    [pscustomobject]@{
        Timestamp = $startedAt.ToString("yyyy-MM-dd HH:mm:ss")
        Iteration = $Iteration
        Type = $Probe.Type
        Component = $Probe.Component
        Service = $Probe.Service
        Method = $Probe.Method
        Url = $Probe.Url
        StatusCode = $statusCode
        ResponseTimeMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        Available = $available
        Error = $errorMessage
    }
}

try {
    docker compose ps *> $composePath
}
catch {
    "No fue posible ejecutar docker compose ps: $($_.Exception.Message)" | Out-File -Encoding UTF8 $composePath
}

$results = New-Object System.Collections.Generic.List[object]

for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    foreach ($probe in $probes) {
        $result = Invoke-Probe -Probe $probe -Iteration $iteration -TimeoutSeconds $TimeoutSeconds
        $results.Add($result)
        $state = if ($result.Available) { "DISPONIBLE" } else { "NO DISPONIBLE" }
        Write-Host ("[{0}] {1} {2} {3} ms" -f $result.Timestamp, $result.Service, $state, $result.ResponseTimeMs)
    }

    if ($iteration -lt $Iterations) {
        Start-Sleep -Seconds $IntervalSeconds
    }
}

$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$summaryRows = foreach ($group in ($results | Group-Object Service)) {
    $total = $group.Count
    $ok = @($group.Group | Where-Object { $_.Available }).Count
    $availability = if ($total -eq 0) { 0 } else { [Math]::Round(($ok / $total) * 100, 2) }
    $responseTimes = @($group.Group | Where-Object { $_.Available } | ForEach-Object { [double]$_.ResponseTimeMs })
    $avg = if ($responseTimes.Count -eq 0) { 0 } else { [Math]::Round(($responseTimes | Measure-Object -Average).Average, 2) }
    $max = if ($responseTimes.Count -eq 0) { 0 } else { [Math]::Round(($responseTimes | Measure-Object -Maximum).Maximum, 2) }
    $p95 = Get-Percentile -Values $responseTimes -Percentile 95

    [pscustomobject]@{
        Service = $group.Name
        TotalChecks = $total
        SuccessfulChecks = $ok
        AvailabilityPercent = $availability
        AverageResponseMs = $avg
        P95ResponseMs = $p95
        MaxResponseMs = $max
    }
}

$overallTotal = $results.Count
$overallOk = @($results | Where-Object { $_.Available }).Count
$overallAvailability = if ($overallTotal -eq 0) { 0 } else { [Math]::Round(($overallOk / $overallTotal) * 100, 2) }

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add("# Resumen de prueba de disponibilidad")
$summary.Add("")
$summary.Add("- Fecha de ejecucion: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$summary.Add("- Iteraciones: $Iterations")
$summary.Add("- Intervalo entre iteraciones: $IntervalSeconds segundos")
$summary.Add("- Timeout por peticion: $TimeoutSeconds segundos")
$summary.Add("- Verificaciones totales: $overallTotal")
$summary.Add("- Verificaciones exitosas: $overallOk")
$summary.Add("- Disponibilidad global: $overallAvailability%")
$summary.Add("- Evidencia CSV: $csvPath")
$summary.Add("- Estado Docker Compose: $composePath")
$summary.Add("")
$summary.Add("| Servicio | Verificaciones | Exitosas | Disponibilidad | Promedio ms | P95 ms | Max ms |")
$summary.Add("|---|---:|---:|---:|---:|---:|---:|")

foreach ($row in $summaryRows) {
    $summary.Add("| $($row.Service) | $($row.TotalChecks) | $($row.SuccessfulChecks) | $($row.AvailabilityPercent)% | $($row.AverageResponseMs) | $($row.P95ResponseMs) | $($row.MaxResponseMs) |")
}

$summary | Out-File -FilePath $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "Evidencia generada:"
Write-Host "  $csvPath"
Write-Host "  $summaryPath"
Write-Host "  $composePath"
