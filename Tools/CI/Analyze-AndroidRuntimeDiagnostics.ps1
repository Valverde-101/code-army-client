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

$summarySha=[string]$summary.tested_sha
$summaryApkSha=[string]$summary.apk_sha256
if($summarySha -ne $ExpectedSha){throw "RUNTIME_DIAGNOSTICS=FAIL tested_sha expected=$ExpectedSha actual=$summarySha"}
if($summaryApkSha -and $summaryApkSha.ToLowerInvariant() -ne $ExpectedApkSha256.ToLowerInvariant()){
  throw "RUNTIME_DIAGNOSTICS=FAIL apk_sha256 expected=$ExpectedApkSha256 actual=$summaryApkSha"
}

if(([string]$summary.result) -eq 'SKIPPED_WITH_REASON'){
  [ordered]@{
    tested_sha=$ExpectedSha
    apk_sha256=$ExpectedApkSha256.ToLowerInvariant()
    result='SKIPPED_WITH_REASON'
    reason=[string]$summary.reason
    game_event_count=0
    swf_event_count=0
    generated_utc=[DateTime]::UtcNow.ToString('o')
  }|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $resultPath -Encoding UTF8
  Write-Host "RUNTIME_DIAGNOSTICS=SKIPPED_WITH_REASON reason=$($summary.reason)"
  Write-Host "SWF_RUNTIME_TRACE=SKIPPED_WITH_REASON reason=$($summary.reason)"
  Write-Host "RUNTIME_DIAGNOSTICS_REPORT=PASS path=$resultPath"
  exit 0
}

$logcatPath=Join-Path $EvidenceRoot 'logcat.txt'
if(-not(Test-Path -LiteralPath $logcatPath)){throw "RUNTIME_DIAGNOSTICS=FAIL logcat_missing=$logcatPath"}
$logLines=Get-Content -LiteralPath $logcatPath
$eventPattern='ArmyAttackGame\s*:\s*([A-Z0-9_]+)\s*(.*)$'
$counts=[ordered]@{}
$events=New-Object System.Collections.Generic.List[object]
$swfEvents=New-Object System.Collections.Generic.List[object]
$swfMisses=New-Object System.Collections.Generic.List[object]
$hfeProgress=New-Object System.Collections.Generic.List[object]
$pvpGraphics=New-Object System.Collections.Generic.List[object]
$pvpMovement=New-Object System.Collections.Generic.List[object]
$pvpLoot=New-Object System.Collections.Generic.List[object]
$pvpPowerUps=New-Object System.Collections.Generic.List[object]
$loadElapsed=New-Object System.Collections.Generic.List[int]

foreach($line in $logLines){
  if($line -notmatch $eventPattern){continue}
  $kind=$matches[1]
  $detail=$matches[2].Trim()
  if(-not $counts.Contains($kind)){$counts[$kind]=0}
  $counts[$kind]=[int]$counts[$kind]+1
  $row=[ordered]@{kind=$kind;detail=$detail}
  $events.Add($row)
  if($kind -like 'SWF_*'){
    $swfEvents.Add($row)
    if($kind -in @('SWF_CLASS_MISS','SWF_RESOURCE_SYMBOL_MISS','SWF_RESOURCE_DOMAIN_ERROR')){$swfMisses.Add($row)}
    if($kind -eq 'SWF_LOAD_COMPLETE' -and $detail -match '(?:elapsed_ms|duration_ms)=([0-9]+)'){$loadElapsed.Add([int]$matches[1])}
  }
  if($kind -eq 'HFE_HARVEST_PROGRESS'){$hfeProgress.Add($row)}
  if($kind -in @('PVP_ENEMY_GRAPHICS_ENTRY','PVP_ENEMY_GRAPHICS_RESOLVED')){$pvpGraphics.Add($row)}
  if($kind -in @('PVP_ENEMY_MOVE_VISUAL','PVP_ENEMY_MOVE_VISUAL_MISMATCH','PVP_ENEMY_SYMBOL')){$pvpMovement.Add($row)}
  if($kind -like 'PVP_LOOT_*'){$pvpLoot.Add($row)}
  if($kind -like 'PVP_POWERUP_*' -or $kind -like 'PVP_AREA_WEIGHTED_*'){$pvpPowerUps.Add($row)}
}

$eventCount=$events.Count
$swfEventCount=$swfEvents.Count
if($eventCount -eq 0){throw 'RUNTIME_DIAGNOSTICS=FAIL always_on_game_events_missing'}
if($swfEventCount -eq 0){throw 'SWF_RUNTIME_TRACE=FAIL swf_events_missing'}

$loadMax=0
$loadAvg=0.0
if($loadElapsed.Count -gt 0){
  $loadMax=($loadElapsed|Measure-Object -Maximum).Maximum
  $loadAvg=[Math]::Round(($loadElapsed|Measure-Object -Average).Average,2)
}

$report=[ordered]@{
  tested_sha=$ExpectedSha
  apk_sha256=$ExpectedApkSha256.ToLowerInvariant()
  result='PASS'
  game_event_count=$eventCount
  swf_event_count=$swfEventCount
  swf_miss_count=$swfMisses.Count
  swf_load_timing=[ordered]@{samples=$loadElapsed.Count;average_ms=$loadAvg;max_ms=$loadMax}
  hfe_progress_event_count=$hfeProgress.Count
  pvp_graphics_event_count=$pvpGraphics.Count
  pvp_movement_event_count=$pvpMovement.Count
  pvp_loot_event_count=$pvpLoot.Count
  pvp_powerup_event_count=$pvpPowerUps.Count
  event_counts=$counts
  swf_misses=@($swfMisses|Select-Object -First 100)
  hfe_progress=@($hfeProgress|Select-Object -First 100)
  pvp_graphics=@($pvpGraphics|Select-Object -First 100)
  pvp_movement=@($pvpMovement|Select-Object -First 200)
  pvp_loot=@($pvpLoot|Select-Object -First 200)
  pvp_powerups=@($pvpPowerUps|Select-Object -First 200)
  generated_utc=[DateTime]::UtcNow.ToString('o')
}
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $resultPath -Encoding UTF8

Write-Host "RUNTIME_DIAGNOSTICS=PASS game_events=$eventCount"
Write-Host "SWF_RUNTIME_TRACE=PASS events=$swfEventCount misses=$($swfMisses.Count) load_samples=$($loadElapsed.Count) load_avg_ms=$loadAvg load_max_ms=$loadMax"
Write-Host "HFE_RUNTIME_TRACE=$(if($hfeProgress.Count -gt 0){'PASS'}else{'SKIPPED_WITH_REASON'}) events=$($hfeProgress.Count)"
Write-Host "PVP_GRAPHICS_RUNTIME_TRACE=$(if($pvpGraphics.Count -gt 0){'PASS'}else{'SKIPPED_WITH_REASON'}) events=$($pvpGraphics.Count)"
Write-Host "PVP_MOVEMENT_RUNTIME_TRACE=$(if($pvpMovement.Count -gt 0){'PASS'}else{'SKIPPED_WITH_REASON'}) events=$($pvpMovement.Count)"
Write-Host "PVP_LOOT_RUNTIME_TRACE=$(if($pvpLoot.Count -gt 0){'PASS'}else{'SKIPPED_WITH_REASON'}) events=$($pvpLoot.Count)"
Write-Host "PVP_POWERUP_RUNTIME_TRACE=$(if($pvpPowerUps.Count -gt 0){'PASS'}else{'SKIPPED_WITH_REASON'}) events=$($pvpPowerUps.Count)"
Write-Host "RUNTIME_DIAGNOSTICS_REPORT=PASS path=$resultPath"
