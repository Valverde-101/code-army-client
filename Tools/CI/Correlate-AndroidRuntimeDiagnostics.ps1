param(
  [Parameter(Mandatory=$true)][string]$EvidenceRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$ExpectedApkSha256,
  [string]$GraphPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Parse-Detail([string]$Detail){
  $map=[ordered]@{}
  if(-not $Detail){return $map}
  foreach($part in ($Detail -split ';')){
    $i=$part.IndexOf('=')
    if($i -le 0){continue}
    $k=$part.Substring(0,$i).Trim()
    $v=$part.Substring($i+1).Trim()
    if($k -and -not $map.Contains($k)){$map[$k]=$v}
  }
  return $map
}

function New-Failure([int]$Seq,[string]$Kind,[string]$Detail,[hashtable]$Kv,[string]$Trace,[string]$Classification,[string]$Severity){
  $row=[ordered]@{
    seq=$Seq;trace=$Trace;kind=$Kind;classification=$Classification;severity=$Severity;detail=$Detail
  }
  foreach($k in @('resource','symbol','resolved_class','domain','url','mission','unit','side','id','result','reason','error','message','from','to','target','phase')){
    if($Kv.Contains($k)){$row[$k]=[string]$Kv[$k]}
  }
  return [pscustomobject]$row
}

function Get-Classification([string]$Kind,[string]$Detail,[hashtable]$Kv){
  if($Kind -eq 'DIAG_FAILURE' -and $Kv.Contains('classification')){return @([string]$Kv['classification'],'ERROR')}
  switch -Regex ($Kind){
    '^ASSET_LOAD_ERROR$' {
      if(($Kv.Contains('url') -and [string]$Kv['url'] -match '^\.\./') -or $Detail -match '\.\./'){return @('APK_ASSET_PATH_MISMATCH','ERROR')}
      return @('APK_ASSET_LOAD_FAILURE','ERROR')
    }
    '^(SWF_CLASS_MISS|SWF_RESOURCE_SYMBOL_MISS|SWF_OPFOR_STRICT_MISS)$' {return @('SWF_SYMBOL_MISSING','ERROR')}
    '^SWF_RESOURCE_DOMAIN_ERROR$' {return @('SWF_RESOURCE_DOMAIN_ERROR','ERROR')}
    '^SWF_CLASS_IDENTITY_MISMATCH$' {return @('SWF_CLASS_IDENTITY_MISMATCH','ERROR')}
    '^SWF_EMBEDDED_SYMBOL_COLLISION$' {return @('SWF_RESOURCE_ALIAS_COLLISION','WARN')}
    '^SWF_ALIAS_RISK$' {return @('SWF_ALIAS_RISK','WARN')}
    '^(MAP_TRANSITION_FAIL|MAP_SWITCH_FAIL)$' {return @('MAP_TRANSITION_STALLED','ERROR')}
    '^PVP_POWERUP_FIREMISSION_MISS$' {return @('CONFIG_REFERENCE_MISSING','ERROR')}
    '^PVP_POWERUP_EXECUTE_ERROR$' {return @('PVP_POWERUP_RUNTIME_ERROR','ERROR')}
    '^PVP_POWERUP_FIREMISSION_ERROR$' {return @('PVP_FIREMISSION_QUEUE_ERROR','ERROR')}
    '^PVP_FIREMISSION_START_ERROR$' {return @('PVP_FIREMISSION_RUNTIME_ERROR','ERROR')}
    '^PVP_ENEMY_MOVE_VISUAL_MISMATCH$' {return @('SWF_CLASS_IDENTITY_MISMATCH','ERROR')}
    '^FIREMISSION_GRAPHICS_MISS$' {return @('SWF_SYMBOL_MISSING','ERROR')}
    '^FIREMISSION_FALLBACK_MISS$' {return @('FIREMISSION_VISUAL_MISSING','ERROR')}
    '^PVP_PARATROOPER_ANIMATION$' {
      $result=if($Kv.Contains('result')){[string]$Kv['result']}else{''}
      switch($result){
        'missing_input' {return @('PARATROOPER_INPUT_MISSING','ERROR')}
        'fallback_miss' {return @('PARATROOPER_SWF_FALLBACK_MISSING','ERROR')}
        'class_miss' {return @('PARATROOPER_SWF_SYMBOL_MISSING','ERROR')}
        'not_movieclip' {return @('PARATROOPER_SYMBOL_TYPE_MISMATCH','ERROR')}
      }
    }
  }
  return $null
}

$root=(Resolve-Path -LiteralPath $EvidenceRoot -ErrorAction Stop).Path
$summaryPath=Join-Path $root 'summary.json'
$runtimePath=Join-Path $root 'runtime-diagnostics.json'
$logcatPath=Join-Path $root 'logcat.txt'
$outDir=Join-Path $root 'correlated-diagnostics'
New-Item -ItemType Directory -Force -Path $outDir|Out-Null

$summary=$null
if(Test-Path -LiteralPath $summaryPath){try{$summary=Get-Content -LiteralPath $summaryPath -Raw|ConvertFrom-Json}catch{}}
if($summary -and [string]$summary.tested_sha -and [string]$summary.tested_sha -ne $ExpectedSha){throw "CORRELATED_DIAGNOSTICS=FAIL tested_sha expected=$ExpectedSha actual=$($summary.tested_sha)"}
if($summary -and [string]$summary.apk_sha256 -and ([string]$summary.apk_sha256).ToLowerInvariant() -ne $ExpectedApkSha256.ToLowerInvariant()){
  throw "CORRELATED_DIAGNOSTICS=FAIL apk_sha expected=$ExpectedApkSha256 actual=$($summary.apk_sha256)"
}

if(-not(Test-Path -LiteralPath $logcatPath -PathType Leaf)){
  $reason=if($summary -and [string]$summary.reason){[string]$summary.reason}else{'logcat_missing'}
  $skipped=[ordered]@{schema='armyattack-correlated-diagnostics/v1';tested_sha=$ExpectedSha;apk_sha256=$ExpectedApkSha256.ToLowerInvariant();result='SKIPPED_WITH_REASON';reason=$reason;generated_utc=[DateTime]::UtcNow.ToString('o')}
  $skipped|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $outDir 'correlated-diagnostics.json') -Encoding UTF8
  $skipped|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $outDir 'last-error.json') -Encoding UTF8
  Write-Host "CORRELATED_DIAGNOSTICS=SKIPPED_WITH_REASON reason=$reason"
  exit 0
}

$staticGraph=$null
if($GraphPath -and (Test-Path -LiteralPath $GraphPath -PathType Leaf)){
  try{$staticGraph=Get-Content -LiteralPath $GraphPath -Raw|ConvertFrom-Json}catch{}
}

$lines=Get-Content -LiteralPath $logcatPath
$events=New-Object System.Collections.Generic.List[object]
$eventPattern='ArmyAttackGame\s*:\s*([A-Z0-9_]+)\s*(.*)$'
$seq=0
$nearestExplicitTrace=''
$nearestExplicitSeq=-100000
$activeMapTrace=''
$mapCounter=0
$bootTrace='BOOT-1'

foreach($line in $lines){
  if($line -notmatch $eventPattern){continue}
  $seq++
  $kind=[string]$matches[1]
  $detail=[string]$matches[2].Trim()
  $kv=Parse-Detail $detail
  $trace=if($kv.Contains('trace')){[string]$kv['trace']}else{''}
  $synthetic=$false

  if($trace){
    $nearestExplicitTrace=$trace
    $nearestExplicitSeq=$seq
  } else {
    if($kind -match '^(ASSET_|SWF_LOAD_)'){
      $trace=$bootTrace;$synthetic=$true
    } elseif($kind -match '^(WORLD_MAP_|MAP_)'){
      if($kind -match '(REQUEST|BEGIN)$' -or -not $activeMapTrace){
        $mapCounter++
        $target=if($kv.Contains('to')){[string]$kv['to']}elseif($kv.Contains('target')){[string]$kv['target']}else{'unknown'}
        $activeMapTrace="MAP-$target-$mapCounter"
      }
      $trace=$activeMapTrace;$synthetic=$true
      if($kind -match '(COMMIT|FAIL|REJECT)$'){$activeMapTrace=''}
    } elseif(($kind -match '^(FIREMISSION_|PVP_FIREMISSION_|PVP_PARATROOPER_)') -and $nearestExplicitTrace -and ($seq-$nearestExplicitSeq) -le 20){
      $trace=$nearestExplicitTrace;$synthetic=$true
    } elseif($kind -match '^SWF_' -and $nearestExplicitTrace -and ($seq-$nearestExplicitSeq) -le 10){
      $trace=$nearestExplicitTrace;$synthetic=$true
    }
  }

  $events.Add([pscustomobject]@{
    seq=$seq;kind=$kind;detail=$detail;trace=$trace;trace_synthetic=$synthetic;kv=$kv
  })
}

# Improve async paratrooper correlation: attach untraced animation lifecycle rows to the
# nearest PARA request with matching side/unit, without relying on coordinates.
$paraByKey=@{}
foreach($e in $events){
  if($e.kind -eq 'PVP_PARATROOPER_REQUEST' -and $e.trace){
    $side=if($e.kv.Contains('side')){[string]$e.kv['side']}else{''}
    $unit=if($e.kv.Contains('unit')){[string]$e.kv['unit']}else{''}
    $paraByKey[($side+'|'+$unit)]=[string]$e.trace
  } elseif($e.kind -eq 'PVP_PARATROOPER_ANIMATION' -and -not $e.trace){
    $side=if($e.kv.Contains('side')){[string]$e.kv['side']}else{''}
    $unit=if($e.kv.Contains('unit')){[string]$e.kv['unit']}else{''}
    $key=$side+'|'+$unit
    if($paraByKey.ContainsKey($key)){$e.trace=[string]$paraByKey[$key];$e.trace_synthetic=$true}
  }
}

$failures=New-Object System.Collections.Generic.List[object]
$warnings=New-Object System.Collections.Generic.List[object]
foreach($e in $events){
  $classification=Get-Classification $e.kind $e.detail $e.kv
  if(-not $classification){continue}
  $row=New-Failure $e.seq $e.kind $e.detail $e.kv $e.trace $classification[0] $classification[1]

  if($staticGraph -and $row.PSObject.Properties.Name -contains 'symbol'){
    $symbol=[string]$row.symbol
    if($symbol){
      $matches=@($staticGraph.edges|Where-Object{[string]$_.symbol -eq $symbol}|Select-Object -First 25)
      if($matches.Count -gt 0){$row|Add-Member -NotePropertyName static_consumers -NotePropertyValue $matches}
    }
  }
  if($classification[1] -eq 'ERROR'){$failures.Add($row)}else{$warnings.Add($row)}
}

$traces=@{}
foreach($e in $events){
  $trace=[string]$e.trace
  if(-not $trace){continue}
  if(-not $traces.ContainsKey($trace)){
    $traces[$trace]=[ordered]@{trace=$trace;first_seq=$e.seq;last_seq=$e.seq;event_count=0;kinds=[ordered]@{};classifications=New-Object System.Collections.Generic.List[string];result='OPEN'}
  }
  $t=$traces[$trace]
  $t.last_seq=$e.seq
  $t.event_count=[int]$t.event_count+1
  if(-not $t.kinds.Contains($e.kind)){$t.kinds[$e.kind]=0}
  $t.kinds[$e.kind]=[int]$t.kinds[$e.kind]+1
  if($e.kind -eq 'TRACE_END' -and $e.kv.Contains('result')){$t.result=[string]$e.kv['result']}
}
foreach($f in $failures){if($f.trace -and $traces.ContainsKey([string]$f.trace)){[void]$traces[[string]$f.trace].classifications.Add([string]$f.classification)}}
foreach($w in $warnings){if($w.trace -and $traces.ContainsKey([string]$w.trace)){[void]$traces[[string]$w.trace].classifications.Add([string]$w.classification)}}

$spikes=New-Object System.Collections.Generic.List[object]
$spikePath=Join-Path $root 'frame-spikes.jsonl'
if(Test-Path -LiteralPath $spikePath -PathType Leaf){
  foreach($line in Get-Content -LiteralPath $spikePath){
    if(-not $line.Trim()){continue}
    try{
      $s=$line|ConvertFrom-Json
      $trace=''
      $kind=[string]$s.nearest_game_event_kind
      $detail=[string]$s.nearest_game_event_detail
      $match=@($events|Where-Object{$_.kind -eq $kind -and $_.detail -eq $detail}|Select-Object -Last 1)
      if($match.Count -gt 0){$trace=[string]$match[0].trace}
      $spikes.Add([pscustomobject]@{frame_ms=[double]$s.frame_ms;event_kind=$kind;event_detail=$detail;event_age_ms=$s.nearest_game_event_age_ms;trace=$trace})
    }catch{}
  }
}
$topSpikes=@($spikes|Sort-Object frame_ms -Descending|Select-Object -First 50)

$lastError=if($failures.Count -gt 0){$failures[$failures.Count-1]}else{$null}
$report=[ordered]@{
  schema='armyattack-correlated-diagnostics/v1'
  repository='Valverde-101/code-army-client'
  tested_sha=$ExpectedSha
  apk_sha256=$ExpectedApkSha256.ToLowerInvariant()
  result='PASS'
  generated_utc=[DateTime]::UtcNow.ToString('o')
  event_count=$events.Count
  explicit_trace_event_count=@($events|Where-Object{$_.trace -and -not $_.trace_synthetic}).Count
  synthetic_trace_event_count=@($events|Where-Object{$_.trace_synthetic}).Count
  trace_count=$traces.Count
  failure_count=$failures.Count
  warning_count=$warnings.Count
  frame_spike_count=$spikes.Count
  last_error=$lastError
  failures=@($failures|Select-Object -Last 200)
  warnings=@($warnings|Select-Object -Last 200)
  traces=@($traces.Values)
  top_frame_spikes=$topSpikes
  static_graph=[ordered]@{available=($null -ne $staticGraph);path=$GraphPath}
}
$reportPath=Join-Path $outDir 'correlated-diagnostics.json'
$failurePath=Join-Path $outDir 'failure-classification.json'
$tracePath=Join-Path $outDir 'trace-summary.json'
$lastPath=Join-Path $outDir 'last-error.json'
$report|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $reportPath -Encoding UTF8
[ordered]@{tested_sha=$ExpectedSha;apk_sha256=$ExpectedApkSha256.ToLowerInvariant();failures=@($failures);warnings=@($warnings)}|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $failurePath -Encoding UTF8
[ordered]@{tested_sha=$ExpectedSha;traces=@($traces.Values)}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $tracePath -Encoding UTF8
if($lastError){$lastError|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $lastPath -Encoding UTF8}
else{[ordered]@{tested_sha=$ExpectedSha;apk_sha256=$ExpectedApkSha256.ToLowerInvariant();result='NO_CLASSIFIED_ERROR'}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $lastPath -Encoding UTF8}

Write-Host "CORRELATED_DIAGNOSTICS=PASS events=$($events.Count) traces=$($traces.Count) failures=$($failures.Count) warnings=$($warnings.Count) frame_spikes=$($spikes.Count)"
if($lastError){Write-Host "LAST_ERROR=CLASSIFIED classification=$($lastError.classification) trace=$($lastError.trace) kind=$($lastError.kind)"}else{Write-Host 'LAST_ERROR=NONE_CLASSIFIED'}
Write-Host "CORRELATED_DIAGNOSTICS_REPORT=$reportPath"
