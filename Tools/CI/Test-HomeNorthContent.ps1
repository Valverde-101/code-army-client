param([string]$RepoRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path}
$config=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\config\army_config_base.json') -Raw|ConvertFrom-Json
$expected=[ordered]@{
 AreaNW=@{Setup='SETUP_NW';Group='AreaNW';Count=43;Units=30;Defenses=13;Civilian=0}
 AreaN=@{Setup='SETUP_NC';Group='AreaN';Count=66;Units=33;Defenses=33;Civilian=0}
 AreaNE=@{Setup='SETUP_NE';Group='AreaNE';Count=53;Units=28;Defenses=25;Civilian=0}
 AreaNorthW2=@{Setup='SETUP_NORTHW2';Group='AreaNorthW';Count=80;Units=27;Defenses=53;Civilian=0}
 AreaNorthC2=@{Setup='SETUP_NORTHC2';Group='AreaNorthC';Count=77;Units=44;Defenses=33;Civilian=0}
 AreaNorthE2=@{Setup='SETUP_NORTHE2';Group='AreaNorthE';Count=69;Units=45;Defenses=23;Civilian=1}
}
$total=0;$upper=0
foreach($id in $expected.Keys){
  $spec=$expected[$id]
  $areaProp=$config.MapArea.PSObject.Properties[$id]
  $stageProp=$config.Mission.PSObject.Properties[[string]$spec.Setup]
  if($null -eq $areaProp -or $null -eq $stageProp){throw "HOME_NORTH_CONTENT=FAIL missing_area_or_mission id=$id"}
  $area=$areaProp.Value;$stage=$stageProp.Value
  if([string]$area.ID -cne $id -or [string]$area.MapID -cne 'Home' -or
     [string]$stage.MapId -cne 'Home' -or [string]$stage.SetupGroup -cne [string]$spec.Group){
    throw "HOME_NORTH_CONTENT=FAIL source_group_mapping id=$id group=$($stage.SetupGroup)"
  }
  $rows=@($config.MissionSetup.PSObject.Properties|ForEach-Object{$_.Value}|Where-Object{[string]$_.Group -ceq [string]$spec.Group})
  if($rows.Count -ne [int]$spec.Count){throw "HOME_NORTH_CONTENT=FAIL authored_count area=$id expected=$($spec.Count) actual=$($rows.Count)"}
  $occupied=@{};$units=0;$defenses=0;$civilian=0
  foreach($entry in $rows){
    $ref=[string]$entry.Item
    if($ref -notmatch '^#(EnemyUnit|EnemyInstallation|PermanentHFE)\.([A-Za-z0-9_]+)$'){throw "HOME_NORTH_CONTENT=FAIL invalid_item area=$id ref=$ref"}
    $type=$Matches[1];$name=$Matches[2]
    $table=$config.PSObject.Properties[$type]
    if($null -eq $table -or $null -eq $table.Value.PSObject.Properties[$name]){throw "HOME_NORTH_CONTENT=FAIL unresolved_item area=$id ref=$ref"}
    $item=$table.Value.PSObject.Properties[$name].Value
    $x=[int]$entry.AreaX;$y=[int]$entry.AreaY
    $dx=if($null -ne $item.PSObject.Properties['DimX']){[int]$item.DimX}else{1}
    $dy=if($null -ne $item.PSObject.Properties['DimY']){[int]$item.DimY}else{1}
    if($dx -lt 1 -or $dy -lt 1 -or $x -lt [int]$area.AreaX -or
       ($x+$dx) -gt ([int]$area.AreaX+[int]$area.AreaWidth) -or
       $y -lt [int]$area.AreaY -or
       ($y+$dy) -gt ([int]$area.AreaY+[int]$area.AreaHeight)){
      throw "HOME_NORTH_CONTENT=FAIL footprint area=$id row=$($entry.ID) x=$x y=$y dx=$dx dy=$dy"
    }
    $slot="$x,$y,$type"
    if($occupied.ContainsKey($slot)){throw "HOME_NORTH_CONTENT=FAIL duplicate_layer area=$id slot=$slot"}
    $occupied[$slot]=$true
    if($type -eq 'EnemyUnit'){$units++}
    elseif($type -eq 'EnemyInstallation'){$defenses++}
    else{
      if($id -cne 'AreaNorthE2' -or $name -cne 'NCTown'){throw "HOME_NORTH_CONTENT=FAIL unexpected_civilian area=$id ref=$ref"}
      $civilian++
    }
  }
  if($units -ne [int]$spec.Units -or $defenses -ne [int]$spec.Defenses -or $civilian -ne [int]$spec.Civilian){
    throw "HOME_NORTH_CONTENT=FAIL distribution area=$id units=$units defenses=$defenses civilian=$civilian"
  }
  $total+=$rows.Count
  if($id.StartsWith('AreaNorth')){$upper+=$rows.Count}
  Write-Host "HOME_NORTH_CONTENT=PASS area=$id stage=$($spec.Setup) group=$($spec.Group) entries=$($rows.Count) enemy_units=$units enemy_installations=$defenses civilian=$civilian"
}
if($total -ne 388 -or $upper -ne 226){throw "HOME_NORTH_CONTENT=FAIL total=$total upper=$upper"}
$mission=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\missions\Mission.as') -Raw
$manager=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\missions\MissionManager.as') -Raw
$state=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\states\GameState.as') -Raw
$save=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\utils\OfflineSave.as') -Raw
$patch=Get-Content -LiteralPath (Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1') -Raw
foreach($needle in @('public function activate(param1:Boolean = false)','public function createGameObjects(param1:Boolean = false)',
 'trialCell.mCharacter != null','trialCell.mObject != null',
 '(_loc7_.mType == "EnemyInstallation" || _loc7_.mType == "PermanentHFE")')){
 if(-not $mission.Contains($needle)){throw "HOME_NORTH_CONTENT=FAIL mission_runtime=$needle"}
}
foreach($needle in @('getNumberOfItems(area) < 1','setup.mState != Mission.STATE_INACTIVE','setup.activate(true);',
 'setupId = "SETUP_NORTHW2"; expectedCount = 80;',
 'setupId = "SETUP_NORTHC2"; expectedCount = 77;',
 'setupId = "SETUP_NORTHE2"; expectedCount = 69;',
 'smNodes = new Array();')){
 if(-not $manager.Contains($needle)){throw "HOME_NORTH_CONTENT=FAIL manager_runtime=$needle"}
}
# Both assignment sites must remain normalized; the V32 overlay handles an older
# checkout and must be idempotent for this updated source.
$normalizedCount=[regex]::Matches($manager,'smNodes[ \t]*=[ \t]*new[ \t]+Array[ \t]*\(\)[ \t]*;').Count
if($normalizedCount -ne 2 -or [regex]::IsMatch($manager,'smNodes[ \t]*=[ \t]*new[ \t]+Array[ \t]*;')){
 throw "HOME_NORTH_WINDOWS_REGRESSION=FAIL smNodes_constructors expected=2 actual=$normalizedCount"
}
if(-not $state.Contains('MissionManager.ensureTrialHomeNorthContent(param1.mId)')){throw 'HOME_NORTH_CONTENT=FAIL purchase_hook_missing'}
if(-not $save.Contains('MissionManager.reconcileTrialHomeNorthContent()')){throw 'HOME_NORTH_CONTENT=FAIL restore_hook_missing'}
$overlay=Get-Content -LiteralPath (Join-Path $RepoRoot 'Tools\CI\Invoke-AndroidEvidenceRootFixOverlayV32.ps1') -Raw
if(-not $overlay.Contains("already_normalized=") -or -not $overlay.Contains("normalized_match_count=")){throw 'HOME_NORTH_CONTENT=FAIL rootfix_v32_non_idempotent'}
foreach($class in @('game.items.AreaItem','game.missions.Mission','game.missions.MissionManager','game.states.GameState','game.utils.OfflineSave')){
 if(-not $patch.Contains("Class='$class'")){throw "HOME_NORTH_CONTENT=FAIL swf_patch_missing=$class"}
}
Write-Host 'HOME_NORTH_WINDOWS_REGRESSION=PASS ffdec_array_constructor=true android_overlay_idempotent=true'
Write-Host 'HOME_NORTH_CITY_OCCUPANCY=PASS city=NCTown no_double_object_placement=true'
Write-Host 'HOME_NORTH_CONTENT_CONTRACT=PASS scope=six_home_north_regions original_objects=388 new_upper_objects=226 city=NCTown once_only=true preserve_occupied_layers=true save_migration=true'
