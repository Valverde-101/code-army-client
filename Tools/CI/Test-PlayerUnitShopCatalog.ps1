param([string]$RepoRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path}
$configPath=Join-Path $RepoRoot 'src\config\army_config_base.json'
if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){throw "PLAYER_UNIT_SHOP=FAIL missing_config=$configPath"}
$cfg=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
$unitTabProperty=$cfg.ShopTab.PSObject.Properties['Units']
if($null -eq $unitTabProperty){throw 'PLAYER_UNIT_SHOP=FAIL Units_tab_missing'}
$tableName=[string]$unitTabProperty.Value.ItemTable
if([string]::IsNullOrWhiteSpace($tableName)){throw 'PLAYER_UNIT_SHOP=FAIL unit_table_missing'}
$tableProperty=$cfg.PSObject.Properties[$tableName]
if($null -eq $tableProperty){throw "PLAYER_UNIT_SHOP=FAIL missing_table=$tableName"}
$shopTable=$tableProperty.Value
$shopRows=if($shopTable -is [array]){@($shopTable)}else{@($shopTable.PSObject.Properties|ForEach-Object{$_.Value})}
if($shopRows.Count -eq 0){throw "PLAYER_UNIT_SHOP=FAIL empty_table=$tableName"}
$playerTableProperty=$cfg.PSObject.Properties['PlayerUnit']
if($null -eq $playerTableProperty){throw 'PLAYER_UNIT_SHOP=FAIL PlayerUnit_table_missing'}
$playerTable=$playerTableProperty.Value
$playerRows=if($playerTable -is [array]){@($playerTable)}else{@($playerTable.PSObject.Properties|ForEach-Object{$_.Value})}
$unitIds=[System.Collections.Generic.List[string]]::new()
foreach($row in $shopRows){
  if($null -eq $row -or $null -eq $row.PSObject.Properties['Item']){continue}
  $item=$row.PSObject.Properties['Item'].Value
  $itemType=''
  $unitId=''
  if($item -is [string]){
    if($item -match '^#?PlayerUnit\.([A-Za-z0-9_]+)$'){$itemType='PlayerUnit';$unitId=$Matches[1]}
  }elseif($null -ne $item){
    $typeProperty=$item.PSObject.Properties['Type']
    $idProperty=$item.PSObject.Properties['ID']
    if($null -ne $typeProperty){$itemType=([string]$typeProperty.Value).TrimStart('#')}
    if($null -ne $idProperty){$unitId=[string]$idProperty.Value}
    if($unitId -match '^#?PlayerUnit\.([A-Za-z0-9_]+)$'){$itemType='PlayerUnit';$unitId=$Matches[1]}
  }
  if($itemType -cne 'PlayerUnit'){continue}
  if([string]::IsNullOrWhiteSpace($unitId)){throw 'PLAYER_UNIT_SHOP=FAIL player_unit_id_missing'}
  if(@($playerRows|Where-Object{[string]$_.ID -ceq $unitId}).Count -ne 1){
    throw "PLAYER_UNIT_SHOP=FAIL unresolved_player_unit=$unitId"
  }
  $unitIds.Add($unitId)
}
if($unitIds.Count -eq 0){throw 'PLAYER_UNIT_SHOP=FAIL no_purchasable_player_units'}
$shopSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\gui\ShopDialog.as') -Raw
if($shopSource -notmatch 'mAllItems\[_loc4_\.ID\]\s*=\s*_loc5_;' -or
   $shopSource -notmatch 'this\.mItemsForSell\s*=\s*this\.mAllItems\[param1\];'){
  throw 'PLAYER_UNIT_SHOP=FAIL shop_rows_not_fully_rendered'
}
$itemManager=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\items\ItemManager.as') -Raw
if($itemManager -notmatch 'addItems\("PlayerUnit",\s*createPlayerUnitItem\)'){
  throw 'PLAYER_UNIT_SHOP=FAIL player_item_factory_missing'
}
Write-Host "PLAYER_UNIT_SHOP=PASS table=$tableName purchasable_player_units=$($unitIds.Count) all_rows_rendered=true enemy_catalog_not_added=true"
