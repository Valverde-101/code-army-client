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
    $k=$part.Substring(0,$i).Trim();$v=$part.Substring($i+1).Trim()
    if($k -and -not $map.Contains($k)){$map[$k]=$v}
  }
  return $map
}

function Classify-Event([string]$Kind,[string]$Detail,[System.Collections.IDictionary]$Kv){
  $classification='';$severity='ERROR'
  switch -Regex ($Kind){
    '^BOOT_TRANSITION_FAILURE$' {$classification='BOOT_TRANSITION_STALLED'}
    '^ASSET_LOAD_ERROR$' {
      if(($Kv.Contains('url') -and [string]$Kv['url'] -match '^\.\./') -or $Detail -match '\.\./'){$classification='APK_ASSET_PATH_MISMATCH'}
      else{$classification='APK_ASSET_LOAD_FAILURE'}
    }
    '^(SWF_CLASS_MISS|SWF_RESOURCE_SYMBOL_MISS|SWF_OPFOR_STRICT_MISS)$' {$classification='SWF_SYMBOL_MISSING'}
    '^SWF_RESOURCE_DOMAIN_ERROR$' {$classification='SWF_RESOURCE_DOMAIN_ERROR'}
    '^SWF_CLASS_IDENTITY_MISMATCH$' {$classification='SWF_CLASS_IDENTITY_MISMATCH'}
    '^SWF_EMBEDDED_SYMBOL_COLLISION$' {$classification='SWF_RESOURCE_ALIAS_COLLISION';$severity='WARN'}
    '^SWF_ALIAS_RISK$' {$classification='SWF_ALIAS_RISK';$severity='WARN'}
    '^(MAP_TRANSITION_FAIL|MAP_SWITCH_FAIL)$' {$classification='MAP_TRANSITION_STALLED'}
    '^PVP_POWERUP_EXECUTE_ERROR$' {$classification='PVP_POWERUP_RUNTIME_ERROR'}
    '^PVP_POWERUP_FIREMISSION_ERROR$' {$classification='PVP_FIREMISSION_QUEUE_ERROR'}
    '^PVP_FIREMISSION_START_ERROR$' {$classification='PVP_FIREMISSION_RUNTIME_ERROR'}
    '^PVP_ENEMY_MOVE_VISUAL_MISMATCH$' {$classification='SWF_CLASS_IDENTITY_MISMATCH'}
    '^FIREMISSION_GRAPHICS_MISS$' {$classification='SWF_SYMBOL_MISSING'}
    '^FIREMISSION_FALLBACK_MISS$' {$classification='FIREMISSION_VISUAL_MISSING'}
    '^DIAG_FAILURE$' {
      if($Kv.Contains('classification')){$classification=[string]$Kv['classification']}else{$classification='RUNTIME_DIAGNOSTIC_FAILURE'}
    }
  }
  if(-not $classification){return $null}
  return [pscustomobject]@{classification=$classification;severity=$severity}
}

function New-Row([int]$Seq,[string]$Kind,[string]$Detail,[System.Collections.IDictionary]$Kv,[string]$Trace,[string]$Classification,[string]$Severity){
  $row=[ordered]@{seq=$Seq;trace=$Trace;kind=$Kind;classification=$Classification;severity=$Severity;detail=$Detail}
  foreach($k in @('resource','symbol','resolved_class','domain','url','mission','unit','side','id','result','reason','error','message','from','to','target','phase')){
    if($Kv.Contains($k)){$row[$k]=[string]$Kv[$k]}
  }
  return [pscustomobject]$row
}

$root=(Resolve-Path -LiteralPath $EvidenceRoot -ErrorAction Stop).Path
$outDir=Join-Path $root 'correlated-diagnostics';New-Item -ItemType Directory -Force -Path $outDir|Out-Null
$summaryPath=Join-Path $root 'summary.json';$logcatPath=Join-Path $root 'logcat.txt'
$summary=$null
if(Test-Path -LiteralPath $summaryPath){try{$summary=Get-Content -LiteralPath $summaryPath -Raw|ConvertFrom-Json}catch{}}
if($summary -and [string]$summary.tested_sha -and [string]$summary.tested_sha -ne $ExpectedSha){throw "CORRELATED_DIAGNOSTICS=FAIL tested_sha expected=$ExpectedSha actual=$($summary.tested_sha)"}
if($summary -and [string]$summary.apk_sha256 -and ([string]$summary.apk_sha256).ToLowerInvariant() -ne $ExpectedApkSha256.ToLowerInvariant()){throw "CORRELATED_DIAGNOSTICS=FAIL apk_sha expected=$ExpectedApkSha256 actual=$($summary.apk_sha256)"}
if(-not(Test-Path -LiteralPath $logcatPath -PathType Leaf)){
  $reason=if($summary -and [string]$summary.reason){[string]$summary.reason}else{'logcat_missing'}
  $skip=[ordered]@{schema='armyattack-correlated-diagnostics/v2';tested_sha=$ExpectedSha;apk_sha256=$ExpectedApkSha256.ToLowerInvariant();result='SKIPPED_WITH_REASON';reason=$reason;generated_utc=[DateTime]::UtcNow.ToString('o')}
  $skip|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $outDir 'correlated-diagnostics.json') -Encoding UTF8
  $skip|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $outDir 'last-error.json') -Encoding UTF8
  Write-Host "CORRELATED_DIAGNOSTICS=SKIPPED_WITH_REASON reason=$reason";exit 0
}

$staticGraph=$null
if($GraphPath -and (Test-Path -LiteralPath $GraphPath -PathType Leaf)){try{$staticGraph=Get-Content -LiteralPath $GraphPath -Raw|ConvertFrom-Json}catch{}}
$events=New-Object System.Collections.ArrayList
$pattern='ArmyAttackGame\s*:\s*([A-Z0-9_]+)\s*(.*)$'
$seq=0;$activeTrace='BOOT-1';$mapSeq=0
foreach($line in Get-Content -LiteralPath $logcatPath){
  if($line -notmatch $pattern){continue}
  $seq++;$kind=[string]$matches[1];$detail=[string]$matches[2].Trim();$kv=Parse-Detail $detail
  $trace=if($kv.Contains('trace')){[string]$kv['trace']}else{''};$synthetic=$false
  if(-not $trace){
    if($kind -match '^(ASSET_|SWF_LOAD_|BOOT_)'){$trace='BOOT-1';$synthetic=$true}
    elseif($kind -match '^(WORLD_MAP_|MAP_)'){
      if($kind -match '(REQUEST|BEGIN)$' -or $activeTrace -eq 'BOOT-1'){$mapSeq++;$target=if($kv.Contains('to')){[string]$kv['to']}elseif($kv.Contains('target')){[string]$kv['target']}else{'unknown'};$activeTrace="MAP-$target-$mapSeq"}
      $trace=$activeTrace;$synthetic=$true
      if($kind -match '(COMMIT|FAIL|REJECT)$'){$activeTrace='BOOT-1'}
    }
  }
  [void]$events.Add([pscustomobject]@{seq=$seq;kind=$kind;detail=$detail;trace=$trace;trace_synthetic=$synthetic;kv=$kv})
}

$failures=New-Object System.Collections.ArrayList;$warnings=New-Object System.Collections.ArrayList
foreach($e in $events){
  $c=Classify-Event $e.kind $e.detail $e.kv
  if(-not $c){continue}
  $row=New-Row $e.seq $e.kind $e.detail $e.kv $e.trace $c.classification $c.severity
  if($staticGraph -and ($row.PSObject.Properties.Name -contains 'symbol') -and [string]$row.symbol){
    $symbol=[string]$row.symbol;$consumers=@($staticGraph.edges|Where-Object{[string]$_.symbol -eq $symbol}|Select-Object -First 25)
    if($consumers.Count -gt 0){$row|Add-Member -NotePropertyName static_consumers -NotePropertyValue $consumers}
  }
  if($c.severity -eq 'ERROR'){[void]$failures.Add($row)}else{[void]$warnings.Add($row)}
}

$traceMap=@{}
foreach($e in $events){
  if(-not $e.trace){continue}
  if(-not $traceMap.ContainsKey([string]$e.trace)){$traceMap[[string]$e.trace]=[ordered]@{trace=[string]$e.trace;first_seq=$e.seq;last_seq=$e.seq;event_count=0;kinds=[ordered]@{};classifications=@()}}
  $t=$traceMap[[string]$e.trace];$t.last_seq=$e.seq;$t.event_count=[int]$t.event_count+1
  if(-not $t.kinds.Contains($e.kind)){$t.kinds[$e.kind]=0};$t.kinds[$e.kind]=[int]$t.kinds[$e.kind]+1
}
foreach($r in @($failures)+@($warnings)){if($r.trace -and $traceMap.ContainsKey([string]$r.trace)){$traceMap[[string]$r.trace].classifications+=([string]$r.classification)}}

$last=if($failures.Count -gt 0){$failures[$failures.Count-1]}else{$null}
$report=[ordered]@{
  schema='armyattack-correlated-diagnostics/v2';repository='Valverde-101/code-army-client';tested_sha=$ExpectedSha;apk_sha256=$ExpectedApkSha256.ToLowerInvariant();result='PASS';generated_utc=[DateTime]::UtcNow.ToString('o');event_count=$events.Count;trace_count=$traceMap.Count;failure_count=$failures.Count;warning_count=$warnings.Count;last_error=$last;failures=@($failures|Select-Object -Last 200);warnings=@($warnings|Select-Object -Last 200);traces=@($traceMap.Values);static_graph=[ordered]@{available=($null -ne $staticGraph);path=$GraphPath}
}
$report|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $outDir 'correlated-diagnostics.json') -Encoding UTF8
[ordered]@{tested_sha=$ExpectedSha;apk_sha256=$ExpectedApkSha256.ToLowerInvariant();failures=@($failures);warnings=@($warnings)}|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $outDir 'failure-classification.json') -Encoding UTF8
[ordered]@{tested_sha=$ExpectedSha;traces=@($traceMap.Values)}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $outDir 'trace-summary.json') -Encoding UTF8
if($last){$last|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $outDir 'last-error.json') -Encoding UTF8}else{[ordered]@{tested_sha=$ExpectedSha;apk_sha256=$ExpectedApkSha256.ToLowerInvariant();result='NO_CLASSIFIED_ERROR'}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $outDir 'last-error.json') -Encoding UTF8}
Write-Host "CORRELATED_DIAGNOSTICS=PASS events=$($events.Count) traces=$($traceMap.Count) failures=$($failures.Count) warnings=$($warnings.Count)"
if($last){Write-Host "LAST_ERROR=CLASSIFIED classification=$($last.classification) trace=$($last.trace) kind=$($last.kind)"}else{Write-Host 'LAST_ERROR=NONE_CLASSIFIED'}
Write-Host "CORRELATED_DIAGNOSTICS_REPORT=$(Join-Path $outDir 'correlated-diagnostics.json')"
