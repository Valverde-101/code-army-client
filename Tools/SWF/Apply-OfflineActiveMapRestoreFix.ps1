param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$offlinePath=Join-Path $RepositoryRoot 'src\game\utils\OfflineSave.as'
$testPath=Join-Path $RepositoryRoot 'Tools\CI\Test-AndroidRuntimePatch.ps1'
foreach($path in @($offlinePath,$testPath)){
  if(-not(Test-Path -LiteralPath $path)){throw "ACTIVE_MAP_FIX=FAIL missing=$path"}
}

$offline=Get-Content -LiteralPath $offlinePath -Raw
$originalOffline=$offline

# Persist the currently active non-PvP world in the save envelope.
if($offline -notmatch 'savedata\["active_map_id"\] = map_id;'){
  $anchor='savedata["isFogOfWarOff"] = GameState.mInstance.isFogOfWarOn();'
  if(-not $offline.Contains($anchor)){throw 'ACTIVE_MAP_FIX=FAIL save_anchor_missing'}
  $offline=$offline.Replace($anchor,$anchor+"`r`n`t`t`tsavedata[`"active_map_id`"] = map_id.indexOf(`"pvp_`") == -1 ? map_id : `"Home`";")
}
$offline=$offline.Replace('savedata["saveversion"] = 5;','savedata["saveversion"] = 6;')

# Backward-compatible migration: old saves always started in Home.
if($offline -notmatch 'version < 6'){
  $anchor='if (version < 5) {'
  $start=$offline.IndexOf($anchor)
  if($start -lt 0){throw 'ACTIVE_MAP_FIX=FAIL migration_anchor_missing'}
  $returnAnchor="`r`n`t`t`treturn savedata;"
  $returnPos=$offline.IndexOf($returnAnchor,$start)
  if($returnPos -lt 0){throw 'ACTIVE_MAP_FIX=FAIL migration_return_missing'}
  $migration=@'
			if (version < 6) {
				if (savedata["active_map_id"] == null || String(savedata["active_map_id"]).length == 0) {
					savedata["active_map_id"] = "Home";
				}
			}
'@
  $offline=$offline.Insert($returnPos,"`r`n"+$migration)
}

# Resolve and sanitize the requested world before the normal Home bootstrap.
if($offline -notmatch 'var activeMapId: String = "Home";'){
  $anchor='savedata = fixOldSave(savedata, saveversion);'
  if(-not $offline.Contains($anchor)){throw 'ACTIVE_MAP_FIX=FAIL load_fix_anchor_missing'}
  $block=@'

			var activeMapId: String = "Home";
			if (savedata["active_map_id"] != null) {
				activeMapId = String(savedata["active_map_id"]);
			}
			if (activeMapId.indexOf("pvp_") == 0 || GameState.GRAPHICS_MAP_ID_LIST.indexOf(activeMapId) < 0) {
				activeMapId = "Home";
			}
'@
  $offline=$offline.Replace($anchor,$anchor+$block)
}

# Keep the proven Home bootstrap, then use the existing resource-gated transition
# to restore Desert only after profile, missions, scene, HUD and Home resources exist.
if($offline -notmatch 'restore_active_map_after_home_bootstrap'){
  $anchor='GameState.mInstance.mHUD.changeWaterVisibility(false)'
  if(-not $offline.Contains($anchor)){throw 'ACTIVE_MAP_FIX=FAIL home_bootstrap_anchor_missing'}
  $restore=@'

			// restore_active_map_after_home_bootstrap: never direct-init Desert from a cold save.
			// executeSwitchMap() owns prefetch/readiness/rollback, so a missing resource cannot
			// destroy the already-restored Home scene or leave input captured by loading UI.
			if (activeMapId != "Home" && mMaps[activeMapId]) {
				GameState.mInstance.executeSwitchMap(activeMapId, null);
			}
'@
  $restorePos=$offline.LastIndexOf($anchor)
  if($restorePos -lt 0){throw 'ACTIVE_MAP_FIX=FAIL home_bootstrap_anchor_missing'}
  $restorePos+=$anchor.Length
  $offline=$offline.Insert($restorePos,$restore)
}

foreach($required in @(
  'savedata["active_map_id"] = map_id.indexOf("pvp_") == -1 ? map_id : "Home";',
  'savedata["saveversion"] = 6;',
  'if (version < 6) {',
  'var activeMapId: String = "Home";',
  'GameState.GRAPHICS_MAP_ID_LIST.indexOf(activeMapId) < 0',
  'restore_active_map_after_home_bootstrap',
  'if (activeMapId != "Home" && mMaps[activeMapId]) {',
  'GameState.mInstance.executeSwitchMap(activeMapId, null);'
)){
  if(-not $offline.Contains($required)){throw "ACTIVE_MAP_FIX=FAIL required_pattern=$required"}
}
if($offline -ne $originalOffline){Set-Content -LiteralPath $offlinePath -Value $offline -Encoding UTF8}

$test=Get-Content -LiteralPath $testPath -Raw
$originalTest=$test
if($test -notmatch 'offline_save_persists_active_map_id'){
  $anchor='$audit=Join-Path $RepoRoot ''Tools\\CI\\Audit-SwfCore.ps1'''
  if(-not $test.Contains($anchor)){throw 'ACTIVE_MAP_FIX=FAIL regression_anchor_missing'}
  $checks=@'
Require-Contains $offline 'savedata["active_map_id"] = map_id.indexOf("pvp_") == -1 ? map_id : "Home";' 'offline_save_persists_only_stable_world'
Require-Contains $offline 'savedata["saveversion"] = 6;' 'offline_save_version_bumped_for_active_map'
Require-Contains $offline 'if (version < 6) {' 'offline_old_save_active_map_migration'
Require-Contains $offline 'var activeMapId: String = "Home";' 'offline_restore_defaults_home'
Require-Contains $offline 'GameState.GRAPHICS_MAP_ID_LIST.indexOf(activeMapId) < 0' 'offline_restore_rejects_unknown_map'
Require-Contains $offline 'if (activeMapId != "Home" && mMaps[activeMapId]) {' 'offline_restore_requires_saved_destination'
Require-Contains $offline 'GameState.mInstance.executeSwitchMap(activeMapId, null);' 'offline_restore_uses_resource_gated_transition'
Require-NotContains $offline 'loadMap(mMaps[activeMapId]);' 'offline_restore_never_direct_loads_cold_desert'
'@
  $test=$test.Replace($anchor,$checks+"`r`n"+$anchor)
}
$test=$test.Replace('REGRESSION=PASS suite=android-runtime-v3.12-tooltip-timer-lifecycle','REGRESSION=PASS suite=android-runtime-v3.13-active-map-restore')
if($test -ne $originalTest){Set-Content -LiteralPath $testPath -Value $test -Encoding UTF8}

Write-Host 'ACTIVE_MAP_FIX=PASS staged=OfflineSave.as,Test-AndroidRuntimePatch.ps1'
