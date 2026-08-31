param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Read-Source([string]$Relative){$path=Join-Path $RepoRoot $Relative;if(-not(Test-Path -LiteralPath $path)){throw "REGRESSION=FAIL missing=$Relative"};Get-Content -LiteralPath $path -Raw}
function Require-Contains([string]$Text,[string]$Needle,[string]$Name){if(-not $Text.Contains($Needle)){throw "REGRESSION=FAIL check=$Name expected=contains"};Write-Host "REGRESSION_CHECK=PASS name=$Name"}
function Require-NotContains([string]$Text,[string]$Needle,[string]$Name){if($Text.Contains($Needle)){throw "REGRESSION=FAIL check=$Name expected=absent"};Write-Host "REGRESSION_CHECK=PASS name=$Name"}
$game=Read-Source 'src\game\states\GameState.as'
$offline=Read-Source 'src\game\utils\OfflineSave.as'
$world=Read-Source 'src\game\gui\popups\WorldMapWindow.as'
$matchup=Read-Source 'src\game\gui\pvp\PvPMatchUpDialog.as'
$combat=Read-Source 'src\game\gui\pvp\PvPCombatSetupDialog.as'
$match=Read-Source 'src\game\net\PvPMatch.as'
$tile=Read-Source 'src\game\battlefield\TileMapGraphic.as'
$scene=Read-Source 'src\game\isometric\IsometricScene.as'
$saveDialog=Read-Source 'src\game\gui\GiveFilePermissionDialog.as'
Require-Contains $game 'private var mPvPReturnMapId: String = "Home";' 'pvp_return_map_state'
Require-Contains $game 'if (param3) {' 'pvp_transient_switch_guard'
Require-Contains $game 'this.mPvPMatch.mOpponent = null;' 'pvp_end_resets_opponent'
Require-Contains $offline 'savedMap["map_data"]["map_id"] = map_id;' 'saved_map_id_normalization'
Require-NotContains $world 'switchOfflineArea' 'worldmap_no_parallel_switch_implementation'
Require-Contains $matchup 'private static const PANEL_COUNT:int = 3;' 'pvp_owns_three_visible_slots'
Require-NotContains $matchup 'GameState.mInstance.endPvP();' 'matchup_close_does_not_end_unstarted_match'
Require-Contains $combat 'chance.toString() + "%"' 'pvp_chance_is_percentage'
Require-NotContains $combat '_loc1_ - _loc2_' 'pvp_raw_float_difference_removed'
Require-NotContains $combat 'mScene.mFog.destroy();' 'pvp_dialog_does_not_destroy_scene_fog'
Require-Contains $match 'while(_loc2_ < 24 && this.mOpponentUnits.length < 4)' 'pvp_randomization_bounded'
Require-Contains $tile 'this.disposeCachedTileBitmaps();' 'native_bitmap_cache_disposed_before_rebuild'
Require-Contains $scene 'Math.abs(this.mContainer.scaleX - param1) < 0.0001' 'zoom_noop_avoids_reraster'
Require-NotContains $game 'this.mHUD.openGiveFilePermissionScreen();' 'mobile_obsolete_v22_save_gate_removed'
Require-Contains $game 'defaultSettings["savelocation"] = this.mSaveLocation;' 'mobile_internal_save_default_persisted'
Require-Contains $saveDialog 'private function fitToScreen():void' 'mobile_save_dialog_has_viewport_fit'
Require-Contains $saveDialog 'stageHeight * 0.92 / mClip.height' 'mobile_save_dialog_height_bounded'
Require-Contains $saveDialog 'var done:Function = mDoneCallback;' 'mobile_save_choice_closes_immediately'
Require-NotContains $saveDialog 'this.buttonSavePressed(param1); // twice' 'mobile_save_duplicate_permission_requests_removed'
Write-Host 'REGRESSION=PASS suite=android-runtime-v3.7'
