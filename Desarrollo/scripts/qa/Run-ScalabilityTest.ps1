param(
    [int[]]$ConcurrencyLevels = @(500),
    [int]$RequestsPerLevel = 500,
    [int]$TimeoutSeconds = 20,
    [string]$OutputDir = "docs/evidencias"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$detailCsvPath = Join-Path $OutputDir "escalabilidad-detalle-$timestamp.csv"
$summaryCsvPath = Join-Path $OutputDir "escalabilidad-resumen-$timestamp.csv"
$summaryMdPath = Join-Path $OutputDir "escalabilidad-resumen-$timestamp.md"

Add-Type -ReferencedAssemblies "System.Net.Http.dll" -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace QaLoad
{
    public class LoadResult
    {
        public string Timestamp { get; set; }
        public string Component { get; set; }
        public string Service { get; set; }
        public string Url { get; set; }
        public int Concurrency { get; set; }
        public int RequestNumber { get; set; }
        public int StatusCode { get; set; }
        public double ResponseTimeMs { get; set; }
        public bool Success { get; set; }
        public string Error { get; set; }
    }

    public static class Runner
    {
        public static LoadResult[] Run(string component, string service, string url, int[] successCodes, int concurrency, int requestCount, int timeoutSeconds)
        {
            ServicePointManager.DefaultConnectionLimit = Math.Max(ServicePointManager.DefaultConnectionLimit, concurrency * 2);
            return RunAsync(component, service, url, successCodes, concurrency, requestCount, timeoutSeconds).GetAwaiter().GetResult();
        }

        private static async Task<LoadResult[]> RunAsync(string component, string service, string url, int[] successCodes, int concurrency, int requestCount, int timeoutSeconds)
        {
            using (var client = new HttpClient())
            using (var semaphore = new SemaphoreSlim(concurrency, concurrency))
            {
                client.Timeout = TimeSpan.FromSeconds(timeoutSeconds);
                var tasks = new List<Task<LoadResult>>();

                for (var i = 1; i <= requestCount; i++)
                {
                    var requestNumber = i;
                    tasks.Add(Task.Run(async () =>
                    {
                        await semaphore.WaitAsync();
                        var startedAt = DateTime.Now;
                        var sw = Stopwatch.StartNew();
                        var result = new LoadResult
                        {
                            Timestamp = startedAt.ToString("yyyy-MM-dd HH:mm:ss"),
                            Component = component,
                            Service = service,
                            Url = url,
                            Concurrency = concurrency,
                            RequestNumber = requestNumber,
                            StatusCode = 0,
                            ResponseTimeMs = 0,
                            Success = false,
                            Error = ""
                        };

                        try
                        {
                            using (var response = await client.GetAsync(url))
                            {
                                sw.Stop();
                                result.StatusCode = (int)response.StatusCode;
                                result.ResponseTimeMs = Math.Round(sw.Elapsed.TotalMilliseconds, 2);
                                result.Success = successCodes.Contains(result.StatusCode);
                            }
                        }
                        catch (Exception ex)
                        {
                            sw.Stop();
                            result.ResponseTimeMs = Math.Round(sw.Elapsed.TotalMilliseconds, 2);
                            result.Error = ex.Message;
                        }
                        finally
                        {
                            semaphore.Release();
                        }

                        return result;
                    }));
                }

                return await Task.WhenAll(tasks);
            }
        }
    }
}
"@

$successCodes = @(200, 201, 204)
$targets = @(
    [pscustomobject]@{ Component = "Modulo Batch"; Service = "content-service"; Url = "http://localhost:8081/api/courses/1/modules"; SuccessCodes = $successCodes },
    [pscustomobject]@{ Component = "Modulo Simulacion"; Service = "simulation-service"; Url = "http://localhost:9990/health/ready"; SuccessCodes = $successCodes },
    [pscustomobject]@{ Component = "Modulo Recomendaciones"; Service = "recommendation-service"; Url = "http://localhost:8083/api/recommendations/user/1"; SuccessCodes = $successCodes }
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

function Invoke-LoadBatch {
    param(
        [pscustomobject]$Target,
        [int]$Concurrency,
        [int]$RequestCount,
        [int]$TimeoutSeconds
    )

    return [QaLoad.Runner]::Run($Target.Component, $Target.Service, $Target.Url, [int[]]$Target.SuccessCodes, $Concurrency, $RequestCount, $TimeoutSeconds)
}

$details = New-Object System.Collections.Generic.List[object]
$summaries = New-Object System.Collections.Generic.List[object]

foreach ($target in $targets) {
    foreach ($concurrency in $ConcurrencyLevels) {
        Write-Host ("Ejecutando {0} con concurrencia {1} y {2} peticiones..." -f $target.Service, $concurrency, $RequestsPerLevel)
        $batchSw = [System.Diagnostics.Stopwatch]::StartNew()
        $batch = Invoke-LoadBatch -Target $target -Concurrency $concurrency -RequestCount $RequestsPerLevel -TimeoutSeconds $TimeoutSeconds
        $batchSw.Stop()

        foreach ($row in $batch) {
            $details.Add($row)
        }

        $total = $batch.Count
        $ok = @($batch | Where-Object { $_.Success }).Count
        $successRate = if ($total -eq 0) { 0 } else { [Math]::Round(($ok / $total) * 100, 2) }
        $responseTimes = @($batch | Where-Object { $_.Success } | ForEach-Object { [double]$_.ResponseTimeMs })
        $avg = if ($responseTimes.Count -eq 0) { 0 } else { [Math]::Round(($responseTimes | Measure-Object -Average).Average, 2) }
        $min = if ($responseTimes.Count -eq 0) { 0 } else { [Math]::Round(($responseTimes | Measure-Object -Minimum).Minimum, 2) }
        $max = if ($responseTimes.Count -eq 0) { 0 } else { [Math]::Round(($responseTimes | Measure-Object -Maximum).Maximum, 2) }
        $p95 = Get-Percentile -Values $responseTimes -Percentile 95
        $throughput = if ($batchSw.Elapsed.TotalSeconds -eq 0) { 0 } else { [Math]::Round($total / $batchSw.Elapsed.TotalSeconds, 2) }

        $summaries.Add([pscustomobject]@{
            Component = $target.Component
            Service = $target.Service
            Url = $target.Url
            Concurrency = $concurrency
            Requests = $total
            SuccessfulRequests = $ok
            SuccessRatePercent = $successRate
            AverageResponseMs = $avg
            MinResponseMs = $min
            P95ResponseMs = $p95
            MaxResponseMs = $max
            BatchDurationSeconds = [Math]::Round($batchSw.Elapsed.TotalSeconds, 2)
            ThroughputRequestsPerSecond = $throughput
        })
    }
}

$details | Export-Csv -Path $detailCsvPath -NoTypeInformation -Encoding UTF8
$summaries | Export-Csv -Path $summaryCsvPath -NoTypeInformation -Encoding UTF8

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Resumen de prueba de escalabilidad")
$md.Add("")
$md.Add("- Fecha de ejecucion: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$md.Add("- Niveles de concurrencia: $($ConcurrencyLevels -join ', ')")
$md.Add("- Peticiones por nivel y servicio: $RequestsPerLevel")
$md.Add("- Timeout por peticion: $TimeoutSeconds segundos")
$md.Add("- Evidencia detallada: $detailCsvPath")
$md.Add("- Evidencia resumida: $summaryCsvPath")
$md.Add("")
$md.Add("| Servicio | Concurrencia | Peticiones | Exitosas | Exito | Promedio ms | P95 ms | Max ms | Throughput req/s |")
$md.Add("|---|---:|---:|---:|---:|---:|---:|---:|---:|")

foreach ($row in $summaries) {
    $md.Add("| $($row.Service) | $($row.Concurrency) | $($row.Requests) | $($row.SuccessfulRequests) | $($row.SuccessRatePercent)% | $($row.AverageResponseMs) | $($row.P95ResponseMs) | $($row.MaxResponseMs) | $($row.ThroughputRequestsPerSecond) |")
}

$md | Out-File -FilePath $summaryMdPath -Encoding UTF8

Write-Host ""
Write-Host "Evidencia generada:"
Write-Host "  $detailCsvPath"
Write-Host "  $summaryCsvPath"
Write-Host "  $summaryMdPath"
