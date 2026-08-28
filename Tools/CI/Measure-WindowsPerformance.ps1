param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [int]$DurationSeconds = 20,
  [int]$SampleSeconds = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($DurationSeconds -lt 10) { throw 'PERFORMANCE_PRECHECK=FAIL duration_too_short' }
if ($SampleSeconds -lt 1) { throw 'PERFORMANCE_PRECHECK=FAIL sample_interval_too_short' }

$buildRoot = Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\windows-full-candidate"
$candidateRoot = Join-Path $buildRoot 'ArmyAttack'
$exePath = Join-Path $candidateRoot 'Army Attack.exe'
$reportPath = Join-Path $buildRoot 'REPORT.md'
$summaryPath = Join-Path $buildRoot 'summary.json'
$performancePath = Join-Path $buildRoot 'performance.json'

foreach ($required in @($candidateRoot,$exePath,$reportPath,$summaryPath)) {
  if (-not (Test-Path -LiteralPath $required)) {
    throw "PERFORMANCE_PRECHECK=FAIL missing=$required"
  }
}

$logicalProcessors = [Math]::Max(1, [Environment]::ProcessorCount)
$samples = New-Object System.Collections.Generic.List[object]
$proc = $null
$started = Get-Date
try {
  $proc = Start-Process -FilePath $exePath -WorkingDirectory $candidateRoot -PassThru
  Write-Host "PERFORMANCE_LAUNCH=PASS pid=$($proc.Id) exe=$exePath"

  $deadline = (Get-Date).AddSeconds(20)
  do {
    Start-Sleep -Milliseconds 500
    $proc.Refresh()
    if ($proc.HasExited) { throw "PERFORMANCE_LAUNCH=FAIL exit=$($proc.ExitCode)" }
  } while ($proc.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline)

  if ($proc.MainWindowHandle -eq 0) { throw 'PERFORMANCE_WINDOW=FAIL no_main_window' }
  Write-Host "PERFORMANCE_WINDOW=PASS handle=$($proc.MainWindowHandle) title=$($proc.MainWindowTitle)"

  Start-Sleep -Seconds 3
  $proc.Refresh()
  $previousCpuMs = $proc.TotalProcessorTime.TotalMilliseconds
  $previousAt = Get-Date
  $elapsed = 0

  while ($elapsed -lt $DurationSeconds) {
    Start-Sleep -Seconds $SampleSeconds
    $elapsed += $SampleSeconds
    $proc.Refresh()
    if ($proc.HasExited) { throw "PERFORMANCE=FAIL process_exited elapsed=$elapsed exit=$($proc.ExitCode)" }
    if (-not $proc.Responding) { throw "PERFORMANCE=FAIL unresponsive elapsed=$elapsed" }

    $now = Get-Date
    $cpuMs = $proc.TotalProcessorTime.TotalMilliseconds
    $wallMs = ($now - $previousAt).TotalMilliseconds
    $deltaCpuMs = [Math]::Max(0.0, $cpuMs - $previousCpuMs)
    $cpuPercent = if ($wallMs -gt 0) { 100.0 * $deltaCpuMs / ($wallMs * $logicalProcessors) } else { 0.0 }
    $cpuPercent = [Math]::Round([Math]::Max(0.0, [Math]::Min(100.0, $cpuPercent)), 2)
    $workingSetBytes = [int64]$proc.WorkingSet64
    $privateBytes = [int64]$proc.PrivateMemorySize64

    $sample = [pscustomobject]@{
      elapsed_seconds = $elapsed
      cpu_percent = $cpuPercent
      working_set_bytes = $workingSetBytes
      private_bytes = $privateBytes
    }
    $samples.Add($sample)
    Write-Host "PERFORMANCE_SAMPLE=PASS elapsed=$elapsed cpu_percent=$cpuPercent working_set=$workingSetBytes private_bytes=$privateBytes"

    $previousCpuMs = $cpuMs
    $previousAt = $now
  }

  if ($samples.Count -lt 3) { throw "PERFORMANCE=FAIL insufficient_samples=$($samples.Count)" }

  $avgCpu = [Math]::Round(($samples | Measure-Object cpu_percent -Average).Average, 2)
  $peakCpu = [Math]::Round(($samples | Measure-Object cpu_percent -Maximum).Maximum, 2)
  $avgWorkingSet = [int64][Math]::Round(($samples | Measure-Object working_set_bytes -Average).Average)
  $peakWorkingSet = [int64]($samples | Measure-Object working_set_bytes -Maximum).Maximum
  $avgPrivate = [int64][Math]::Round(($samples | Measure-Object private_bytes -Average).Average)
  $peakPrivate = [int64]($samples | Measure-Object private_bytes -Maximum).Maximum

  $performance = [ordered]@{
    schema = 1
    tested_sha = $ExpectedSha
    duration_seconds = $DurationSeconds
    sample_interval_seconds = $SampleSeconds
    logical_processors = $logicalProcessors
    sample_count = $samples.Count
    avg_cpu_percent = $avgCpu
    peak_cpu_percent = $peakCpu
    avg_working_set_bytes = $avgWorkingSet
    peak_working_set_bytes = $peakWorkingSet
    avg_private_bytes = $avgPrivate
    peak_private_bytes = $peakPrivate
    samples = @($samples)
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
  }
  $performance | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $performancePath -Encoding UTF8

  $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
  $summary | Add-Member -NotePropertyName performance -NotePropertyValue 'PASS' -Force
  $summary | Add-Member -NotePropertyName avg_cpu_percent -NotePropertyValue $avgCpu -Force
  $summary | Add-Member -NotePropertyName peak_cpu_percent -NotePropertyValue $peakCpu -Force
  $summary | Add-Member -NotePropertyName avg_working_set_bytes -NotePropertyValue $avgWorkingSet -Force
  $summary | Add-Member -NotePropertyName peak_working_set_bytes -NotePropertyValue $peakWorkingSet -Force
  $summary | Add-Member -NotePropertyName performance_report -NotePropertyValue $performancePath -Force
  $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

  @"

## Performance gate

- PERFORMANCE: PASS
- Scenario: idle/booted candidate after runtime validation
- Duration: $DurationSeconds seconds
- Sample interval: $SampleSeconds seconds
- Logical processors: $logicalProcessors
- Average CPU: $avgCpu%
- Peak CPU: $peakCpu%
- Average working set: $avgWorkingSet bytes
- Peak working set: $peakWorkingSet bytes
- Average private bytes: $avgPrivate bytes
- Peak private bytes: $peakPrivate bytes
- Detailed samples: $performancePath
"@ | Add-Content -LiteralPath $reportPath -Encoding UTF8

  Write-Host "PERFORMANCE_REPORT=$performancePath"
  Write-Host "PERFORMANCE=PASS avg_cpu_percent=$avgCpu peak_cpu_percent=$peakCpu avg_working_set=$avgWorkingSet peak_working_set=$peakWorkingSet samples=$($samples.Count)"
}
finally {
  if ($proc -and -not $proc.HasExited) {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
}
