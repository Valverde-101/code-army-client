param(
  [string]$RepoRoot,
  [string]$ConfigPath,
  [ValidateSet('Desert','Snow')][string]$MapId='Desert'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path}
if([string]::IsNullOrWhiteSpace($ConfigPath)){$ConfigPath=Join-Path $RepoRoot 'src\config\army_config_base.json'}
if(-not(Test-Path -LiteralPath $ConfigPath -PathType Leaf)){throw "CAMPAIGN_AREA_CONFIG=FAIL path=$ConfigPath"}
$cfg=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$expected=if($MapId -eq 'Desert'){
  [ordered]@{
    DesertM=@{Mission='AREA_D_M_DIALOG1';Group='DesertM';Count=123;Money=20000;Intel=20}
    DesertN=@{Mission='AREA_D_N_INTRO_1';Group='DesertN';Count=161;Money=50000;Intel=50}
  }
}else{
  [ordered]@{
    AreaSnowLeft1=@{Mission='MAP_SETUP_SNOW_SW';Group='AreaSnowLeft1';Count=89;Money=20000;Intel=20}
    AreaSnowRight1=@{Mission='MAP_SETUP_SNOW_SE';Group='AreaSnowRight1';Count=116;Money=20000;Intel=20}
    AreaSnowLeft2=@{Mission='MAP_SETUP_SNOW_W';Group='AreaSnowLeft2';Count=64;Money=30000;Intel=30}
    AreaSnow2=@{Mission='MAP_SETUP_SNOW_C';Group='AreaSnow2';Count=90;Money=30000;Intel=30}
    AreaSnowRight2=@{Mission='MAP_SETUP_SNOW_E';Group='AreaSnowRight2';Count=80;Money=30000;Intel=30}
    AreaSnowLeft3=@{Mission='MAP_SETUP_SNOW_NW';Group='AreaSnowLeft3';Count=65;Money=40000;Intel=40}
    AreaSnow3=@{Mission='MAP_SETUP_SNOW_N';Group='AreaSnow3';Count=69;Money=40000;Intel=40}
    AreaSnowRight3=@{Mission='MAP_SETUP_SNOW_NE';Group='AreaSnowRight3';Count=42;Money=40000;Intel=40}
  }
}
if($null -eq $cfg.MapSetup -or $null -eq $cfg.MapArea -or $null -eq $cfg.ShopArea -or
   $null -eq $cfg.Mission -or $null -eq $cfg.MissionSetup){throw "CAMPAIGN_AREA_CONFIG=FAIL map=$MapId missing_authored_tables"}
if($null -eq $cfg.ShopTab -or $null -eq $cfg.ShopTab.Areas -or [string]$cfg.ShopTab.Areas.ItemTable -cne 'ShopArea'){throw "CAMPAIGN_AREA_SHOP=FAIL map=$MapId table"}
$mapProperty=$cfg.MapSetup.PSObject.Properties[$MapId]
if($null -eq $mapProperty){throw "CAMPAIGN_AREA_CONFIG=FAIL missing_map=$MapId"}
$defaultRef=[string]$mapProperty.Value.DefaultArea
$defaultId=$defaultRef.Replace('#MapArea.','')
$expectedDefault=if($MapId -eq 'Desert'){'DesertS'}else{'AreaSnow1'}
if($defaultRef -cne ('#MapArea.'+$expectedDefault)){throw "CAMPAIGN_AREA_CONFIG=FAIL map=$MapId default=$defaultRef expected=$expectedDefault"}
$shopRefs=@($cfg.ShopArea.PSObject.Properties|ForEach-Object{$_.Value}|Where-Object{$null -ne $_ -and $null -ne $_.Item}|ForEach-Object{[string]$_.Item})
if(@($shopRefs|Where-Object{$_ -ceq $defaultRef}).Count -ne 0){throw "CAMPAIGN_AREA_SHOP=FAIL default_in_shop=$defaultRef"}
$areas=@($cfg.MapArea.PSObject.Properties|ForEach-Object{$_.Value}|Where-Object{[string]$_.MapID -ceq $MapId})
if($areas.Count -ne ($expected.Count+1)){throw "CAMPAIGN_AREA_CONFIG=FAIL map=$MapId expected_areas=$($expected.Count+1) actual=$($areas.Count)"}
$purchaseIds=@($areas|Where-Object{[string]$_.ID -cne $defaultId}|ForEach-Object{[string]$_.ID})
foreach($id in $purchaseIds){if($null -eq $expected[$id]){throw "CAMPAIGN_AREA_SCOPE=FAIL unknown_purchasable=$id"}}
$allStages=@($cfg.Mission.PSObject.Properties|ForEach-Object{$_.Value}|Where-Object{
  $groupProperty=$_.PSObject.Properties['SetupGroup']
  $null -ne $groupProperty -and [string]$_.MapId -ceq $MapId -and
    -not [string]::IsNullOrWhiteSpace([string]$groupProperty.Value)
})
$allSetup=@($cfg.MissionSetup.PSObject.Properties|ForEach-Object{$_.Value})
$total=0
foreach($id in $expected.Keys){
  $spec=$expected[$id]
  $areaProperty=$cfg.MapArea.PSObject.Properties[$id]
  $stageProperty=$cfg.Mission.PSObject.Properties[[string]$spec.Mission]
  if($null -eq $areaProperty -or $null -eq $stageProperty){throw "CAMPAIGN_AREA_CONTENT=FAIL missing_area_or_stage=$id"}
  $area=$areaProperty.Value;$stage=$stageProperty.Value
  $ref='#MapArea.'+$id
  $matches=@($shopRefs|Where-Object{$_ -ceq $ref}).Count
  if($matches -ne 1){throw "CAMPAIGN_AREA_SHOP=FAIL map=$MapId area=$id count=$matches"}
  if([string]$area.ID -cne $id -or [string]$area.MapID -cne $MapId -or [string]$area.Type -cne 'Area' -or
     [string]$stage.ID -cne [string]$spec.Mission -or [string]$stage.MapId -cne $MapId -or
     [string]$stage.SetupGroup -cne [string]$spec.Group){throw "CAMPAIGN_AREA_CONTENT=FAIL source_identity=$id"}
  if([int]$area.CostMoney -ne [int]$spec.Money -or [int]$area.CostIntel -ne [int]$spec.Intel){throw "CAMPAIGN_AREA_SCOPE=FAIL source_price_changed=$id"}
  $requiredMissionProperty=$area.PSObject.Properties['RequiredMission']
  $requiredMission=if($null -ne $requiredMissionProperty){[string]$requiredMissionProperty.Value}else{''}
  $hasOriginalGate=-not [string]::IsNullOrWhiteSpace($requiredMission)
  if(-not $hasOriginalGate){
    foreach($gateName in @('RequiredLevel','RequiredAllies','RequiredItem','RequiredBuilding','CostIntel')){
      $gateProperty=$area.PSObject.Properties[$gateName]
      if($null -eq $gateProperty){continue}
      if($gateName -in @('RequiredLevel','RequiredAllies','CostIntel')){
        if([int]$gateProperty.Value -gt 0){$hasOriginalGate=$true}
      }elseif(-not [string]::IsNullOrWhiteSpace([string]$gateProperty.Value)){
        $hasOriginalGate=$true
      }
    }
  }
  if(-not $hasOriginalGate){throw "CAMPAIGN_AREA_UNLOCK=FAIL no_original_gate id=$id"}
  if(-not [string]::IsNullOrWhiteSpace($requiredMission)){
    if($requiredMission -match '^#Mission\.([A-Za-z0-9_]+)$'){
      $requiredMissionId=$Matches[1]
      if($null -eq $cfg.Mission.PSObject.Properties[$requiredMissionId]){throw "CAMPAIGN_AREA_UNLOCK=FAIL unresolved_required_mission id=$id mission=$requiredMission"}
    }else{throw "CAMPAIGN_AREA_UNLOCK=FAIL malformed_required_mission id=$id value=$requiredMission"}
  }
  $candidateCount=0;$selectedCount=0
  foreach($candidate in $allStages){
    $rows=@($allSetup|Where-Object{[string]$_.Group -ceq [string]$candidate.SetupGroup})
    if($rows.Count -eq 0){continue}
    $inside=$true
    foreach($row in $rows){
      $raw=[string]$row.Item
      if($raw -notmatch '^#([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)$'){throw "CAMPAIGN_AREA_CONTENT=FAIL invalid_object_reference stage=$($candidate.ID) item=$raw"}
      $table=$cfg.PSObject.Properties[$Matches[1]]
      if($null -eq $table -or $null -eq $table.Value.PSObject.Properties[$Matches[2]]){throw "CAMPAIGN_AREA_CONTENT=FAIL missing_object stage=$($candidate.ID) item=$raw"}
      $item=$table.Value.PSObject.Properties[$Matches[2]].Value
      $dx=if($null -ne $item.PSObject.Properties['DimX']){[int]$item.DimX}else{1}
      $dy=if($null -ne $item.PSObject.Properties['DimY']){[int]$item.DimY}else{1}
      $x=[int]$row.AreaX;$y=[int]$row.AreaY
      if($dx -lt 1 -or $dy -lt 1){throw "CAMPAIGN_AREA_CONTENT=FAIL object_dimensions=$raw"}
      if($x -lt [int]$area.AreaX -or $y -lt [int]$area.AreaY -or
         ($x+$dx) -gt ([int]$area.AreaX+[int]$area.AreaWidth) -or
         ($y+$dy) -gt ([int]$area.AreaY+[int]$area.AreaHeight)){$inside=$false;break}
    }
    if($inside){$candidateCount++;if([string]$candidate.ID -ceq [string]$spec.Mission){$selectedCount=$rows.Count}}
  }
  if($candidateCount -ne 1 -or $selectedCount -ne [int]$spec.Count){throw "CAMPAIGN_AREA_CONTENT=FAIL map=$MapId area=$id stage=$($spec.Mission) candidates=$candidateCount objects=$selectedCount expected=$($spec.Count)"}
  $total+=$selectedCount
  Write-Host "CAMPAIGN_AREA_CONTENT=PASS map=$MapId area=$id mission=$($spec.Mission) original_objects=$selectedCount price=$($area.CostMoney) intel_original=$($area.CostIntel)"
}
$areaSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\items\AreaItem.as') -Raw
$manager=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\missions\MissionManager.as') -Raw
$state=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\states\GameState.as') -Raw
$world=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\gui\popups\WorldMapWindow.as') -Raw
$patch=Get-Content -LiteralPath (Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1') -Raw
foreach($needle in @('OFFLINE_CAMPAIGN_CONTENT_SETUP:Boolean = true','Config.OFFLINE_MODE','param1 == "Desert" || param1 == "Snow"')){
  if(-not $areaSource.Contains($needle)){throw "CAMPAIGN_AREA_SOURCE=FAIL content_setup_missing=$needle"}
}
foreach($needle in @('TEST_HOME_NORTH_PURCHASE','TEST_CAMPAIGN_AREA_PURCHASE',
 'mRequiredMission = null;','mRequiredLevel = 0;','mRequiredAllies = 0;',
 'mRequiredItem = null;','mRequiredBuilding = null;','mCostIntel = 0;')){
  if($areaSource.Contains($needle)){throw "CAMPAIGN_AREA_UNLOCK=FAIL requirement_override=$needle"}
}
if(-not $areaSource.Contains('return super.isUnlocked()')){throw 'CAMPAIGN_AREA_UNLOCK=FAIL original_isUnlocked_missing'}
if(-not $world.Contains('return !MissionManager.isMapLocked(WORLD_MAP_ID_LIST[param1]);')){throw 'CAMPAIGN_MAP_UNLOCK=FAIL normal_route_missing'}
if($world -match 'if\s*\(\s*Config\.OFFLINE_MODE\s*&&\s*\(\s*param1\s*==\s*0\s*\|\|\s*param1\s*==\s*1\s*\)\s*\)\s*\{\s*return\s+true\s*;'){throw 'CAMPAIGN_MAP_UNLOCK=FAIL offline_force_open'}
foreach($id in $expected.Keys){if(-not $areaSource.Contains('param2 == "'+$id+'"')){throw "CAMPAIGN_AREA_SCOPE=FAIL trial_allowlist=$id"}}
if($areaSource.Contains('param2 == "DesertS"') -or $areaSource.Contains('param2 == "AreaSnow1"')){throw 'CAMPAIGN_AREA_SCOPE=FAIL default_area_in_allowlist'}
foreach($needle in @('ensureTrialCampaignAreaContent','AreaItem.isTrialCampaignArea','mission.getSetupObjectCount()','matches != 1','matched.mState != Mission.STATE_INACTIVE','matched.activate(true);','CAMPAIGN_AREA_SETUP_UNRESOLVED')){
  if(-not $manager.Contains($needle)){throw "CAMPAIGN_AREA_SOURCE=FAIL missing=$needle"}
}
if(-not $state.Contains('MissionManager.ensureTrialCampaignAreaContent(param1.mId)')){throw 'CAMPAIGN_AREA_SOURCE=FAIL purchase_hook'}
if($areaSource -match 'mCostMoney\s*=|mCostPremium\s*=|smUnlockCheat\s*=|mEarlyUnlockBought\s*='){throw 'CAMPAIGN_AREA_SCOPE=FAIL global_cheat_or_free_purchase'}
foreach($class in @('game.items.AreaItem','game.missions.MissionManager','game.states.GameState')){
  if(-not $patch.Contains("Class='$class'")){throw "CAMPAIGN_AREA_SWF=FAIL missing=$class"}
}
Write-Host "CAMPAIGN_AREA_UNLOCK_CONTRACT=PASS map=$MapId areas=$($expected.Count) authored_objects=$total default=$defaultId excluded shop_entries=present original_gates_and_costs=preserved setup=original_only"
