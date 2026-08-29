param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$InputSwf,
  [Parameter(Mandatory=$true)][string]$OutputSwf,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [string]$ExpectedSourceSha256='99a7e8c219610eabbe97aee74228d52ded1532b4c2d4310432d15082b2ff11c4',
  [string]$ManifestPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$git=Get-Command git.exe -ErrorAction SilentlyContinue
if(-not $git){$git=Get-Command git -ErrorAction SilentlyContinue}
if(-not $git){throw 'SWF_PERF_PATCH=FAIL git_missing'}
$head=(& $git.Source -C $RepoRoot rev-parse HEAD).Trim()
if($head -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$head"}
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
foreach($p in @($tmp1,$tmp2,$OutputSwf)){Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}

function Invoke-FFDecReplace([string]$In,[string]$Out,[string]$ClassName,[string]$Source,[string]$LogName){
  if(-not (Test-Path -LiteralPath $Source)){throw "SWF_PERF_PATCH=FAIL source_missing=$Source"}
  $args=@('-cli','-air','-onerror','abort','-replace',$In,$Out,$ClassName,$Source)
  $log=Join-Path $outDir $LogName
  if($java){$lines=@(& $java.Source '-jar' $ffdec.FullName @args 2>&1|ForEach-Object{$_.ToString()})}
  else{$lines=@(& $ffdec.FullName @args 2>&1|ForEach-Object{$_.ToString()})}
  $exit=$LASTEXITCODE
  $lines|Set-Content -LiteralPath $log -Encoding UTF8
  if($exit -ne 0 -or -not (Test-Path -LiteralPath $Out)){
    $lines|Select-Object -Last 80|ForEach-Object{Write-Host $_}
    throw "SWF_PERF_PATCH=FAIL class=$ClassName exit=$exit log=$log"
  }
  Write-Host "SWF_CLASS_PATCH=PASS class=$ClassName log=$log"
}

$tileSource=Join-Path $RepoRoot 'src\game\battlefield\TileMapGraphic.as'
$sceneSource=Join-Path $RepoRoot 'src\game\isometric\IsometricScene.as'
# Patch dependency first so IsometricScene can compile against updateCameraViewport().
Invoke-FFDecReplace -In $InputSwf -Out $tmp1 -ClassName 'game.battlefield.TileMapGraphic' -Source $tileSource -LogName 'ffdec-performance-tilemap.log'
Invoke-FFDecReplace -In $tmp1 -Out $tmp2 -ClassName 'game.isometric.IsometricScene' -Source $sceneSource -LogName 'ffdec-performance-scene.log'
Move-Item -LiteralPath $tmp2 -Destination $OutputSwf -Force
Remove-Item -LiteralPath $tmp1 -Force -ErrorAction SilentlyContinue

$outputInfo=Get-Item -LiteralPath $OutputSwf
$outputSha=(Get-FileHash -LiteralPath $OutputSwf -Algorithm SHA256).Hash.ToLowerInvariant()
if($outputSha -eq $inputSha){throw 'SWF_PERF_PATCH=FAIL output_equals_source'}
if($outputInfo.Length -lt 10000000){throw "SWF_PERF_PATCH=FAIL suspicious_size=$($outputInfo.Length)"}

$dumpLog=Join-Path $outDir 'ffdec-performance-dumpas3.log'
$dumpArgs=@('-cli','-dumpAS3',$OutputSwf)
if($java){$dump=@(& $java.Source '-jar' $ffdec.FullName @dumpArgs 2>&1|ForEach-Object{$_.ToString()})}
else{$dump=@(& $ffdec.FullName @dumpArgs 2>&1|ForEach-Object{$_.ToString()})}
$dumpExit=$LASTEXITCODE
$dump|Set-Content -LiteralPath $dumpLog -Encoding UTF8
if($dumpExit -ne 0){throw "SWF_PERF_PATCH=FAIL dump_exit=$dumpExit"}
$dumpText=$dump -join "`n"
foreach($className in @('game.battlefield.TileMapGraphic','game.isometric.IsometricScene')){
  if($dumpText -notmatch [regex]::Escape($className)){throw "SWF_PERF_PATCH=FAIL class_missing_after_patch=$className"}
}

$manifest=[ordered]@{
  schema_version=1
  repository='Valverde-101/code-army-client'
  tested_sha=$ExpectedSha
  patch_version='mobile-engine-v1'
  source_swf=[ordered]@{path=$InputSwf;size=(Get-Item $InputSwf).Length;sha256=$inputSha}
  output_swf=[ordered]@{path=$OutputSwf;size=$outputInfo.Length;sha256=$outputSha}
  classes=@(
    [ordered]@{name='game.battlefield.TileMapGraphic';source='src/game/battlefield/TileMapGraphic.as';sha256=(Get-FileHash $tileSource -Algorithm SHA256).Hash.ToLowerInvariant()},
    [ordered]@{name='game.isometric.IsometricScene';source='src/game/isometric/IsometricScene.as';sha256=(Get-FileHash $sceneSource -Algorithm SHA256).Hash.ToLowerInvariant()}
  )
  guarantees=@(
    'enemy_character_update_cadence_unchanged',
    'enemy_actions_update_cadence_unchanged',
    'enemy_movement_update_cadence_unchanged',
    'visual_assets_preserved_from_source_swf',
    'audio_assets_preserved_from_source_swf',
    'animate_linkage_preserved_from_source_swf'
  )
  optimizations=@(
    'padded_tilemap_camera_cache_256px',
    'tilemap_rebuild_threshold_72pct',
    'remove_unused_sort_hit_tests',
    'fix_sort_order_change_index_comparison',
    'indexed_character_hot_loop',
    'indexed_static_object_hot_loop'
  )
  generated_utc=[DateTime]::UtcNow.ToString('o')
}
$manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ManifestPath -Encoding UTF8
Write-Host "SWF_PERFORMANCE_PATCH=PASS version=mobile-engine-v1 source_sha256=$inputSha patched_sha256=$outputSha size=$($outputInfo.Length) manifest=$ManifestPath"
Write-Output $OutputSwf
