param([string]$RepoRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path}
$configPath=Join-Path $RepoRoot 'src\config\army_config_base.json'
if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){throw "HOME_NORTH_CONFIG=FAIL missing=$configPath"}
$cfg=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
# The authored ShopArea table stores STRING references; the runtime links them.
$targets=[ordered]@{
 AreaNW=@{Name='#TID.AREA_NW_NAME';Mission='#Mission.MAP_LOCK_NW';Money=30000;Intel=25}
 AreaN=@{Name='#TID.AREA_N_NAME';Mission='#Mission.MAP_LOCK_NC';Money=50000;Intel=30}
 AreaNE=@{Name='#TID.AREA_NE_NAME';Mission='#Mission.MAP_LOCK_NE';Money=100000;Intel=40}
 AreaNorthW2=@{Name='#TID.AREANORTHW_NAME';Mission='#Mission.MAP_LOCK_NW2';Money=150000;Intel=50}
 AreaNorthC2=@{Name='#TID.AREANORTHC_NAME';Mission='#Mission.MAP_LOCK_NC2';Money=200000;Intel=60}
 AreaNorthE2=@{Name='#TID.AREANORTHE_NAME';Mission='#Mission.MAP_LOCK_NE2';Money=300000;Intel=70}
}
if($null -eq $cfg.MapArea -or $null -eq $cfg.ShopTab -or $null -eq $cfg.ShopTab.Areas){throw 'HOME_NORTH_CONFIG=FAIL areas_or_shop_missing'}
$tableName=[string]$cfg.ShopTab.Areas.ItemTable
if($tableName -cne 'ShopArea' -or $null -eq $cfg.PSObject.Properties[$tableName]){throw "HOME_NORTH_SHOP=FAIL table=$tableName"}
$table=$cfg.PSObject.Properties[$tableName].Value
if($null -eq $table){throw 'HOME_NORTH_SHOP=FAIL empty_shop_table'}
$shopRows=if($table -is [array]){@($table)}else{@($table.PSObject.Properties|ForEach-Object{$_.Value})}
foreach($id in $targets.Keys){
  $p=$cfg.MapArea.PSObject.Properties[$id]
  if($null -eq $p){throw "HOME_NORTH_CONFIG=FAIL missing_area=$id"}
  $area=$p.Value;$want=$targets[$id]
  if([string]$area.ID -cne $id -or [string]$area.MapID -cne 'Home' -or [string]$area.Type -cne 'Area' -or
     [string]$area.Name -cne [string]$want.Name -or [string]$area.RequiredMission -cne [string]$want.Mission){
    throw "HOME_NORTH_CONFIG=FAIL source_identity id=$id"
  }
  if([int]$area.CostMoney -ne [int]$want.Money -or [int]$area.CostIntel -ne [int]$want.Intel){
    throw "HOME_NORTH_CONFIG=FAIL original_price id=$id money=$($area.CostMoney) intel=$($area.CostIntel)"
  }
  $rawRef='#MapArea.'+$id
  $matching=@($shopRows|Where-Object{
    $null -ne $_ -and $null -ne $_.PSObject.Properties['Item'] -and
    $_.PSObject.Properties['Item'].Value -is [string] -and
    [string]$_.PSObject.Properties['Item'].Value -ceq $rawRef
  })
  if($matching.Count -ne 1){throw "HOME_NORTH_SHOP=FAIL id=$id reference=$rawRef count=$($matching.Count)"}
  Write-Host "HOME_NORTH_AREA=PASS id=$id map=Home shop_ref=$rawRef original_money=$($area.CostMoney) original_intel=$($area.CostIntel)"
}
$homeIds=@($cfg.MapArea.PSObject.Properties|ForEach-Object{$_.Value}|Where-Object{[string]$_.MapID -ceq 'Home'}|ForEach-Object{[string]$_.ID})
if($homeIds.Count -ne 12 -or $targets.Count -ne 6){throw "HOME_NORTH_SCOPE=FAIL home=$($homeIds.Count) trial=$($targets.Count)"}
foreach($id in @('AreaS','AreaSW','AreaSE','AreaW','AreaC','AreaE')){
  if(@($homeIds|Where-Object{$_ -ceq $id}).Count -ne 1 -or $targets.Contains($id)){throw "HOME_NORTH_SCOPE=FAIL non_trial_area=$id"}
}
$areaSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\items\AreaItem.as') -Raw
$manager=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\missions\MissionManager.as') -Raw
foreach($id in $targets.Keys){
 if(-not $areaSource.Contains('mId == "'+$id+'"') -or -not $areaSource.Contains('param1 == "'+$id+'"') -or
    -not $manager.Contains('param1 == "'+$id+'"')){throw "HOME_NORTH_SOURCE=FAIL trial_allowlist=$id"}
}
foreach($needle in @('TEST_HOME_NORTH_PURCHASE:Boolean = true','Config.OFFLINE_MODE','this.mMapId == "Home"',
 'mRequiredMission = null;','mRequiredLevel = 0;','mRequiredAllies = 0;','mRequiredItem = null;',
 'mRequiredBuilding = null;','mCostIntel = 0;')){
 if(-not $areaSource.Contains($needle)){throw "HOME_NORTH_SOURCE=FAIL required=$needle"}
}
if($areaSource -match 'mCostMoney\s*=|mCostPremium\s*=|smUnlockCheat\s*=|mEarlyUnlockBought\s*='){throw 'HOME_NORTH_SCOPE=FAIL free_purchase_or_global_cheat'}
if(-not $areaSource.Contains('mId != "AreaNorthW"') -or -not $areaSource.Contains('mId != "AreaNorthC"') -or -not $areaSource.Contains('mId != "AreaNorthE"')){throw 'HOME_NORTH_SCOPE=FAIL alias_guard_changed'}
$shopSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\gui\ShopDialog.as') -Raw
if(-not $shopSource.Contains('this.mGame.mScene.isAreaReachable(')){throw 'HOME_NORTH_SCOPE=FAIL adjacency_guard_missing'}
$patch=Get-Content -LiteralPath (Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1') -Raw
if(-not $patch.Contains("Class='game.items.AreaItem';Source='src\game\items\AreaItem.as'")){throw 'HOME_NORTH_SWF=FAIL AreaItem_not_in_swf_patch'}
Write-Host 'HOME_NORTH_PURCHASE_CONTRACT=PASS scope=six_home_north_regions source_prices=preserved offline_only=true mission_and_intel_bypass=target_only adjacency=preserved non_trial_areas=unchanged'
