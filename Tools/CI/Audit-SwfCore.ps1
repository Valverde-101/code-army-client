param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$ExpectedSha,
  [string]$OutputRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Resolve-Git {
  $cmd=Get-Command git.exe -ErrorAction SilentlyContinue
  if($cmd){return $cmd.Source}
  $cmd=Get-Command git -ErrorAction SilentlyContinue
  if($cmd){return $cmd.Source}
  foreach($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue){
    if(-not $drive.Root){continue}
    foreach($candidate in @((Join-Path $drive.Root 'AndroidBuild\Tools\Git\cmd\git.exe'),(Join-Path $drive.Root 'AndroidBuild\PortableGit\cmd\git.exe'))){
      if(Test-Path -LiteralPath $candidate){return $candidate}
    }
  }
  throw 'SWF_CORE_AUDIT=FAIL git_not_found'
}

$repo=(Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$git=Resolve-Git
$head=(& $git -C $repo rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0){throw 'SWF_CORE_AUDIT=FAIL git_head'}
if($ExpectedSha -and $head -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$head"}
Write-Host "SWF_CORE_AUDIT_HEAD=PASS sha=$head"

$srcRoot=Join-Path $repo 'src'
if(-not (Test-Path -LiteralPath $srcRoot)){throw "SWF_CORE_AUDIT=FAIL src_missing=$srcRoot"}
if(-not $OutputRoot){$OutputRoot=Join-Path $repo ".work\reports\core-audit\$head"}
New-Item -ItemType Directory -Force -Path $OutputRoot|Out-Null

$asFiles=@(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter '*.as' -ErrorAction Stop)
if($asFiles.Count -lt 100){throw "SWF_CORE_AUDIT=FAIL suspicious_as_file_count=$($asFiles.Count)"}

$rows=New-Object System.Collections.Generic.List[object]
$total=[ordered]@{
  action_script_files=$asFiles.Count
  lines=0
  add_event_listener=0
  remove_event_listener=0
  timer_allocations=0
  repeating_timer_candidates=0
  bitmapdata_allocations=0
  bitmap_dispose_calls=0
  enter_frame_hooks=0
  mouse_move_hooks=0
  http_literals=0
  todo_fixme=0
  throw_not_implemented=0
  get_definition_by_name=0
}

foreach($file in $asFiles){
  $text=Get-Content -LiteralPath $file.FullName -Raw
  $lineCount=([regex]::Matches($text,"`n")).Count+1
  $add=([regex]::Matches($text,'\.addEventListener\s*\(')).Count
  $remove=([regex]::Matches($text,'\.removeEventListener\s*\(')).Count
  $timers=([regex]::Matches($text,'new\s+Timer\s*\(')).Count
  $singleShot=([regex]::Matches($text,'new\s+Timer\s*\([^,\r\n]+,\s*1\s*\)')).Count
  $repeat=[Math]::Max(0,$timers-$singleShot)
  $bitmap=([regex]::Matches($text,'new\s+BitmapData\s*\(')).Count
  $dispose=([regex]::Matches($text,'\.dispose\s*\(')).Count
  $enterFrame=([regex]::Matches($text,'Event\.ENTER_FRAME')).Count
  $mouseMove=([regex]::Matches($text,'MouseEvent\.MOUSE_MOVE')).Count
  $http=([regex]::Matches($text,'https?://','IgnoreCase')).Count
  $todo=([regex]::Matches($text,'\b(TODO|FIXME|HACK)\b','IgnoreCase')).Count
  $notImpl=([regex]::Matches($text,'throw\s+new\s+Error\s*\([^\)]*(not implemented|unimplemented)','IgnoreCase')).Count
  $defs=([regex]::Matches($text,'getDefinitionByName\s*\(')).Count
  $rel=$file.FullName.Substring($repo.Length).TrimStart('\').Replace('\','/')
  $listenerDelta=$add-$remove
  $riskScore=($repeat*3)+($bitmap*4)+([Math]::Max(0,$listenerDelta)*2)+($enterFrame*4)+($mouseMove*2)+($http*2)+($notImpl*8)
  $rows.Add([pscustomobject]@{
    path=$rel
    lines=$lineCount
    add_event_listener=$add
    remove_event_listener=$remove
    listener_delta=$listenerDelta
    timer_allocations=$timers
    repeating_timer_candidates=$repeat
    bitmapdata_allocations=$bitmap
    bitmap_dispose_calls=$dispose
    enter_frame_hooks=$enterFrame
    mouse_move_hooks=$mouseMove
    http_literals=$http
    todo_fixme=$todo
    throw_not_implemented=$notImpl
    get_definition_by_name=$defs
    risk_score=$riskScore
  })
  $total.lines+=$lineCount
  $total.add_event_listener+=$add
  $total.remove_event_listener+=$remove
  $total.timer_allocations+=$timers
  $total.repeating_timer_candidates+=$repeat
  $total.bitmapdata_allocations+=$bitmap
  $total.bitmap_dispose_calls+=$dispose
  $total.enter_frame_hooks+=$enterFrame
  $total.mouse_move_hooks+=$mouseMove
  $total.http_literals+=$http
  $total.todo_fixme+=$todo
  $total.throw_not_implemented+=$notImpl
  $total.get_definition_by_name+=$defs
}

$hotspots=@($rows|Where-Object{$_.risk_score -gt 0}|Sort-Object risk_score -Descending, bitmapdata_allocations -Descending, repeating_timer_candidates -Descending|Select-Object -First 40)
$listenerRisks=@($rows|Where-Object{$_.listener_delta -ge 3}|Sort-Object listener_delta -Descending|Select-Object -First 30)
$bitmapRisks=@($rows|Where-Object{$_.bitmapdata_allocations -gt 0}|Sort-Object bitmapdata_allocations -Descending|Select-Object -First 30)
$timerRisks=@($rows|Where-Object{$_.repeating_timer_candidates -gt 0}|Sort-Object repeating_timer_candidates -Descending|Select-Object -First 30)
$networkRisks=@($rows|Where-Object{$_.http_literals -gt 0}|Sort-Object http_literals -Descending|Select-Object -First 30)

$configRoot=Join-Path $srcRoot 'config'
$configFiles=@()
if(Test-Path -LiteralPath $configRoot){$configFiles=@(Get-ChildItem -LiteralPath $configRoot -Recurse -File -Include '*.json','*.xml','*.csv' -ErrorAction SilentlyContinue)}
$mapSetupHits=0
$desertHits=0
$pvpHits=0
foreach($f in $configFiles){
  $t=Get-Content -LiteralPath $f.FullName -Raw
  $mapSetupHits+=([regex]::Matches($t,'MapSetup','IgnoreCase')).Count
  $desertHits+=([regex]::Matches($t,'Desert','IgnoreCase')).Count
  $pvpHits+=([regex]::Matches($t,'pvp_','IgnoreCase')).Count
}

$report=[ordered]@{
  schema_version=1
  repository='Valverde-101/code-army-client'
  tested_sha=$head
  generated_utc=[DateTime]::UtcNow.ToString('o')
  totals=$total
  config_inventory=[ordered]@{files=$configFiles.Count;mapsetup_references=$mapSetupHits;desert_references=$desertHits;pvp_map_references=$pvpHits}
  hotspots=$hotspots
  listener_imbalance_candidates=$listenerRisks
  bitmap_allocation_candidates=$bitmapRisks
  repeating_timer_candidates=$timerRisks
  network_dependency_candidates=$networkRisks
  interpretation=@(
    'Candidates are static signals, not proof of a leak or defect.',
    'Prioritize high-frequency render/update paths with BitmapData allocations or repeating timers.',
    'Listener deltas require lifecycle inspection because some listeners are intentionally process-long.',
    'HTTP literals identify online coupling that may need an offline implementation or explicit fail-fast path.'
  )
}
$json=Join-Path $OutputRoot 'SWF-CORE-AUDIT.json'
$csv=Join-Path $OutputRoot 'SWF-CORE-AUDIT-files.csv'
$md=Join-Path $OutputRoot 'SWF-CORE-AUDIT.md'
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $json -Encoding UTF8
$rows|Sort-Object risk_score -Descending,path|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

$lines=New-Object System.Collections.Generic.List[string]
$lines.Add('# Army Attack SWF/Core static audit')
$lines.Add('')
$lines.Add("TESTED_SHA: $head")
$lines.Add("AS files: $($total.action_script_files); lines: $($total.lines)")
$lines.Add("Listeners add/remove: $($total.add_event_listener)/$($total.remove_event_listener)")
$lines.Add("Timer allocations: $($total.timer_allocations); repeating candidates: $($total.repeating_timer_candidates)")
$lines.Add("BitmapData allocations/dispose calls: $($total.bitmapdata_allocations)/$($total.bitmap_dispose_calls)")
$lines.Add("ENTER_FRAME hooks: $($total.enter_frame_hooks); MOUSE_MOVE hooks: $($total.mouse_move_hooks)")
$lines.Add("HTTP literals: $($total.http_literals); TODO/FIXME/HACK: $($total.todo_fixme); not-implemented throws: $($total.throw_not_implemented)")
$lines.Add('')
$lines.Add('## Highest static-risk files')
foreach($h in ($hotspots|Select-Object -First 20)){$lines.Add("- $($h.path): risk=$($h.risk_score), bitmap=$($h.bitmapdata_allocations), timers=$($h.repeating_timer_candidates), listener_delta=$($h.listener_delta), enter_frame=$($h.enter_frame_hooks), mouse_move=$($h.mouse_move_hooks), http=$($h.http_literals)")}
$lines.Add('')
$lines.Add('This report is an audit queue. Each candidate still requires source/lifecycle review and a focused regression before modification.')
$lines|Set-Content -LiteralPath $md -Encoding UTF8

Write-Host "SWF_CORE_AUDIT=PASS sha=$head as_files=$($total.action_script_files) lines=$($total.lines) bitmap_allocations=$($total.bitmapdata_allocations) repeating_timers=$($total.repeating_timer_candidates) listener_add=$($total.add_event_listener) listener_remove=$($total.remove_event_listener) http_literals=$($total.http_literals)"
Write-Host "SWF_CORE_AUDIT_JSON=$json"
Write-Host "SWF_CORE_AUDIT_REPORT=$md"
