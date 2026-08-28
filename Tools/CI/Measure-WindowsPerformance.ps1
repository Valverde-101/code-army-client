param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [int]$DurationSeconds = 20,
  [int]$SampleSeconds = 2,
  [double]$CpuRegressionRatio = 1.50,
  [double]$CpuRegressionFloorPercent = 5.0,
  [double]$WorkingSetRegressionRatio = 1.25,
  [int64]$WorkingSetRegressionFloorBytes = 67108864
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($DurationSeconds -lt 10) { throw 'PERFORMANCE_PRECHECK=FAIL duration_too_short' }
if ($SampleSeconds -lt 1) { throw 'PERFORMANCE_PRECHECK=FAIL sample_interval_too_short' }
if ($CpuRegressionRatio -lt 1.0) { throw 'PERFORMANCE_PRECHECK=FAIL invalid_cpu_regression_ratio' }
if ($WorkingSetRegressionRatio -lt 1.0) { throw 'PERFORMANCE_PRECHECK=FAIL invalid_working_set_regression_ratio' }

$buildBase = Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha"
$buildRoot = Join-Path $buildBase 'windows-full-candidate'
$candidateRoot = Join-Path $buildRoot 'ArmyAttack'
$candidateExe = Join-Path $candidateRoot 'Army Attack.exe'
$upstreamRoot = Join-Path $buildBase 'windows-upstream-v23\23'
$upstreamExe = Join-Path $upstreamRoot 'Army Attack.exe'
$reportPath = Join-Path $buildRoot 'REPORT.md'
$summaryPath = Join-Path $buildRoot 'summary.json'
$performancePath = Join-Path $buildRoot 'performance.json'

foreach ($required in @($candidateRoot,$candidateExe,$upstreamRoot,$upstreamExe,$reportPath,$summaryPath)) {
  if (-not (Test-Path -LiteralPath $required)) {
    throw "PERFORMANCE_PRECHECK=FAIL missing=$required"
  }
}

$logicalProcessors = [Math]::Max(1, [Environment]::ProcessorCount)

function Measure-Scenario {
  param(
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)][string]$ExePath,
    [Parameter(Mandatory=$true)][string]$WorkingDirectory
  )

  $samples = @()
  $proc = $null
  try {
    $proc = Start-Process -FilePath $ExePath -WorkingDirectory $WorkingDirectory -PassThru
    Write-Host "PERFORMANCE_LAUNCH=PASS label=$Label pid=$($proc.Id) exe=$ExePath"

    $deadline = (Get-Date).AddSeconds(20)
    do {
      Start-Sleep -Milliseconds 500
      $proc.Refresh()
      if ($proc.HasExited) { throw "PERFORMANCE_LAUNCH=FAIL label=$Label exit=$($proc.ExitCode)" }
    } while ($proc.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline)

    if ($proc.MainWindowHandle -eq 0) { throw "PERFORMANCE_WINDOW=FAIL label=$Label no_main_window" }
    Write-Host "PERFORMANCE_WINDOW=PASS label=$Label handle=$($proc.MainWindowHandle) title=$($proc.MainWindowTitle)"

    Start-Sleep -Seconds 3
    $proc.Refresh()
    $previousCpuMs = $proc.TotalProcessorTime.TotalMilliseconds
    $previousAt = Get-Date
    $elapsed = 0

    while ($elapsed -lt $DurationSeconds) {
      Start-Sleep -Seconds $SampleSeconds
      $elapsed += $SampleSeconds
      $proc.Refresh()
      if ($proc.HasExited) { throw "PERFORMANCE=FAIL label=$Label process_exited elapsed=$elapsed exit=$($proc.ExitCode)" }
      if (-not $proc.Responding) { throw "PERFORMANCE=FAIL label=$Label unresponsive elapsed=$elapsed" }

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
      $samples += $sample
      Write-Host "PERFORMANCE_SAMPLE=PASS label=$Label elapsed=$elapsed cpu_percent=$cpuPercent working_set=$workingSetBytes private_bytes=$privateBytes"

      $previousCpuMs = $cpuMs
      $previousAt = $now
    }

    if ($samples.Count -lt 3) { throw "PERFORMANCE=FAIL label=$Label insufficient_samples=$($samples.Count)" }

    return [pscustomobject]@{
      label = $Label
      sample_count = $samples.Count
      avg_cpu_percent = [Math]::Round((($samples | Measure-Object cpu_percent -Average).Average), 2)
      peak_cpu_percent = [Math]::Round((($samples | Measure-Object cpu_percent -Maximum).Maximum), 2)
      avg_working_set_bytes = [int64][Math]::Round((($samples | Measure-Object working_set_bytes -Average).Average))
      peak_working_set_bytes = [int64](($samples | Measure-Object working_set_bytes -Maximum).Maximum)
      avg_private_bytes = [int64][Math]::Round((($samples | Measure-Object private_bytes -Average).Average))
      peak_private_bytes = [int64](($samples | Measure-Object private_bytes -Maximum).Maximum)
      samples = $samples
    }
  }
  finally {
    if ($proc -and -not $proc.HasExited) {
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
}

$baseline = Measure-Scenario -Label 'UPSTREAM_V23' -ExePath $upstreamExe -WorkingDirectory $upstreamRoot
$candidate = Measure-Scenario -Label 'FULL_CANDIDATE' -ExePath $candidateExe -WorkingDirectory $candidateRoot

$cpuDelta = [Math]::Round(($candidate.avg_cpu_percent - $baseline.avg_cpu_percent), 2)
$cpuRatio = if ($baseline.avg_cpu_percent -gt 0.01) { [Math]::Round(($candidate.avg_cpu_percent / $baseline.avg_cpu_percent), 3) } else { 1.0 }
$workingSetDelta = [int64]($candidate.avg_working_set_bytes - $baseline.avg_working_set_bytes)
$workingSetRatio = if ($baseline.avg_working_set_bytes -gt 0) { [Math]::Round(($candidate.avg_working_set_bytes / [double]$baseline.avg_working_set_bytes), 3) } else { 1.0 }
$privateDelta = [int64]($candidate.avg_private_bytes - $baseline.avg_private_bytes)

$cpuRegression = ($cpuDelta -gt $CpuRegressionFloorPercent) -and ($cpuRatio -gt $CpuRegressionRatio)
$workingSetRegression = ($workingSetDelta -gt $WorkingSetRegressionFloorBytes) -and ($workingSetRatio -gt $WorkingSetRegressionRatio)

$comparison = [ordered]@{
  cpu_delta_percent_points = $cpuDelta
  cpu_ratio = $cpuRatio
  avg_working_set_delta_bytes = $workingSetDelta
  working_set_ratio = $workingSetRatio
  avg_private_delta_bytes = $privateDelta
  cpu_regression = $cpuRegression
  working_set_regression = $workingSetRegression
  cpu_regression_ratio_threshold = $CpuRegressionRatio
  cpu_regression_floor_percent_points = $CpuRegressionFloorPercent
  working_set_regression_ratio_threshold = $WorkingSetRegressionRatio
  working_set_regression_floor_bytes = $WorkingSetRegressionFloorBytes
}

$performance = [ordered]@{
  schema = 2
  tested_sha = $ExpectedSha
  scenario = 'same_machine_same_idle_boot_window'
  duration_seconds = $DurationSeconds
  sample_interval_seconds = $SampleSeconds
  logical_processors = $logicalProcessors
  baseline = $baseline
  candidate = $candidate
  comparison = $comparison
  generated_utc = (Get-Date).ToUniversalTime().ToString('o')
}
$performance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $performancePath -Encoding UTF8

if ($cpuRegression -or $workingSetRegression) {
  Write-Host "PERFORMANCE_REGRESSION=FAIL cpu_regression=$cpuRegression working_set_regression=$workingSetRegression cpu_delta_pp=$cpuDelta cpu_ratio=$cpuRatio working_set_delta=$workingSetDelta working_set_ratio=$workingSetRatio"
  throw 'PERFORMANCE=FAIL regression_detected'
}

$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
$summary | Add-Member -NotePropertyName performance -NotePropertyValue 'PASS' -Force
$summary | Add-Member -NotePropertyName performance_baseline -NotePropertyValue 'UPSTREAM_V23' -Force
$summary | Add-Member -NotePropertyName avg_cpu_percent -NotePropertyValue $candidate.avg_cpu_percent -Force
$summary | Add-Member -NotePropertyName peak_cpu_percent -NotePropertyValue $candidate.peak_cpu_percent -Force
$summary | Add-Member -NotePropertyName avg_working_set_bytes -NotePropertyValue $candidate.avg_working_set_bytes -Force
$summary | Add-Member -NotePropertyName peak_working_set_bytes -NotePropertyValue $candidate.peak_working_set_bytes -Force
$summary | Add-Member -NotePropertyName baseline_avg_cpu_percent -NotePropertyValue $baseline.avg_cpu_percent -Force
$summary | Add-Member -NotePropertyName baseline_avg_working_set_bytes -NotePropertyValue $baseline.avg_working_set_bytes -Force
$summary | Add-Member -NotePropertyName cpu_delta_percent_points -NotePropertyValue $cpuDelta -Force
$summary | Add-Member -NotePropertyName working_set_delta_bytes -NotePropertyValue $workingSetDelta -Force
$summary | Add-Member -NotePropertyName performance_report -NotePropertyValue $performancePath -Force
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

@"

## Performance gate

- PERFORMANCE: PASS
- Scenario: same-machine idle/booted baseline v23 versus candidate
- Duration per executable: $DurationSeconds seconds
- Sample interval: $SampleSeconds seconds
- Logical processors: $logicalProcessors
- Baseline average CPU: $($baseline.avg_cpu_percent)%
- Candidate average CPU: $($candidate.avg_cpu_percent)%
- CPU delta: $cpuDelta percentage points (ratio $cpuRatio)
- Baseline average working set: $($baseline.avg_working_set_bytes) bytes
- Candidate average working set: $($candidate.avg_working_set_bytes) bytes
- Working-set delta: $workingSetDelta bytes (ratio $workingSetRatio)
- Baseline average private bytes: $($baseline.avg_private_bytes) bytes
- Candidate average private bytes: $($candidate.avg_private_bytes) bytes
- Regression decision: PASS
- Detailed samples/comparison: $performancePath
"@ | Add-Content -LiteralPath $reportPath -Encoding UTF8

Write-Host "PERFORMANCE_REPORT=$performancePath"
Write-Host "PERFORMANCE_BASELINE=PASS avg_cpu_percent=$($baseline.avg_cpu_percent) avg_working_set=$($baseline.avg_working_set_bytes) samples=$($baseline.sample_count)"
Write-Host "PERFORMANCE_CANDIDATE=PASS avg_cpu_percent=$($candidate.avg_cpu_percent) peak_cpu_percent=$($candidate.peak_cpu_percent) avg_working_set=$($candidate.avg_working_set_bytes) peak_working_set=$($candidate.peak_working_set_bytes) samples=$($candidate.sample_count)"
Write-Host "PERFORMANCE_REGRESSION=PASS cpu_delta_pp=$cpuDelta cpu_ratio=$cpuRatio working_set_delta=$workingSetDelta working_set_ratio=$workingSetRatio"
Write-Host "PERFORMANCE=PASS baseline=v23 candidate_sha=$ExpectedSha"
