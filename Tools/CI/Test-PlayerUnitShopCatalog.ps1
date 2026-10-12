param(
  [string]$RepoRoot,
  [string]$PublishedContentRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if([string]::IsNullOrWhiteSpace($RepoRoot)){
  $RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$configPath=Join-Path $RepoRoot 'src\config\army_config_base.json'
if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){
  throw "PLAYER_UNIT_SHOP=FAIL missing_config=$configPath"
}
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
$expectedUnitIds=@(
  'Infantry','Soldier','SpecialForces','ArmoredCar','MainBattleTank','GunBattery',
  'MobileRocketBattery','EliteInfantry','FlameForce','EliteMainBattleTank',
  'PremiumMobileRocketBattery','PremiumCommando','Sniper','EliteLandKreuzer',
  'EliteJuggernaut','BlackFox','EliteRocketeer','AssaultChopper'
)
if($playerRows.Count -ne $expectedUnitIds.Count){
  throw "PLAYER_UNIT_SHOP=FAIL canonical_player_unit_count expected=$($expectedUnitIds.Count) actual=$($playerRows.Count)"
}
$playerById=[System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
foreach($unit in $playerRows){
  $idProperty=$unit.PSObject.Properties['ID']
  if($null -eq $idProperty -or [string]::IsNullOrWhiteSpace([string]$idProperty.Value)){
    throw 'PLAYER_UNIT_SHOP=FAIL player_unit_id_missing'
  }
  $unitId=[string]$idProperty.Value
  if($playerById.ContainsKey($unitId)){throw "PLAYER_UNIT_SHOP=FAIL duplicate_player_unit=$unitId"}
  $playerById.Add($unitId,$unit)
}
foreach($unitId in $expectedUnitIds){
  if(-not $playerById.ContainsKey($unitId)){throw "PLAYER_UNIT_SHOP=FAIL canonical_player_unit_missing=$unitId"}
}
$unexpectedPlayerIds=@($playerById.Keys|Where-Object{$expectedUnitIds -cnotcontains $_})
if($unexpectedPlayerIds.Count -gt 0){
  throw "PLAYER_UNIT_SHOP=FAIL unexpected_player_units=$($unexpectedPlayerIds -join ',')"
}
$requiredGraphicFields=@(
  'IconGraphics','Graphic_idle','Graphic_move','Graphic_aim','Graphic_shoot',
  'Graphic_hit','Graphic_die','Graphic_aim_up','Graphic_shoot_up','Graphic_move_up'
)
foreach($unitId in $expectedUnitIds){
  $unit=$playerById[$unitId]
  foreach($field in $requiredGraphicFields){
    $property=$unit.PSObject.Properties[$field]
    if($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)){
      throw "PLAYER_UNIT_SHOP=FAIL unit_graphic_missing unit=$unitId field=$field"
    }
  }
}

$unitIds=[System.Collections.Generic.List[string]]::new()
foreach($row in $shopRows){
  if($null -eq $row -or $null -eq $row.PSObject.Properties['Item']){
    throw 'PLAYER_UNIT_SHOP=FAIL shop_item_missing'
  }
  $item=$row.PSObject.Properties['Item'].Value
  $itemType=''
  $unitId=''
  if($item -is [string]){
    if($item -match '^#?PlayerUnit\.([A-Za-z0-9_]+)$'){
      $itemType='PlayerUnit'
      $unitId=$Matches[1]
    }
  }elseif($null -ne $item){
    $typeProperty=$item.PSObject.Properties['Type']
    $idProperty=$item.PSObject.Properties['ID']
    if($null -ne $typeProperty){$itemType=([string]$typeProperty.Value).TrimStart('#')}
    if($null -ne $idProperty){$unitId=[string]$idProperty.Value}
    if($unitId -match '^#?PlayerUnit\.([A-Za-z0-9_]+)$'){
      $itemType='PlayerUnit'
      $unitId=$Matches[1]
    }
  }
  if($itemType -cne 'PlayerUnit'){throw "PLAYER_UNIT_SHOP=FAIL non_player_item_in_unit_tab=$item"}
  if([string]::IsNullOrWhiteSpace($unitId)){throw 'PLAYER_UNIT_SHOP=FAIL player_unit_id_missing'}
  if(-not $playerById.ContainsKey($unitId)){throw "PLAYER_UNIT_SHOP=FAIL unresolved_player_unit=$unitId"}
  $unitIds.Add($unitId)
}
$shopUnitIds=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach($unitId in $unitIds){
  if(-not $shopUnitIds.Add($unitId)){throw "PLAYER_UNIT_SHOP=FAIL duplicate_shop_unit=$unitId"}
}
$missingExpectedShopUnits=@($expectedUnitIds|Where-Object{-not $shopUnitIds.Contains($_)})
$unexpectedShopUnits=@($unitIds|Where-Object{$expectedUnitIds -cnotcontains $_})
if($missingExpectedShopUnits.Count -gt 0 -or $unexpectedShopUnits.Count -gt 0){
  throw "PLAYER_UNIT_SHOP=FAIL canonical_shop_roster missing=$($missingExpectedShopUnits -join ',') unexpected=$($unexpectedShopUnits -join ',')"
}

$priceCulture=[System.Globalization.CultureInfo]::InvariantCulture
$purchasableUnitIds=[System.Collections.Generic.List[string]]::new()
foreach($unit in $playerRows){
  $money=0.0
  $premium=0.0
  $moneyProperty=$unit.PSObject.Properties['CostMoney']
  $premiumProperty=$unit.PSObject.Properties['CostPremium']
  if($null -ne $moneyProperty -and -not [string]::IsNullOrWhiteSpace([string]$moneyProperty.Value)){
    $money=[double]::Parse([string]$moneyProperty.Value,$priceCulture)
  }
  if($null -ne $premiumProperty -and -not [string]::IsNullOrWhiteSpace([string]$premiumProperty.Value)){
    $premium=[double]::Parse([string]$premiumProperty.Value,$priceCulture)
  }
  if($money -gt 0 -or $premium -gt 0){
    $idProperty=$unit.PSObject.Properties['ID']
    if($null -eq $idProperty -or [string]::IsNullOrWhiteSpace([string]$idProperty.Value)){
      throw 'PLAYER_UNIT_SHOP=FAIL purchasable_unit_id_missing'
    }
    $purchasableUnitIds.Add([string]$idProperty.Value)
  }
}
if($purchasableUnitIds.Count -ne $expectedUnitIds.Count){
  throw "PLAYER_UNIT_SHOP=FAIL priced_roster_count expected=$($expectedUnitIds.Count) actual=$($purchasableUnitIds.Count)"
}
$missingPurchasable=@($purchasableUnitIds|Where-Object{-not $shopUnitIds.Contains($_)})
if($missingPurchasable.Count -gt 0){
  throw "PLAYER_UNIT_SHOP=FAIL missing_purchasable_units=$($missingPurchasable -join ',')"
}

$mobileTabs=$cfg.PSObject.Properties['ShopTabIPhone']
if($null -eq $mobileTabs){throw 'PLAYER_UNIT_SHOP=FAIL iphone_tabs_missing'}
$mobileUnits=$mobileTabs.Value.PSObject.Properties['Units']
if($null -eq $mobileUnits -or [string]$mobileUnits.Value.ItemTable -cne $tableName){
  throw 'PLAYER_UNIT_SHOP=FAIL iphone_units_tab_mismatch'
}

$localeLanguages=@('de','en','es','fr','it')
$referencedTids=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach($unitId in $expectedUnitIds){
  $unit=$playerById[$unitId]
  foreach($field in @('Name','Description')){
    $referenceProperty=$unit.PSObject.Properties[$field]
    if($null -eq $referenceProperty){throw "PLAYER_UNIT_SHOP=FAIL unit_tid_missing unit=$unitId field=$field"}
    $reference=[string]$referenceProperty.Value
    if($reference -notmatch '^#TID\.([A-Za-z0-9_]+)$'){
      throw "PLAYER_UNIT_SHOP=FAIL unit_tid_reference_invalid unit=$unitId field=$field value=$reference"
    }
    [void]$referencedTids.Add($Matches[1])
  }
}
foreach($language in $localeLanguages){
  $localePath=Join-Path $RepoRoot ("src\config\army_config_"+$language+".json")
  if(-not(Test-Path -LiteralPath $localePath -PathType Leaf)){
    throw "PLAYER_UNIT_SHOP=FAIL locale_missing language=$language"
  }
  $locale=Get-Content -LiteralPath $localePath -Raw|ConvertFrom-Json
  $tids=$locale.PSObject.Properties['TID'].Value
  foreach($tidId in $referencedTids){
    $tidProperty=$tids.PSObject.Properties[$tidId]
    if($null -eq $tidProperty){
      throw "PLAYER_UNIT_SHOP=FAIL unit_translation_missing language=$language tid=$tidId"
    }
    $languageText=$tidProperty.Value.PSObject.Properties[$language]
    if($null -eq $languageText -or [string]::IsNullOrWhiteSpace([string]$languageText.Value)){
      throw "PLAYER_UNIT_SHOP=FAIL unit_translation_missing language=$language tid=$tidId"
    }
  }
}

$shopSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\gui\ShopDialog.as') -Raw
if($shopSource -notmatch 'mAllItems\[_loc4_\.ID\]\s*=\s*_loc5_;' -or
   $shopSource -notmatch 'this\.mItemsForSell\s*=\s*this\.mAllItems\[param1\];' -or
   $shopSource -notmatch 'this\.mPageMax\s*=\s*\(this\.mItemsForSell\.length\s*\+\s*PANEL_COUNT\s*-\s*1\)\s*/\s*PANEL_COUNT;' -or
   $shopSource -notmatch 'if\(\(_loc4_ = _loc2_ \+ _loc1_\) < this\.mItemsForSell\.length\)'){
  throw 'PLAYER_UNIT_SHOP=FAIL shop_rows_or_pagination_not_fully_rendered'
}
$itemManager=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\items\ItemManager.as') -Raw
if($itemManager -notmatch 'addItems\("PlayerUnit",\s*createPlayerUnitItem\)'){
  throw 'PLAYER_UNIT_SHOP=FAIL player_item_factory_missing'
}

if(-not [string]::IsNullOrWhiteSpace($PublishedContentRoot)){
  $publishedRoot=(Resolve-Path -LiteralPath $PublishedContentRoot).Path
  $publishedConfigPath=Join-Path $publishedRoot 'armyattack\config\army_config_base.json'
  if(-not(Test-Path -LiteralPath $publishedConfigPath -PathType Leaf)){
    throw "PLAYER_UNIT_SHOP=FAIL published_config_missing=$publishedConfigPath"
  }
  $publishedConfig=Get-Content -LiteralPath $publishedConfigPath -Raw|ConvertFrom-Json
  $publishedPlayers=$publishedConfig.PSObject.Properties['PlayerUnit'].Value
  $iconRoot=Join-Path $publishedRoot 'armyattack\data\icons\shop_icons'
  if(-not(Test-Path -LiteralPath $iconRoot -PathType Container)){
    throw "PLAYER_UNIT_SHOP=FAIL published_icon_directory_missing=$iconRoot"
  }
  $publishedIconNames=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  Get-ChildItem -LiteralPath $iconRoot -File|ForEach-Object{[void]$publishedIconNames.Add($_.Name)}
  foreach($unitId in $expectedUnitIds){
    $currentUnit=$playerById[$unitId]
    $publishedUnitProperty=$publishedPlayers.PSObject.Properties[$unitId]
    if($null -eq $publishedUnitProperty){throw "PLAYER_UNIT_SHOP=FAIL published_player_unit_missing=$unitId"}
    $publishedUnit=$publishedUnitProperty.Value
    foreach($assetProperty in @($publishedUnit.PSObject.Properties|Where-Object{$_.Name -like 'Graphic_*'})){
      $currentAsset=$currentUnit.PSObject.Properties[$assetProperty.Name]
      if($null -eq $currentAsset -or [string]$currentAsset.Value -cne [string]$assetProperty.Value){
        throw "PLAYER_UNIT_SHOP=FAIL published_animation_mismatch unit=$unitId field=$($assetProperty.Name)"
      }
    }
    $iconPath=[string]$currentUnit.IconGraphics
    if($iconPath -notmatch '^icons/shop_icons/[^/]+$'){
      throw "PLAYER_UNIT_SHOP=FAIL published_icon_path_invalid unit=$unitId path=$iconPath"
    }
    $iconName=($iconPath -split '/')[-1]
    if(-not $publishedIconNames.Contains($iconName)){
      throw "PLAYER_UNIT_SHOP=FAIL published_icon_missing_or_wrong_case unit=$unitId icon=$iconName"
    }
  }
  Write-Host "PLAYER_UNIT_ASSETS=PASS pinned_published_source=true units=$($expectedUnitIds.Count) icons_case_sensitive=true animations_matched=true"
}

Write-Host "PLAYER_UNIT_SHOP=PASS table=$tableName canonical_roster=$($expectedUnitIds.Count) purchasable_player_units=$($purchasableUnitIds.Count) listed_player_units=$($unitIds.Count) all_rows_rendered=true paginated=true localized_languages=$($localeLanguages -join ',')"
