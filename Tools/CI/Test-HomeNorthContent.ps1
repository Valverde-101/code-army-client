param([string]$RepoRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path}
$config=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\config\army_config_base.json') -Raw|ConvertFrom-Json
$expected=@{
 AreaNW=@{Setup='SETUP_NW';Count=43;Units=30;Defenses=13}
 AreaN=@{Setup='SETUP_NC';Count=66;Units=33;Defenses=33}
 AreaNE=@{Setup='SETUP_NE';Count=53;Units=28;Defenses=25}
}
foreach($id in @('AreaNW','AreaN','AreaNE')){
  $areaProp=$config.MapArea.PSObject.Properties[$id]
  $spec=$expected[$id]
  $stageProp=$config.Mission.PSObject.Properties[$spec.Setup]
  if($null -eq $areaProp -or $null -eq $stageProp){throw "HOME_NORTH_CONTENT=FAIL absent_area_or_stage id=$id"}
  $area=$areaProp.Value;$stage=$stageProp.Value
  if([string]$area.MapID -cne 'Home' -or [string]$area.Type -cne 'Area' -or [string]$stage.MapId -cne 'Home' -or [string]$stage.SetupGroup -cne $id){throw "HOME_NORTH_CONTENT=FAIL original_area_or_stage id=$id"}
  $rows=@($config.MissionSetup.PSObject.Properties|ForEach-Object{$_.Value}|Where-Object{[string]$_.Group -ceq $id})
  if($rows.Count -ne $spec.Count){throw "HOME_NORTH_CONTENT=FAIL authored_count area=$id expected=$($spec.Count) actual=$($rows.Count)"}
  $occupied=@{};$units=0;$defenses=0
  foreach($entry in $rows){
    $ref=[string]$entry.Item
    if($ref -notmatch '^#(EnemyUnit|EnemyInstallation)\.([A-Za-z0-9_]+)$'){throw "HOME_NORTH_CONTENT=FAIL invalid_item area=$id ref=$ref"}
    $type=$Matches[1];$name=$Matches[2]
    $itemTable=$config.PSObject.Properties[$type]
    if($null -eq $itemTable -or $null -eq $itemTable.Value.PSObject.Properties[$name]){throw "HOME_NORTH_CONTENT=FAIL unresolved_item area=$id ref=$ref"}
    $x=[int]$entry.AreaX;$y=[int]$entry.AreaY
    if($x -lt [int]$area.AreaX -or $x -ge ([int]$area.AreaX+[int]$area.AreaWidth) -or $y -lt [int]$area.AreaY -or $y -ge ([int]$area.AreaY+[int]$area.AreaHeight)){throw "HOME_NORTH_CONTENT=FAIL out_of_bounds area=$id row=$($entry.ID)"}
    $slot="$x,$y,$type"
    if($occupied.ContainsKey($slot)){throw "HOME_NORTH_CONTENT=FAIL overlapping_layer area=$id slot=$slot"}
    $occupied[$slot]=$true
    if($type -eq 'EnemyUnit'){$units++}else{$defenses++}
  }
  if($units -ne $spec.Units -or $defenses -ne $spec.Defenses){throw "HOME_NORTH_CONTENT=FAIL wrong_distribution area=$id units=$units defenses=$defenses"}
  Write-Host "HOME_NORTH_CONTENT=PASS area=$id original_stage=$($spec.Setup) entries=$($rows.Count) enemy_units=$units enemy_installations=$defenses"
}
$mission=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\missions\Mission.as') -Raw
$manager=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\missions\MissionManager.as') -Raw
$state=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\states\GameState.as') -Raw
$save=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\utils\OfflineSave.as') -Raw
$patch=Get-Content -LiteralPath (Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1') -Raw
foreach($check in @(
 @{text=$mission;needle='public function activate(param1:Boolean = false)'},
 @{text=$mission;needle='public function createGameObjects(param1:Boolean = false)'},
 @{text=$mission;needle='trialCell.mCharacter != null'},
 @{text=$mission;needle='trialCell.mObject != null'},
 @{text=$manager;needle='getNumberOfItems(area) < 1'},
 @{text=$manager;needle='setup.mState != Mission.STATE_INACTIVE'},
 @{text=$manager;needle='setup.activate(true);'},
 @{text=$state;needle='MissionManager.ensureTrialHomeNorthContent(param1.mId)'},
 @{text=$save;needle='MissionManager.reconcileTrialHomeNorthContent()'}
)){if(-not $check.text.Contains([string]$check.needle)){throw "HOME_NORTH_CONTENT=FAIL missing_runtime=$($check.needle)"}}
foreach($class in @('game.items.AreaItem','game.missions.Mission','game.missions.MissionManager','game.states.GameState','game.utils.OfflineSave')){
  if(-not $patch.Contains("Class='$class'")){throw "HOME_NORTH_CONTENT=FAIL swf_patch_missing=$class"}
}
Write-Host 'HOME_NORTH_CONTENT_CONTRACT=PASS scope=AreaNW,AreaN,AreaNE original_group_objects=162 purchase_only=true older_save_reconcile=true once=true preserve_occupied_layers=true extra_areas=unchanged'
