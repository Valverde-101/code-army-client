param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Contains([string]$Text,[string]$Pattern,[string]$Gate) {
  if(-not [regex]::IsMatch($Text,$Pattern,[Text.RegularExpressions.RegexOptions]::Singleline)){
    throw "$Gate=FAIL pattern=$Pattern"
  }
  Write-Host "$Gate=PASS"
}
function Read-Source([string]$Path) {
  $full=Join-Path $RepoRoot $Path
  if(-not (Test-Path -LiteralPath $full -PathType Leaf)){throw "SOURCE=FAIL missing=$Path"}
  return [IO.File]::ReadAllText($full)
}
$game=Read-Source 'src\game\states\GameState.as'
$scene=Read-Source 'src\game\isometric\IsometricScene.as'
$cell=Read-Source 'src\game\isometric\GridCell.as'
$shop=Read-Source 'src\game\items\ShopItem.as'
$units=Read-Source 'src\game\items\PlayerUnitItem.as'
$dialog=Read-Source 'src\game\gui\ShopDialog.as'
$hud=Read-Source 'src\game\gui\GameHUD.as'
$patcher=Read-Source 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$validator=Read-Source 'Tools\CI\Validate-AndroidApk.ps1'
$conf=Read-Source 'src\config\army_config_base.json'
$config=$conf|ConvertFrom-Json
$playerUnits=@($config.PlayerUnit.PSObject.Properties|ForEach-Object{$_.Value})
$shopUnits=@($config.ShopUnit.PSObject.Properties|ForEach-Object{$_.Value})
$ids=@($playerUnits|ForEach-Object{[string]$_.ID}|Sort-Object -Unique)
if($playerUnits.Count -lt 15 -or $playerUnits.Count -ne $ids.Count){throw "UNIT_CATALOG=FAIL units=$($playerUnits.Count) unique=$($ids.Count)"}
if(@($ids|Where-Object{$_ -eq 'BlackFox'}).Count -ne 1){throw 'UNIT_CATALOG=FAIL blackfox_not_present'}
Write-Host "UNIT_CATALOG=PASS player_units=$($ids.Count) regular_shop_entries=$($shopUnits.Count) includes_BlackFox=true"
Assert-Contains $game 'private static var smOfflineGodMode:Boolean = false' 'MODE_DEFAULT_OFF'
Assert-Contains $game 'Config\.OFFLINE_MODE && Config\.DEBUG_MODE && !Config\.USE_LIVE_BUILD' 'DEBUG_OFFLINE_GATE'
Assert-Contains $game 'mCurrentMapId\.indexOf\("pvp_"\) != 0 && mInstance\.mState != STATE_PVP' 'PVP_EXCLUDED'
Assert-Contains $game 'function setOfflineGodMode\(enabled:Boolean\):Boolean' 'MODE_HOOK'
Assert-Contains $game 'this\.mScene\.updateBorderTiles\(\)' 'CLOUD_RECALC'
Assert-Contains $game 'this\.mScene\.mFog\.init\(false\)' 'FOG_RECALC'
Assert-Contains $game 'this\.mScene\.mTilemapGraphic\.updateTilemap\(\)' 'TILEMAP_REDRAW'
Assert-Contains $scene 'GameState\.isOfflineGodModeActive\(\) \|\| GameState\.mInstance\.visitingTutor\(\)' 'ALL_AREAS_VISIBLE'
Assert-Contains $cell '!GameState\.isOfflineGodModeActive\(\) && this\.mViewers == 0' 'FOG_OVERRIDE'
Assert-Contains $shop 'this is PlayerUnitItem && GameState\.isOfflineGodModeActive\(\)' 'PLAYER_UNITS_UNLOCKED'
Assert-Contains $units 'if \(GameState\.isOfflineGodModeActive\(\)\) return true' 'UNIT_CAP_BYPASS'
Assert-Contains $dialog 'for each \(unit in GameState\.mConfig\.PlayerUnit\)' 'FULL_UNIT_SOURCE'
Assert-Contains $dialog 'ItemManager\.getItemByTableName\(String\(unit\.ID\), "PlayerUnit"\)' 'ALL_UNIT_LOOKUP'
Assert-Contains $dialog 'if \(!alreadyListed\) fullUnits\.push\(candidate\)' 'SHOP_DEDUP'
Assert-Contains $dialog 'this\.mLastGodModeCatalog != GameState\.isOfflineGodModeActive\(\)' 'SHOP_MODE_CHANGE_REFRESH'
Assert-Contains $dialog 'this\.mLastGodModeCatalog = GameState\.isOfflineGodModeActive\(\)' 'SHOP_MODE_CHANGE_TRACKED'
Assert-Contains $hud 'army_offline_god_mode' 'FLOATING_BUTTON_ID'
Assert-Contains $hud 'this\.mGame\.setOfflineGodMode\(enable\)' 'FLOATING_BUTTON_HOOK'
Assert-Contains $hud '!PopUpManager\.isAnyPopupActive\(\)' 'FLOATING_BUTTON_POPUP_GUARD'
if($game -match 'smOfflineGodMode\s*=\s*true\s*;'){throw 'MODE_DEFAULT_OFF=FAIL enabled_without_user_action'}
if($game -match 'mInventory\.addItems\([^)]*AreaItem'){throw 'PERSISTENCE_GUARD=FAIL suspicious_area_grant'}
Write-Host 'PERSISTENCE_GUARD=PASS temporary_flag_and_no_auto_area_purchase'
# A green source contract is not enough: all altered classes must actually replace
# their binary counterparts in the Android root SWF and be enforced at APK validation.
foreach($class in @('game.states.GameState','game.gui.GameHUD','game.isometric.IsometricScene','game.isometric.GridCell','game.items.ShopItem','game.items.PlayerUnitItem','game.gui.ShopDialog')){
  Assert-Contains $patcher ([regex]::Escape("Class='$class'")) "GOD_MODE_SWF_SPEC_$class"
  Assert-Contains $validator ([regex]::Escape("'$class'")) "GOD_MODE_APK_CLASS_$class"
}
Write-Host 'GOD_MODE_BINARY_CONTRACT=PASS classes=7 android_root_swf=true'
$marker=Read-Source 'android\native\diagnostics\as3\com\valverde\armyattack\diagnostics\DiagnosticsMarker.as'
$native=Read-Source 'android\native\diagnostics\java\com\valverde\armyattack\diagnostics\DiagnosticsExtension.java'
$regress=Read-Source 'Tools\CI\Test-AndroidTargetedRegressions.ps1'
Assert-Contains $marker 'command == "god_mode"' 'GOD_MODE_DEBUG_COMMAND'
Assert-Contains $marker 'command == "god_shop"' 'GOD_SHOP_DEBUG_COMMAND'
Assert-Contains $native '"god_mode"\.equals\(command\)' 'GOD_MODE_NATIVE_ALLOWLIST'
Assert-Contains $regress 'GOD_MODE_ALL_TROOPS=PASS' 'GOD_MODE_PHYSICAL_SHOP_TEST'
Assert-Contains $regress 'GOD_MODE_MAP_PERSISTENCE' 'GOD_MODE_PHYSICAL_MAP_TEST'
Write-Host 'FINAL_VALIDATION=PASS scope=static_god_mode_contract_only'
