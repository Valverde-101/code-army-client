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
$tmp1=Join-Path $outDir 'swf-perf-tilemap.tmp.swf'
$tmp2=Join-Path $outDir 'swf-perf-scene.tmp.swf'
$tmp3=Join-Path $outDir 'swf-feature-hud.tmp.swf'
$tmp4=Join-Path $outDir 'swf-feature-worldmap.tmp.swf'
foreach($p in @($tmp1,$tmp2,$tmp3,$tmp4,$OutputSwf)){Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}

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
  }finally{
    $ErrorActionPreference=$previousErrorActionPreference
  }
  $lines|Set-Content -LiteralPath $log -Encoding UTF8
  if($exit -ne 0 -or -not (Test-Path -LiteralPath $Out)){
    $lines|Select-Object -Last 120|ForEach-Object{Write-Host $_}
    throw "SWF_PERF_PATCH=FAIL class=$ClassName exit=$exit log=$log"
  }
  Write-Host "SWF_CLASS_PATCH=PASS class=$ClassName log=$log"
}

$tileSource=Join-Path $RepoRoot 'src\game\battlefield\TileMapGraphic.as'
$sceneSource=Join-Path $RepoRoot 'src\game\isometric\IsometricScene.as'
$hudSource=Join-Path $RepoRoot 'src\game\gui\GameHUD.as'
$worldMapSource=Join-Path $RepoRoot 'src\game\gui\popups\WorldMapWindow.as'

# Runtime-stability policy:
# Keep canonical Config, GameState, ArmyButton, animation and audio-adjacent bytecode.
# Recompile only the two rendering hot paths plus the two narrow in-game feature entrypoints.
Invoke-FFDecReplace -In $InputSwf -Out $tmp1 -ClassName 'game.battlefield.TileMapGraphic' -Source $tileSource -LogName 'ffdec-performance-tilemap.log'
Invoke-FFDecReplace -In $tmp1 -Out $tmp2 -ClassName 'game.isometric.IsometricScene' -Source $sceneSource -LogName 'ffdec-performance-scene.log'
Invoke-FFDecReplace -In $tmp2 -Out $tmp3 -ClassName 'game.gui.GameHUD' -Source $hudSource -LogName 'ffdec-feature-hud.log'
Invoke-FFDecReplace -In $tmp3 -Out $tmp4 -ClassName 'game.gui.popups.WorldMapWindow' -Source $worldMapSource -LogName 'ffdec-feature-worldmap.log'
Move-Item -LiteralPath $tmp4 -Destination $OutputSwf -Force
foreach($p in @($tmp1,$tmp2,$tmp3)){Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}

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
foreach($className in @('game.battlefield.TileMapGraphic','game.isometric.IsometricScene','game.gui.GameHUD','game.gui.popups.WorldMapWindow')){
  if($dumpText -notmatch [regex]::Escape($className)){throw "SWF_PERF_PATCH=FAIL class_missing_after_patch=$className"}
}

$manifest=[ordered]@{
  schema_version=1
  repository='Valverde-101/code-army-client'
  tested_sha=$ExpectedSha
  patch_version='mobile-engine-v3.3-features-safe'
  source_swf=[ordered]@{path=$InputSwf;size=(Get-Item $InputSwf).Length;sha256=$inputSha}
  output_swf=[ordered]@{path=$OutputSwf;size=$outputInfo.Length;sha256=$outputSha}
  classes=@(
    [ordered]@{name='game.battlefield.TileMapGraphic';source='src/game/battlefield/TileMapGraphic.as';sha256=(Get-FileHash $tileSource -Algorithm SHA256).Hash.ToLowerInvariant()},
    [ordered]@{name='game.isometric.IsometricScene';source='src/game/isometric/IsometricScene.as';sha256=(Get-FileHash $sceneSource -Algorithm SHA256).Hash.ToLowerInvariant()},
    [ordered]@{name='game.gui.GameHUD';source='src/game/gui/GameHUD.as';sha256=(Get-FileHash $hudSource -Algorithm SHA256).Hash.ToLowerInvariant()},
    [ordered]@{name='game.gui.popups.WorldMapWindow';source='src/game/gui/popups/WorldMapWindow.as';sha256=(Get-FileHash $worldMapSource -Algorithm SHA256).Hash.ToLowerInvariant()}
  )
  guarantees=@(
    'enemy_character_update_cadence_unchanged',
    'enemy_actions_update_cadence_unchanged',
    'enemy_movement_update_cadence_unchanged',
    'visual_assets_preserved_from_source_swf',
    'audio_assets_preserved_from_source_swf',
    'animate_linkage_preserved_from_source_swf'
  )
  feature_patch_version='offline-entrypoints-v3'
  optimizations=@(
    'padded_tilemap_camera_cache_256px',
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
    'canonical_config_bytecode_preserved',
    'canonical_gamestate_bytecode_preserved',
    'canonical_armybutton_bytecode_preserved',
    'canonical_animationcontroller_bytecode_preserved',
    'canonical_enveffectmanager_bytecode_preserved',
    'canonical_menu_button_lifecycle_preserved',
    'canonical_audio_lifecycle_preserved'
  )
  generated_utc=[DateTime]::UtcNow.ToString('o')
}
$manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ManifestPath -Encoding UTF8
Write-Host "SWF_PERFORMANCE_PATCH=PASS version=mobile-engine-v3.3-features-safe source_sha256=$inputSha patched_sha256=$outputSha size=$($outputInfo.Length) manifest=$ManifestPath"
Write-Output $OutputSwf
