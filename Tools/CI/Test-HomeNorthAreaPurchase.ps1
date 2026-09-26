param([string]$RepoRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\\..')).Path}
$configPath=Join-Path $RepoRoot 'src\\config\\army_config_base.json'
if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){throw "HOME_NORTH_CONFIG=FAIL missing=$configPath"}
$cfg=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
$targets=@('AreaNW','AreaN','AreaNE')
if($null -eq $cfg.MapArea -or $null -eq $cfg.ShopTab -or $null -eq $cfg.ShopTab.Areas){throw 'HOME_NORTH_CONFIG=FAIL areas_or_shop_missing'}
$areas=@($cfg.MapArea.PSObject.Properties|ForEach-Object{$_.Value})
$areaIDs=@($areas|Where-Object{$null -ne $_ -and [string]$_.MapID -eq 'Home'}|ForEach-Object{[string]$_.ID})
$tableName=[string]$cfg.ShopTab.Areas.ItemTable
if([string]::IsNullOrWhiteSpace($tableName) -or $null -eq $cfg.PSObject.Properties[$tableName]){throw "HOME_NORTH_SHOP=FAIL item_table=$tableName"}
$shopTable=$cfg.PSObject.Properties[$tableName].Value
$shopRows=if($shopTable -is [array]){@($shopTable)}else{@($shopTable.PSObject.Properties|ForEach-Object{$_.Value})}
$shopIds=@($shopRows|Where-Object{$null -ne $_ -and $null -ne $_.Item -and [string]$_.Item.Type -eq 'Area'}|ForEach-Object{[string]$_.Item.ID})
foreach($id in $targets){
  if(@($areaIDs|Where-Object{$_ -eq $id}).Count -ne 1){throw "HOME_NORTH_CONFIG=FAIL missing_home_area=$id detected=$($areaIDs -join ',')"}
  if(@($shopIds|Where-Object{$_ -eq $id}).Count -ne 1){throw "HOME_NORTH_SHOP=FAIL missing_shop_entry=$id detected=$($shopIds -join ',')"}
  Write-Host "HOME_NORTH_AREA=PASS id=$id map=Home shop=$tableName"
}
$areaSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\\game\\items\\AreaItem.as') -Raw
foreach($needle in @('TEST_HOME_NORTH_PURCHASE:Boolean = true','Config.OFFLINE_MODE','this.mMapId == "Home"','mId == "AreaNW"','mId == "AreaN"','mId == "AreaNE"','mRequiredMission = null;','mRequiredLevel = 0;','mRequiredAllies = 0;','mRequiredItem = null;','mRequiredBuilding = null;','mCostIntel = 0;','mId != "AreaNorthW"','mId != "AreaNorthC"','mId != "AreaNorthE"')){
 if(-not $areaSource.Contains($needle)){throw "HOME_NORTH_SOURCE=FAIL required=$needle"}
}
if($areaSource -match 'mCostMoney\\s*=|mCostPremium\\s*=|smUnlockCheat\\s*=|mEarlyUnlockBought\\s*='){throw 'HOME_NORTH_SOURCE=FAIL forbidden_free_or_global_cheat_change'}
$patchSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'Tools\\CI\\Patch-AndroidPerformanceSwf.ps1') -Raw
if(-not $patchSource.Contains("Class='game.items.AreaItem';Source='src\\game\\items\\AreaItem.as'")){throw 'HOME_NORTH_SWF=FAIL AreaItem_not_in_root_swf_patch_specs'}
Write-Host 'HOME_NORTH_PURCHASE_CONTRACT=PASS scope=Home:AreaNW,AreaN,AreaNE mode=offline mission_and_prerequisites=bypassed intel=0 normal_prices=preserved adjacency=preserved extra_north_areas=locked'
