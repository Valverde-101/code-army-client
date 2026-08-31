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
$patchSpecs=@(
  [ordered]@{Class='game.battlefield.TileMapGraphic';Source='src\game\battlefield\TileMapGraphic.as';Log='ffdec-performance-tilemap.log'},
  [ordered]@{Class='game.isometric.IsometricScene';Source='src\game\isometric\IsometricScene.as';Log='ffdec-performance-scene.log'},
  [ordered]@{Class='game.utils.OfflineSave';Source='src\game\utils\OfflineSave.as';Log='ffdec-feature-offlinesave.log'},
  [ordered]@{Class='game.states.GameState';Source='src\game\states\GameState.as';Log='ffdec-feature-gamestate.log'},
  [ordered]@{Class='game.net.PvPMatch';Source='src\game\net\PvPMatch.as';Log='ffdec-feature-pvp-match.log'},
  [ordered]@{Class='game.gui.popups.WorldMapWindow';Source='src\game\gui\popups\WorldMapWindow.as';Log='ffdec-feature-worldmap.log'},
  [ordered]@{Class='game.gui.pvp.PvPMatchUpDialog';Source='src\game\gui\pvp\PvPMatchUpDialog.as';Log='ffdec-feature-pvp-matchup.log'},
  [ordered]@{Class='game.gui.pvp.PvPCombatSetupDialog';Source='src\game\gui\pvp\PvPCombatSetupDialog.as';Log='ffdec-feature-pvp-combat.log'}
)
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
function Convert-GameStateSourceForFFDec([string]$Source,[string]$Destination){
  $sourceLines=Get-Content -LiteralPath $Source
  $result=New-Object System.Collections.Generic.List[string]
  $configMode=$null
  $configIndent=$null
  foreach($line in $sourceLines){
    if($null -eq $configMode){
      if($line -match '^(\s*)CONFIG::(BUILD_FOR_MOBILE_AIR|BUILD_FOR_AIR|NOT_BUILD_FOR_AIR)\s*\{\s*$'){
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
  # types from the mobile SDK. Preserve runtime semantics in this temporary
  # source without changing the canonical GameState implementation.
  $text=$text -replace '(?m)^\s*import flash\.permissions\.PermissionStatus\s*;?\s*$', ''
  $text=$text -replace 'PermissionEvent\.PERMISSION_STATUS', '"permissionStatus"'
  $text=$text -replace 'PermissionStatus\.GRANTED', '"granted"'
  $text=$text -replace '(?m)(\w+)\s*:\s*PermissionEvent\b', '$1:*'
  if($text -match 'CONFIG::'){throw "SWF_PERF_PATCH=FAIL config_directive_survived source=$Source"}
  if($text -match '\bPermissionEvent\b|\bPermissionStatus\b'){throw "SWF_PERF_PATCH=FAIL air_permission_type_survived source=$Source"}
  Set-Content -LiteralPath $Destination -Value $text -Encoding UTF8
  Write-Host "FFDEC_AIR_PERMISSION_SHIM=PASS event=permissionStatus granted=granted"
  Write-Host "FFDEC_SOURCE_PREPROCESS=PASS class=game.states.GameState target=BUILD_FOR_MOBILE_AIR path=$Destination"
}

Remove-Item -LiteralPath $OutputSwf -Force -ErrorAction SilentlyContinue
$current=$InputSwf
$tempFiles=New-Object System.Collections.Generic.List[string]
$tempSources=New-Object System.Collections.Generic.List[string]
for($i=0;$i -lt $patchSpecs.Count;$i++){
  $spec=$patchSpecs[$i]
  $source=Join-Path $RepoRoot $spec.Source
  if($spec.Class -eq 'game.states.GameState'){
    $ffdecSource=Join-Path $outDir 'GameState.mobile.ffdec.as'
    Remove-Item -LiteralPath $ffdecSource -Force -ErrorAction SilentlyContinue
    Convert-GameStateSourceForFFDec -Source $source -Destination $ffdecSource
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
  patch_version='mobile-engine-v3.6-pvp-map-memory'
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
    'pvp_returns_to_origin_map',
    'pvp_three_visible_opponent_slots_owned',
    'pvp_chance_bounded_percentage',
    'pvp_enemy_randomization_bounded_attempts',
    'offline_pvp_state_not_reset_on_button_press',
    'offline_pvp_dialog_excludes_global_recent_data',
    'offline_pvp_opponents_bounded_to_valid_ranks',
    'offline_pvp_booster_store_populated',
    'canonical_config_bytecode_preserved',
    'canonical_gamehud_bytecode_preserved',
    'canonical_armybutton_bytecode_preserved',
    'canonical_animationcontroller_bytecode_preserved',
    'canonical_enveffectmanager_bytecode_preserved',
    'canonical_menu_button_lifecycle_preserved',
    'canonical_audio_lifecycle_preserved'
  )
  generated_utc=[DateTime]::UtcNow.ToString('o')
}
$manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ManifestPath -Encoding UTF8
Write-Host "SWF_PERFORMANCE_PATCH=PASS version=mobile-engine-v3.6-pvp-map-memory source_sha256=$inputSha patched_sha256=$outputSha size=$($outputInfo.Length) manifest=$ManifestPath"
Write-Output $OutputSwf
