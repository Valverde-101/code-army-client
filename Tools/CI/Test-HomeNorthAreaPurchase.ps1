param([string]$RepoRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path}
$configPath=Join-Path $RepoRoot 'src\config\army_config_base.json'
if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){throw "HOME_NORTH_CONFIG=FAIL missing=$configPath"}
$cfg=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json

# The shipped config holds ShopArea[*].Item as "#MapArea.AreaNW", NOT as
# an object with Item.ID / Item.Type. The loader resolves these references
# when building GameState.mConfig; validate the raw source contract here.
$targets=[ordered]@{
  AreaNW=[ordered]@{Name='#TID.AREA_NW_NAME';Mission='#Mission.MAP_LOCK_NW';Money=30000;Intel=25}
  AreaN=[ordered]@{Name='#TID.AREA_N_NAME';Mission='#Mission.MAP_LOCK_NC';Money=50000;Intel=30}
  AreaNE=[ordered]@{Name='#TID.AREA_NE_NAME';Mission='#Mission.MAP_LOCK_NE';Money=100000;Intel=40}
}
if($null -eq $cfg.MapArea -or $null -eq $cfg.ShopTab -or $null -eq $cfg.ShopTab.Areas){throw 'HOME_NORTH_CONFIG=FAIL areas_or_shop_missing'}
$tableName=[string]$cfg.ShopTab.Areas.ItemTable
if($tableName -ne 'ShopArea' -or $null -eq $cfg.PSObject.Properties[$tableName]){throw "HOME_NORTH_SHOP=FAIL item_table=$tableName"}
$rawTable=$cfg.PSObject.Properties[$tableName].Value
if($null -eq $rawTable){throw 'HOME_NORTH_SHOP=FAIL empty_shop_table'}
$shopRows=if($rawTable -is [array]){@($rawTable)}else{@($rawTable.PSObject.Properties|ForEach-Object{$_.Value})}
foreach($id in $targets.Keys){
  $areaProperty=$cfg.MapArea.PSObject.Properties[$id]
  if($null -eq $areaProperty -or $null -eq $areaProperty.Value){throw "HOME_NORTH_CONFIG=FAIL area_missing=$id"}
  $area=$areaProperty.Value
  $expected=$targets[$id]
  if([string]$area.ID -cne $id -or [string]$area.MapID -cne 'Home' -or [string]$area.Type -cne 'Area'){
    throw "HOME_NORTH_CONFIG=FAIL identity id=$id raw_id=$($area.ID) map=$($area.MapID) type=$($area.Type)"
  }
  if([string]$area.Name -cne [string]$expected.Name -or [string]$area.RequiredMission -cne [string]$expected.Mission){
    throw "HOME_NORTH_CONFIG=FAIL original_name_or_mission id=$id name=$($area.Name) mission=$($area.RequiredMission)"
  }
  if([int]$area.CostMoney -ne [int]$expected.Money -or [int]$area.CostIntel -ne [int]$expected.Intel){
    throw "HOME_NORTH_CONFIG=FAIL source_price_changed id=$id money=$($area.CostMoney) intel=$($area.CostIntel)"
  }
  $rawRef='#MapArea.'+$id
  $matches=@($shopRows|Where-Object{
    $null -ne $_ -and
    $null -ne $_.PSObject.Properties['Item'] -and
    $_.PSObject.Properties['Item'].Value -is [string] -and
    [string]$_.PSObject.Properties['Item'].Value -ceq $rawRef
  })
  if($matches.Count -ne 1){throw "HOME_NORTH_SHOP=FAIL target=$id ref=$rawRef matches=$($matches.Count)"}
  Write-Host "HOME_NORTH_AREA=PASS id=$id map=Home shop_ref=$rawRef original_money=$($area.CostMoney) original_intel=$($area.CostIntel) mission_bypass=offline_only"
}
# Extended northern regions are different source IDs: do not unlock them.
foreach($id in @('AreaNorthW2','AreaNorthC2','AreaNorthE2')){
  $entry=$cfg.MapArea.PSObject.Properties[$id]
  if($null -eq $entry -or [string]$entry.Value.MapID -cne 'Home' -or $null -eq $entry.Value.PSObject.Properties['RequiredMission']){
    throw "HOME_NORTH_SCOPE=FAIL extra_area_source_identity=$id"
  }
  if(@($targets.Keys|Where-Object{$_ -ceq $id}).Count -ne 0){throw "HOME_NORTH_SCOPE=FAIL extra_area_in_allowlist=$id"}
}
$areaSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\items\AreaItem.as') -Raw
foreach($needle in @('TEST_HOME_NORTH_PURCHASE:Boolean = true','Config.OFFLINE_MODE','this.mMapId == "Home"','mId == "AreaNW"','mId == "AreaN"','mId == "AreaNE"','mRequiredMission = null;','mRequiredLevel = 0;','mRequiredAllies = 0;','mRequiredItem = null;','mRequiredBuilding = null;','mCostIntel = 0;')){
 if(-not $areaSource.Contains($needle)){throw "HOME_NORTH_SOURCE=FAIL required=$needle"}
}
if($areaSource -match 'mCostMoney\s*=|mCostPremium\s*=|smUnlockCheat\s*=|mEarlyUnlockBought\s*='){throw 'HOME_NORTH_SOURCE=FAIL forbidden_free_or_global_cheat_change'}
$shopSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\gui\ShopDialog.as') -Raw
if(-not $shopSource.Contains('this.mGame.mScene.isAreaReachable(')){throw 'HOME_NORTH_SCOPE=FAIL shop_adjacency_guard_missing'}
$patchSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1') -Raw
if(-not $patchSource.Contains("Class='game.items.AreaItem';Source='src\game\items\AreaItem.as'")){throw 'HOME_NORTH_SWF=FAIL AreaItem_not_in_root_swf_patch_specs'}
Write-Host 'HOME_NORTH_PURCHASE_CONTRACT=PASS scope=Home:AreaNW,AreaN,AreaNE mode=offline raw_shop_references=validated original_prices=preserved mission_and_intel_runtime_bypass=target_only adjacency=preserved extra_north_areas=unchanged'
