param(
  [Parameter(Mandatory=$true)][string]$EvidenceRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$ExpectedApkSha256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(-not(Test-Path -LiteralPath $EvidenceRoot)){throw "RUNTIME_DIAGNOSTICS=FAIL evidence_root_missing=$EvidenceRoot"}
$summaryPath=Join-Path $EvidenceRoot 'summary.json'
if(-not(Test-Path -LiteralPath $summaryPath)){throw "RUNTIME_DIAGNOSTICS=FAIL summary_missing=$summaryPath"}
$summary=Get-Content -LiteralPath $summaryPath -Raw|ConvertFrom-Json
$resultPath=Join-Path $EvidenceRoot 'runtime-diagnostics.json'
if([string]$summary.tested_sha -ne $ExpectedSha){throw "RUNTIME_DIAGNOSTICS=FAIL tested_sha expected=$ExpectedSha actual=$($summary.tested_sha)"}
if([string]$summary.apk_sha256 -and ([string]$summary.apk_sha256).ToLowerInvariant() -ne $ExpectedApkSha256.ToLowerInvariant()){throw "RUNTIME_DIAGNOSTICS=FAIL apk_sha256 expected=$ExpectedApkSha256 actual=$($summary.apk_sha256)"}
if(([string]$summary.result) -eq 'SKIPPED_WITH_REASON'){
  [ordered]@{tested_sha=$ExpectedSha;apk_sha256=$ExpectedApkSha256.ToLowerInvariant();result='SKIPPED_WITH_REASON';reason=[string]$summary.reason;game_event_count=0;swf_event_count=0;generated_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $resultPath -Encoding UTF8
  Write-Host "RUNTIME_DIAGNOSTICS=SKIPPED_WITH_REASON reason=$($summary.reason)";exit 0
}

$logcatPath=Join-Path $EvidenceRoot 'logcat.txt'
if(-not(Test-Path -LiteralPath $logcatPath)){throw "RUNTIME_DIAGNOSTICS=FAIL logcat_missing=$logcatPath"}
$pattern='ArmyAttackGame\s*:\s*([A-Z0-9_]+)\s*(.*)$'
$counts=[ordered]@{};$events=New-Object System.Collections.ArrayList;$swfMisses=New-Object System.Collections.ArrayList;$loadElapsed=New-Object System.Collections.ArrayList
foreach($line in Get-Content -LiteralPath $logcatPath){
  if($line -notmatch $pattern){continue}
  $kind=[string]$matches[1];$detail=[string]$matches[2].Trim()
  if(-not $counts.Contains($kind)){$counts[$kind]=0};$counts[$kind]=[int]$counts[$kind]+1
  [void]$events.Add([pscustomobject]@{kind=$kind;detail=$detail})
  if($kind -in @('SWF_CLASS_MISS','SWF_RESOURCE_SYMBOL_MISS','SWF_RESOURCE_DOMAIN_ERROR','SWF_CLASS_IDENTITY_MISMATCH')){[void]$swfMisses.Add([pscustomobject]@{kind=$kind;detail=$detail})}
  if($kind -eq 'SWF_LOAD_COMPLETE' -and $detail -match '(?:elapsed_ms|duration_ms)=([0-9]+)'){[void]$loadElapsed.Add([int]$matches[1])}
}
if($events.Count -eq 0){throw 'RUNTIME_DIAGNOSTICS=FAIL always_on_game_events_missing'}
$swfCount=0;$swfLoadComplete=0;$assetGateZero=0;$assetLoadErrors=0;$bootReady=0;$bootTransitionFailures=0
foreach($e in $events){
  if([string]$e.kind -like 'SWF_*'){$swfCount++}
  if([string]$e.kind -eq 'SWF_LOAD_COMPLETE'){$swfLoadComplete++}
  if([string]$e.kind -eq 'ASSET_LOAD_GATE' -and [string]$e.detail -match '(?:^|[;\s])pending=0(?:[;\s]|$)'){$assetGateZero++}
  if([string]$e.kind -eq 'ASSET_LOAD_ERROR'){$assetLoadErrors++}
  if([string]$e.kind -eq 'BOOT_READY'){$bootReady++}
  if([string]$e.kind -eq 'BOOT_TRANSITION_FAILURE'){$bootTransitionFailures++}
}
if($swfCount -eq 0){throw 'SWF_RUNTIME_TRACE=FAIL swf_events_missing'}
if($swfLoadComplete -eq 0){throw 'RUNTIME_DIAGNOSTICS=FAIL swf_load_complete_missing'}
if($assetGateZero -eq 0){throw 'RUNTIME_DIAGNOSTICS=FAIL asset_load_gate_pending_zero_missing'}
if($assetLoadErrors -gt 0){throw "RUNTIME_DIAGNOSTICS=FAIL asset_load_errors count=$assetLoadErrors"}
if($bootTransitionFailures -gt 0){throw "RUNTIME_DIAGNOSTICS=FAIL boot_transition_failures count=$bootTransitionFailures"}
if($bootReady -eq 0){throw 'RUNTIME_DIAGNOSTICS=FAIL boot_ready_missing'}

$loadMax=0;$loadAvg=0.0
if($loadElapsed.Count -gt 0){$loadMax=($loadElapsed|Measure-Object -Maximum).Maximum;$loadAvg=[Math]::Round(($loadElapsed|Measure-Object -Average).Average,2)}
$report=[ordered]@{
  tested_sha=$ExpectedSha;apk_sha256=$ExpectedApkSha256.ToLowerInvariant();result='PASS';game_event_count=$events.Count;swf_event_count=$swfCount;swf_miss_count=$swfMisses.Count;swf_load_timing=[ordered]@{samples=$loadElapsed.Count;average_ms=$loadAvg;max_ms=$loadMax};swf_load_complete_count=$swfLoadComplete;asset_load_gate_zero_count=$assetGateZero;asset_load_error_count=$assetLoadErrors;boot_ready_count=$bootReady;boot_transition_failure_count=$bootTransitionFailures;event_counts=$counts;swf_misses=@($swfMisses|Select-Object -First 200);generated_utc=[DateTime]::UtcNow.ToString('o')
}
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $resultPath -Encoding UTF8
Write-Host "BOOT_READY=PASS count=$bootReady transition_failures=$bootTransitionFailures asset_errors=$assetLoadErrors"
Write-Host "RUNTIME_DIAGNOSTICS=PASS game_events=$($events.Count) swf_load_complete=$swfLoadComplete asset_gate_zero=$assetGateZero asset_load_errors=$assetLoadErrors boot_ready=$bootReady"
Write-Host "SWF_RUNTIME_TRACE=PASS events=$swfCount misses=$($swfMisses.Count) load_samples=$($loadElapsed.Count) load_avg_ms=$loadAvg load_max_ms=$loadMax"
Write-Host "RUNTIME_DIAGNOSTICS_REPORT=PASS path=$resultPath"
