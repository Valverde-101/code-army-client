param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$InputSwf,
  [Parameter(Mandatory=$true)][string]$OutputSwf,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [string]$GitPath,
  [string]$ExpectedSourceSha256='99a7e8c219610eabbe97aee74228d52ded1532b4c2d4310432d15082b2ff11c4',
  [string]$ManifestPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$gitCandidates=@()
if($GitPath){$gitCandidates+=$GitPath}
$gitCmd=Get-Command git.exe -ErrorAction SilentlyContinue
if($gitCmd){$gitCandidates+=$gitCmd.Source}
$repoParent=Split-Path -Parent $RepoRoot
$androidBuildRoot=Split-Path -Parent $repoParent
$gitCandidates+=@(
  (Join-Path $androidBuildRoot 'Tools\Git\cmd\git.exe'),
  (Join-Path $androidBuildRoot 'PortableGit\cmd\git.exe')
)
$git=$gitCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
if(-not $git){throw "SWF_PERF_PATCH=FAIL git_missing candidates=$($gitCandidates -join ';')"}
$head=(& $git -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0){throw "SWF_PERF_PATCH=FAIL git_head_exit=$LASTEXITCODE git=$git"}
if($head -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$head"}
Write-Host "SWF_PATCH_GIT=PASS path=$git head=$head"
if(-not (Test-Path -LiteralPath $InputSwf)){throw "SWF_PERF_PATCH=FAIL input_missing=$InputSwf"}
$inputSha=(Get-FileHash -LiteralPath $InputSwf -Algorithm SHA256).Hash.ToLowerInvariant()
if($inputSha -ne $ExpectedSourceSha256.ToLowerInvariant()){throw "SWF_PERF_PATCH=FAIL source_sha expected=$ExpectedSourceSha256 actual=$inputSha"}

$ensure=Join-Path $RepoRoot 'Tools\SWF\Ensure-FFDec.ps1'
if(-not (Test-Path -LiteralPath $ensure)){throw "SWF_PERF_PATCH=FAIL ensure_ffdec_missing=$ensure"}
& $ensure -RepositoryRoot $RepoRoot

$ffdec=Get-ChildItem -LiteralPath (Join-Path $RepoRoot '.work\tools\ffdec') -Recurse -File -ErrorAction Stop |
  Where-Object{$_.Name -in @('ffdec-cli.exe','ffdec.bat','ffdec.jar')} |
  Sort-Object FullName -Descending | Select-Object -First 1
if(-not $ffdec){throw 'SWF_PERF_PATCH=FAIL ffdec_not_found'}
$java=$null
if($ffdec.Extension -eq '.jar'){
  $java=Get-Command java.exe -ErrorAction SilentlyContinue
  if(-not $java){throw 'SWF_PERF_PATCH=FAIL java_missing'}
}

$outDir=Split-Path -Parent $OutputSwf
New-Item -ItemType Directory -Force -Path $outDir|Out-Null
if(-not $ManifestPath){$ManifestPath=Join-Path $outDir 'SWF-PERFORMANCE-PATCH.json'}
$patchVersion='mobile-engine-v3.20-pvp-powerup-env-hud-rootfix'
$patchSpecs=@(
  [ordered]@{Class='FeatureTuner';Source='src\FeatureTuner.as';Log='ffdec-feature-tuner.log'},
  [ordered]@{Class='game.environment.EnvEffectManager';Source='src\game\environment\EnvEffectManager.as';Log='ffdec-performance-environment.log'},
  [ordered]@{Class='game.battlefield.TileMapGraphic';Source='src\game\battlefield\TileMapGraphic.as';Log='ffdec-performance-tilemap.log'},
  [ordered]@{Class='game.isometric.IsometricScene';Source='src\game\isometric\IsometricScene.as';Log='ffdec-performance-scene.log'},
  [ordered]@{Class='game.battlefield.MapData';Source='src\game\battlefield\MapData.as';Log='ffdec-feature-mapdata.log'},
  [ordered]@{Class='game.isometric.characters.IsometricCharacter';Source='src\game\isometric\characters\IsometricCharacter.as';Log='ffdec-feature-character-hints.log'},
  [ordered]@{Class='game.characters.AnimationController';Source='src\game\characters\AnimationController.as';Log='ffdec-feature-animation-controller.log'},
  [ordered]@{Class='com.dchoc.graphics.DCResourceManager';Source='src\com\dchoc\graphics\DCResourceManager.as';Log='ffdec-feature-resource-manager.log'},
  [ordered]@{Class='com.dchoc.GUI.DCButton';Source='src\com\dchoc\GUI\DCButton.as';Log='ffdec-feature-dcbutton.log'},
  [ordered]@{Class='Utils';Source='src\Utils.as';Log='ffdec-performance-utils.log'},
  [ordered]@{Class='game.characters.PvPEnemyUnit';Source='src\game\characters\PvPEnemyUnit.as';Log='ffdec-feature-pvp-enemy-visual.log'},
  [ordered]@{Class='game.utils.OfflineSave';Source='src\game\utils\OfflineSave.as';Log='ffdec-feature-offlinesave.log'},
  [ordered]@{Class='game.net.PvPMatch';Source='src\game\net\PvPMatch.as';Log='ffdec-feature-pvp-match.log'},
  [ordered]@{Class='game.states.GameState';Source='src\game\states\GameState.as';Log='ffdec-feature-gamestate.log'},
  [ordered]@{Class='game.gameElements.PlayerBuildingObject';Source='src\game\gameElements\PlayerBuildingObject.as';Log='ffdec-performance-player-building.log'},
  [ordered]@{Class='game.gameElements.HFEObject';Source='src\game\gameElements\HFEObject.as';Log='ffdec-feature-hfe-harvest.log'},
  [ordered]@{Class='game.items.PowerUpItem';Source='src\game\items\PowerUpItem.as';Log='ffdec-feature-pvp-powerup-item.log'},
  [ordered]@{Class='game.gameElements.PowerUpObject';Source='src\game\gameElements\PowerUpObject.as';Log='ffdec-feature-pvp-powerup-object.log'},
  [ordered]@{Class='game.gameElements.FireMissionObject';Source='src\game\gameElements\FireMissionObject.as';Log='ffdec-feature-firemission-object.log'},
  [ordered]@{Class='game.gameElements.LootReward';Source='src\game\gameElements\LootReward.as';Log='ffdec-feature-pvp-loot.log'},
  [ordered]@{Class='game.actions.PvPAttackEnemyAction';Source='src\game\actions\PvPAttackEnemyAction.as';Log='ffdec-feature-pvp-attack.log'},
  [ordered]@{Class='game.actions.PvPAttackEnemyInstallationAction';Source='src\game\actions\PvPAttackEnemyInstallationAction.as';Log='ffdec-feature-pvp-installation-attack.log'},
  [ordered]@{Class='game.actions.FireMissionAction';Source='src\game\actions\FireMissionAction.as';Log='ffdec-feature-firemission-action.log'},
  [ordered]@{Class='game.actions.PvPFireMissionAction';Source='src\game\actions\PvPFireMissionAction.as';Log='ffdec-feature-pvp-firemission.log'},
  [ordered]@{Class='game.gui.GameHUD';Source='src\game\gui\GameHUD.as';Log='ffdec-feature-gamehud.log'},
  [ordered]@{Class='game.gui.pvp.PvPDebriefingDialog';Source='src\game\gui\pvp\PvPDebriefingDialog.as';Log='ffdec-feature-pvp-debriefing.log'},
  [ordered]@{Class='game.gui.GiveFilePermissionDialog';Source='src\game\gui\GiveFilePermissionDialog.as';Log='ffdec-feature-save-permission.log'},
  [ordered]@{Class='game.gui.popups.WorldMapWindow';Source='src\game\gui\popups\WorldMapWindow.as';Log='ffdec-feature-worldmap.log'},
  [ordered]@{Class='game.gui.pvp.PvPMatchUpDialog';Source='src\game\gui\pvp\PvPMatchUpDialog.as';Log='ffdec-feature-pvp-matchup.log'},
  [ordered]@{Class='game.gui.pvp.PvPCombatSetupDialog';Source='src\game\gui\pvp\PvPCombatSetupDialog.as';Log='ffdec-feature-pvp-combat.log'},
  [ordered]@{Class='game.gui.pvp.PvPBoosterBar';Source='src\game\gui\pvp\PvPBoosterBar.as';Log='ffdec-feature-pvp-booster.log'},
  [ordered]@{Class='game.gui.pvp.PvPHUD';Source='src\game\gui\pvp\PvPHUD.as';Log='ffdec-feature-pvp-hud.log'}
)

# Root-regression assertions are deliberately in the patcher itself, so a candidate
# cannot silently build an old constructor contract, old airdrop routing or old LOW policy.
$featureSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\FeatureTuner.as') -Raw
$envSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\environment\EnvEffectManager.as') -Raw
$powerSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\gameElements\PowerUpObject.as') -Raw
$fireBaseSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\game\actions\FireMissionAction.as') -Raw
if($featureSource -notmatch 'USE_ENVIRONMENT_EFFECTS' -or $featureSource -notmatch '!USE_LOW_SWF'){throw 'SWF_ROOT_FIX_REGRESSION=FAIL check=low_environment_policy'}
if($envSource -notmatch 'if\(!FeatureTuner\.USE_ENVIRONMENT_EFFECTS\)'){throw 'SWF_ROOT_FIX_REGRESSION=FAIL check=environment_fast_skip'}
if($powerSource -notmatch 'resolvePlayerAirdropGraphics' -or $powerSource -notmatch 'PVP_POWERUP_FIREMISSION_PHASE' -or $powerSource -notmatch 'PVP_POWERUP_FIREMISSION_ERROR'){throw 'SWF_ROOT_FIX_REGRESSION=FAIL check=pvp_powerup_trace'}
if($fireBaseSource -notmatch 'param3:String\s*=\s*null' -or $fireBaseSource -notmatch 'mGraphicsOverride'){throw 'SWF_ROOT_FIX_REGRESSION=FAIL check=firemission_base_contract'}
if(-not @($patchSpecs|Where-Object{$_.Class -eq 'game.actions.FireMissionAction'})){throw 'SWF_ROOT_FIX_REGRESSION=FAIL check=firemission_base_not_patched'}
Write-Host 'SWF_ROOT_FIX_REGRESSION=PASS firemission_base=true paratrooper_route=true low_environment=true'

$logRoot=Split-Path -Parent $ManifestPath
if(-not $logRoot){$logRoot=$outDir}
New-Item -ItemType Directory -Force -Path $logRoot|Out-Null
function Invoke-FFDecReplace([string]$In,[string]$Out,[string]$ClassName,[string]$Source,[string]$LogName){
  if(-not (Test-Path -LiteralPath $Source)){throw "SWF_PERF_PATCH=FAIL source_missing=$Source"}
  $args=@('-cli','-air','-onerror','abort','-replace',$In,$Out,$ClassName,$Source)
  $log=Join-Path $logRoot $LogName
  $previousErrorActionPreference=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    if($java){$lines=@(& $java.Source '-jar' $ffdec.FullName @args 2>&1|ForEach-Object{$_.ToString()})}
    else{$lines=@(& $ffdec.FullName @args 2>&1|ForEach-Object{$_.ToString()})}
    $exit=$LASTEXITCODE
  }finally{$ErrorActionPreference=$previousErrorActionPreference}
  $lines|Set-Content -LiteralPath $log -Encoding UTF8
  if($exit -ne 0 -or -not (Test-Path -LiteralPath $Out)){
    $lines|Select-Object -Last 120|ForEach-Object{Write-Host $_}
    throw "SWF_PERF_PATCH=FAIL class=$ClassName exit=$exit log=$log"
  }
  Write-Host "SWF_CLASS_PATCH=PASS class=$ClassName log=$log"
}

function Convert-MobileAirSourceForFFDec([string]$Source,[string]$Destination,[string]$ClassName){
  $sourceLines=Get-Content -LiteralPath $Source
  $result=New-Object System.Collections.Generic.List[string]
  $configMode=$null
  $configIndent=$null
  foreach($line in $sourceLines){
    if($null -eq $configMode){
      if($line -match '^(\s*)CONFIG::(BUILD_FOR_MOBILE_AIR|BUILD_FOR_AIR|NOT_BUILD_FOR_AIR)\s*\{\s*(?://.*)?\z'){
        $configIndent=$matches[1]
        $configMode=$matches[2]
        continue
      }
      $result.Add($line)
      continue
    }
    if($line -eq ($configIndent + '}')){
      $configMode=$null
      $configIndent=$null
      continue
    }
    if($configMode -eq 'BUILD_FOR_MOBILE_AIR'){
      $result.Add($line)
    }
  }
  if($null -ne $configMode){throw "SWF_PERF_PATCH=FAIL unterminated_config_block source=$Source mode=$configMode"}
  $text=$result -join [Environment]::NewLine
  # FFDec's experimental AS3 compiler does not resolve AIR 24+ permission-only
  # types from the mobile SDK. Preserve runtime semantics in this temporary source.
  $text=$text -replace '(?m)^\s*import flash\.permissions\.PermissionStatus\s*;?\s*$', ''
  $text=$text -replace 'PermissionEvent\.PERMISSION_STATUS', '"permissionStatus"'
  $text=$text -replace 'PermissionStatus\.GRANTED', '"granted"'
  $text=$text -replace '(?m)(\w+)\s*:\s*PermissionEvent\b', '$1:*'

  # GameHUD's authored mission panel animates its own internal bounds. The previous
  # mobile clamp accumulated y += delta on every ENTER_FRAME and also clamped during
  # Close, producing upward drift followed by an abrupt disappearance. Normalize to
  # a stable base Y every frame and let the authored close timeline run untouched.
  if($ClassName -eq 'game.gui.GameHUD'){
    foreach($needle in @(
      'private var mMobileRightMenuBaseY:Number = 0;',
      'var bounds:Rectangle = param1.getBounds(this.mIngameHUDClip_BOTTOM);',
      'param1.y += deltaY;',
      'this.mPullOutMissionFrame.y = Math.max(0,localHeight - this.mPullOutMissionFrame.height);',
      'this.mPullOutMissionFrame.gotoAndPlay("Open");',
      'this.mPullOutMissionFrame.gotoAndPlay("Close");'
    )){if(-not $text.Contains($needle)){throw "SWF_GAMEHUD_FIX=FAIL missing_pattern=$needle"}}
    $nl=[Environment]::NewLine
    $tab="`t"
    $text=$text.Replace('private var mMobileRightMenuBaseY:Number = 0;','private var mMobileRightMenuBaseY:Number = 0;'+$nl+$tab+$tab+'private var mMobileMissionMenuBaseY:Number = 0;')
    $text=$text.Replace('if(!param1 || !this.mIngameHUDClip_BOTTOM) return;','if(!param1 || !this.mIngameHUDClip_BOTTOM) return;'+$nl+$tab+$tab+$tab+'if(param2 == "missions" && this.mPullOutMissionMenuState == this.STATE_MISSIONS_MENU_CLOSED) return;')
    $text=$text.Replace('var bounds:Rectangle = param1.getBounds(this.mIngameHUDClip_BOTTOM);','var baseY:Number = param2 == "missions" ? this.mMobileMissionMenuBaseY : this.mMobileRightMenuBaseY;'+$nl+$tab+$tab+$tab+'param1.y = baseY;'+$nl+$tab+$tab+$tab+'var bounds:Rectangle = param1.getBounds(this.mIngameHUDClip_BOTTOM);')
    $text=$text.Replace('param1.y += deltaY;','param1.y = baseY + deltaY;')
    $text=$text.Replace('this.mPullOutMissionFrame.y = Math.max(0,localHeight - this.mPullOutMissionFrame.height);','this.mPullOutMissionFrame.y = Math.max(0,localHeight - this.mPullOutMissionFrame.height);'+$nl+$tab+$tab+$tab+$tab+'this.mMobileMissionMenuBaseY = this.mPullOutMissionFrame.y;')
    $text=$text.Replace('this.mPullOutMissionFrame.gotoAndPlay("Open");','this.mPullOutMissionFrame.y = this.mMobileMissionMenuBaseY;'+$nl+$tab+$tab+$tab+$tab+'this.mPullOutMissionFrame.gotoAndPlay("Open");'+$nl+$tab+$tab+$tab+$tab+'Utils.DiagEvent("HUD_MISSION_TRANSITION","phase=open_begin;base_y=" + this.mMobileMissionMenuBaseY + ";y=" + this.mPullOutMissionFrame.y);')
    $text=$text.Replace('this.mPullOutMissionFrame.gotoAndPlay("Close");','this.mPullOutMissionFrame.gotoAndPlay("Close");'+$nl+$tab+$tab+$tab+$tab+'Utils.DiagEvent("HUD_MISSION_TRANSITION","phase=close_begin;y=" + this.mPullOutMissionFrame.y + ";frame=" + this.mPullOutMissionFrame.currentFrame);')
    if($text.Contains('param1.y += deltaY;') -or -not $text.Contains('mMobileMissionMenuBaseY') -or -not $text.Contains('param1.y = baseY + deltaY;')){throw 'SWF_GAMEHUD_FIX=FAIL postcondition'}
    if($text -match '\\t'){throw 'SWF_GAMEHUD_FIX=FAIL literal_backslash_tab_survived'}
    if($text -match '\btprivate\b'){throw 'SWF_GAMEHUD_FIX=FAIL invalid_namespace_tprivate'}
    Write-Host 'SWF_GAMEHUD_FIX=PASS mission_clamp=non_accumulating close_clamp=disabled indentation=real_tabs'
  }

  if($text -match 'CONFIG::'){throw "SWF_PERF_PATCH=FAIL config_directive_survived source=$Source"}
  if($text -cmatch '\bPermissionEvent\b|\bPermissionStatus\b'){throw "SWF_PERF_PATCH=FAIL air_permission_type_survived source=$Source"}
  Set-Content -LiteralPath $Destination -Value $text -Encoding UTF8
  Write-Host "FFDEC_AIR_PERMISSION_SHIM=PASS class=$ClassName event=permissionStatus granted=granted"
  Write-Host "FFDEC_SOURCE_PREPROCESS=PASS class=$ClassName target=BUILD_FOR_MOBILE_AIR path=$Destination"
}

Remove-Item -LiteralPath $OutputSwf -Force -ErrorAction SilentlyContinue
$current=$InputSwf
$tempFiles=New-Object System.Collections.Generic.List[string]
$tempSources=New-Object System.Collections.Generic.List[string]
for($i=0;$i -lt $patchSpecs.Count;$i++){
  $spec=$patchSpecs[$i]
  $source=Join-Path $RepoRoot $spec.Source
  if($spec.Class -in @('game.states.GameState','game.gui.GameHUD','game.gui.GiveFilePermissionDialog','game.isometric.IsometricScene')){
    $leafClass=[System.IO.Path]::GetFileNameWithoutExtension([string]$spec.Source)
    $ffdecSource=Join-Path $outDir ($leafClass + '.mobile.ffdec.as')
    Remove-Item -LiteralPath $ffdecSource -Force -ErrorAction SilentlyContinue
    Convert-MobileAirSourceForFFDec -Source $source -Destination $ffdecSource -ClassName ([string]$spec.Class)
    $source=$ffdecSource
    $tempSources.Add($ffdecSource)
  }
  $next=if($i -eq $patchSpecs.Count-1){$OutputSwf}else{Join-Path $outDir ("swf-runtime-patch-{0:D2}.tmp.swf" -f $i)}
  Remove-Item -LiteralPath $next -Force -ErrorAction SilentlyContinue
  Invoke-FFDecReplace -In $current -Out $next -ClassName $spec.Class -Source $source -LogName $spec.Log
  if($current -ne $InputSwf -and $current -ne $OutputSwf){$tempFiles.Add($current)}
  $current=$next
}
foreach($tmp in $tempFiles){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
foreach($tmpSource in $tempSources){Remove-Item -LiteralPath $tmpSource -Force -ErrorAction SilentlyContinue}

$outputInfo=Get-Item -LiteralPath $OutputSwf
$outputSha=(Get-FileHash -LiteralPath $OutputSwf -Algorithm SHA256).Hash.ToLowerInvariant()
if($outputSha -eq $inputSha){throw 'SWF_PERF_PATCH=FAIL output_equals_source'}
if($outputInfo.Length -lt 10000000){throw "SWF_PERF_PATCH=FAIL suspicious_size=$($outputInfo.Length)"}

$dumpLog=Join-Path $logRoot 'ffdec-performance-dumpas3.log'
$dumpArgs=@('-cli','-dumpAS3',$OutputSwf)
if($java){$dump=@(& $java.Source '-jar' $ffdec.FullName @dumpArgs 2>&1|ForEach-Object{$_.ToString()})}
else{$dump=@(& $ffdec.FullName @dumpArgs 2>&1|ForEach-Object{$_.ToString()})}
$dumpExit=$LASTEXITCODE
$dump|Set-Content -LiteralPath $dumpLog -Encoding UTF8
if($dumpExit -ne 0){throw "SWF_PERF_PATCH=FAIL dump_exit=$dumpExit"}
$dumpText=$dump -join "`n"
foreach($spec in $patchSpecs){
  $className=[string]$spec.Class
  if($dumpText -notmatch [regex]::Escape($className)){throw "SWF_PERF_PATCH=FAIL class_missing_after_patch=$className"}
}

$manifest=[ordered]@{
  schema_version=1
  repository='Valverde-101/code-army-client'
  tested_sha=$ExpectedSha
  patch_version=$patchVersion
  source_swf=[ordered]@{path=$InputSwf;size=(Get-Item $InputSwf).Length;sha256=$inputSha}
  output_swf=[ordered]@{path=$OutputSwf;size=$outputInfo.Length;sha256=$outputSha}
  classes=@($patchSpecs|ForEach-Object{
    $source=Join-Path $RepoRoot $_.Source
    [ordered]@{name=[string]$_.Class;source=([string]$_.Source).Replace('\','/');sha256=(Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()}
  })
  guarantees=@(
    'enemy_character_update_cadence_unchanged',
    'enemy_actions_update_cadence_unchanged',
    'enemy_movement_update_cadence_unchanged',
    'visual_assets_preserved_from_source_swf',
    'audio_assets_preserved_from_source_swf',
    'animate_linkage_preserved_from_source_swf'
  )
  feature_patch_version='offline-systems-v5-root-recovery'
  optimizations=@(
    'padded_tilemap_camera_cache_256px',
    'deterministic_tile_bitmap_cache_disposal_before_zoom_rebuild',
    'tilemap_rebuild_threshold_72pct',
    'remove_unused_sort_hit_tests',
    'fix_sort_order_change_index_comparison',
    'indexed_character_hot_loop',
    'indexed_static_object_hot_loop',
    'skip_global_membership_scan_while_camera_pans',
    'skip_sort_when_object_positions_are_unchanged',
    'reuse_existing_mouse_cell_result',
    'viewport_cull_offscreen_renderables_384px',
    'persistent_visible_membership_dictionary',
    'android_pinch_zoom_enabled',
    'pinch_zoom_bypasses_tutorial_gate',
    'offline_pvp_button_visible_without_level_gate',
    'offline_pvp_bootstrap_before_match_dialog',
    'offline_world_map_button_visible',
    'offline_world_map_home_desert_enabled',
    'offline_world_map_single_canonical_switch_path',
    'offline_saved_map_id_normalization',
    'pvp_transient_map_single_build',
    'pvp_powerup_authored_visual_with_embedded_fallback',
    'pvp_paratrooper_radius3_spawn_recovery',
    'campaign_fog_tilemap_environment_jank_profile',
    'pvp_returns_to_origin_map',
    'pvp_three_visible_opponent_slots_owned',
    'pvp_chance_bounded_percentage',
    'pvp_enemy_randomization_bounded_attempts',
    'mobile_save_onboarding_v22_gate_removed',
    'mobile_save_dialog_fits_viewport',
    'mobile_save_choice_nonblocking',
    'offline_pvp_state_not_reset_on_button_press',
    'offline_pvp_dialog_excludes_global_recent_data',
    'offline_pvp_opponents_bounded_to_valid_ranks',
    'offline_pvp_booster_store_populated',
    'canonical_config_bytecode_preserved',
    'canonical_gamehud_source_with_mobile_runtime_normalization',
    'canonical_armybutton_bytecode_preserved',
    'animationcontroller_cached_movieclip_targets',
    'low_swf_decorative_environment_disabled',
    'canonical_menu_button_lifecycle_preserved',
    'canonical_audio_lifecycle_preserved',
    'pvp_enemy_exact_config_swf_paths',
    'pvp_enemy_full_graphics_provenance',
    'swf_resource_symbol_provenance',
    'pvp_static_buy_fight_buttons',
    'pvp_static_button_root_state_preserves_nested_icons',
    'pvp_cancel_standard_binding',
    'mobile_hud_reference_canvas_parent_scale',
    'hfe_native_timeline_playback',
    'hfe_timeline_progress_diagnostics',
    'mainmap_player_building_passive_10hz',
    'mainmap_viewport_recull_128px_threshold',
    'mainmap_viewport_fallback_recull_20_frames',
    'mainmap_spatial_audio_refresh_10hz',
    'mobile_hud_pullout_visible_bounds_clamp',
    'mobile_left_pullout_non_accumulating_clamp',
    'placement_immediate_visibility_commit',
    'pvp_move_visual_runtime_trace',
    'pvp_loot_runtime_trace',
    'pvp_powerup_spawn_runtime_trace',
    'perf_overlay_always_on_no_start_stop',
    'pvp_weighted_spawn_scalar_amount',
    'pvp_firemission_null_drop_guard',
    'perf_event_hot_path_no_json',
    'perf_sample_2s_flush_15s',
    'runtime_trace_pvp_outcomes',
    'native_perf_provenance_exact_controls',
    'mobile_explicit_placement_check_required',
    'right_hud_close_uses_authored_timeline',
    'pvp_powerup_item_bytecode_applied',
    'pvp_powerup_object_bytecode_applied',
    'pvp_firemission_object_bytecode_applied',
    'pvp_firemission_base_constructor_patched',
    'pvp_player_paratrooper_deterministic_embedded_airdrop',
    'pvp_powerup_phase_stack_trace',
    'pvp_firemission_null_visual_safe',
    'pvp_firemission_single_destroy_lifecycle',
    'hfe_wallclock_resync_30fps',
    'hfe_missing_graphics_safe',
    'pvp_powerup_exception_containment',
    'pvp_firemission_missing_debris_safe',
    'pvp_enemy_materialized_class_trace',
    'swf_resolved_class_identity_trace',
    'hfe_progress_not_mirrored_to_logcat'
  )
  generated_utc=[DateTime]::UtcNow.ToString('o')
}
$manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ManifestPath -Encoding UTF8
Write-Host "SWF_PERFORMANCE_PATCH=PASS version=$patchVersion source_sha256=$inputSha patched_sha256=$outputSha size=$($outputInfo.Length) manifest=$ManifestPath"
Write-Output $OutputSwf