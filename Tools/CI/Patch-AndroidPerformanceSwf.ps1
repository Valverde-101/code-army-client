param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$SourceSwf,
  [Parameter(Mandatory=$true)][string]$OutputSwf,
  [Parameter(Mandatory=$true)][string]$ReportPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(-not (Test-Path -LiteralPath $SourceSwf)){throw "PERF_PATCH=FAIL source_missing=$SourceSwf"}
$sourceInfo=Get-Item -LiteralPath $SourceSwf
$sourceSha=(Get-FileHash -LiteralPath $SourceSwf -Algorithm SHA256).Hash.ToLowerInvariant()

$ensure=Join-Path $RepoRoot 'Tools\SWF\Ensure-FFDec.ps1'
if(-not (Test-Path -LiteralPath $ensure)){throw "PERF_PATCH=FAIL ensure_ffdec_missing=$ensure"}
& $ensure -RepositoryRoot $RepoRoot

$ffdecRoot=Join-Path $RepoRoot '.work\tools\ffdec'
$ffdec=$null
foreach($name in @('ffdec-cli.exe','ffdec.bat','ffdec.jar')){
  $candidate=Get-ChildItem -LiteralPath $ffdecRoot -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
  if($candidate){$ffdec=$candidate.FullName;break}
}
if(-not $ffdec){throw 'PERF_PATCH=FAIL ffdec_not_found'}

$java=$null
if([IO.Path]::GetExtension($ffdec).ToLowerInvariant() -eq '.jar'){
  $javaCmd=Get-Command java.exe -ErrorAction SilentlyContinue
  if($javaCmd){$java=$javaCmd.Source}
  if(-not $java){throw 'PERF_PATCH=FAIL java_not_found_for_ffdec_jar'}
}

$work=Join-Path (Split-Path -Parent $OutputSwf) 'performance-patch-work'
if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
New-Item -ItemType Directory -Force -Path $work,(Split-Path -Parent $ReportPath) | Out-Null

function Invoke-FFDecPerf([string[]]$Arguments,[string]$LogPath){
  if([IO.Path]::GetExtension($ffdec).ToLowerInvariant() -eq '.jar'){
    $lines=@(& $java '-jar' $ffdec @Arguments 2>&1 | ForEach-Object {$_.ToString()})
  }else{
    $lines=@(& $ffdec @Arguments 2>&1 | ForEach-Object {$_.ToString()})
  }
  $exit=$LASTEXITCODE
  $lines|Set-Content -LiteralPath $LogPath -Encoding UTF8
  if($exit -ne 0){
    $lines|Select-Object -Last 100|ForEach-Object{Write-Host $_}
    throw "PERF_PATCH=FAIL ffdec_exit=$exit log=$LogPath"
  }
}

function Export-Class([string]$Swf,[string]$ClassName,[string]$Leaf,[string]$Tag){
  $dir=Join-Path $work ("export-"+$Tag)
  if(Test-Path -LiteralPath $dir){Remove-Item -LiteralPath $dir -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $dir|Out-Null
  Invoke-FFDecPerf @('-cli','-onerror','abort','-selectclass',$ClassName,'-export','script',$dir,$Swf) (Join-Path $work ("export-"+$Tag+".log"))
  $files=@(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter $Leaf -ErrorAction Stop)
  if($files.Count -ne 1){throw "PERF_PATCH=FAIL export class=$ClassName count=$($files.Count)"}
  return $files[0].FullName
}

function Replace-Class([string]$InputSwf,[string]$ClassName,[string]$SourcePath,[string]$OutputPath,[string]$Tag){
  Invoke-FFDecPerf @('-cli','-onerror','abort','-replace',$InputSwf,$OutputPath,$ClassName,$SourcePath) (Join-Path $work ("replace-"+$Tag+".log"))
  if(-not (Test-Path -LiteralPath $OutputPath)){throw "PERF_PATCH=FAIL replace_output_missing class=$ClassName"}
}

function Assert-Contains([string]$Text,[string]$Marker,[string]$Tag){
  if(-not $Text.Contains($Marker)){throw "PERF_PATCH=FAIL marker_missing tag=$Tag marker=$Marker"}
}

$current=$SourceSwf
$isometricExport=Export-Class $current 'game.isometric.IsometricScene' 'IsometricScene.as' 'isometric'
$isometric=[IO.File]::ReadAllText($isometricExport)

if(-not $isometric.Contains('mAndroidPerfStaticAccumulator')){
  $fieldPattern='(?m)^(\s*public\s+var\s+mVisibleObjectCnt\s*:\s*int\s*=\s*0\s*;)'
  if(-not [regex]::IsMatch($isometric,$fieldPattern)){throw 'PERF_PATCH=FAIL isometric_field_anchor'}
  $fieldBlock=@'
$1

      private var mAndroidPerfStaticAccumulator:int = 0;
      private var mAndroidPerfEnvAccumulator:int = 0;
'@
  $isometric=[regex]::Replace($isometric,$fieldPattern,$fieldBlock,1)

  $envPattern='EnvEffectManager\.update\(param1\);'
  if(-not [regex]::IsMatch($isometric,$envPattern)){throw 'PERF_PATCH=FAIL env_update_anchor'}
  $envBlock=@'
this.mAndroidPerfEnvAccumulator += param1;
         if(this.mAndroidPerfEnvAccumulator >= 33)
         {
            EnvEffectManager.update(this.mAndroidPerfEnvAccumulator);
            this.mAndroidPerfEnvAccumulator = 0;
         }
'@
  $isometric=[regex]::Replace($isometric,$envPattern,$envBlock,1)

  $staticPattern='this\.updateCharacters\(param1\);\s*this\.updateStaticObjects\(param1\);\s*this\.updateHudObjects\(param1\);\s*this\.updatePatrols\(param1\);\s*this\.updateDebrisSpawn\(param1\);'
  if(-not [regex]::IsMatch($isometric,$staticPattern)){throw 'PERF_PATCH=FAIL static_update_anchor'}
  $staticBlock=@'
this.updateCharacters(param1);
         this.mAndroidPerfStaticAccumulator += param1;
         if(this.mAndroidPerfStaticAccumulator >= 50)
         {
            var __androidPerfStaticDelta:int = this.mAndroidPerfStaticAccumulator;
            this.mAndroidPerfStaticAccumulator = 0;
            this.updateStaticObjects(__androidPerfStaticDelta);
            this.updatePatrols(__androidPerfStaticDelta);
            this.updateDebrisSpawn(__androidPerfStaticDelta);
         }
         this.updateHudObjects(param1);
'@
  $isometric=[regex]::Replace($isometric,$staticPattern,$staticBlock,1)

}

foreach($marker in @('mAndroidPerfStaticAccumulator','mAndroidPerfEnvAccumulator')){Assert-Contains $isometric $marker 'isometric'}

$isometricPatchedAs=Join-Path $work 'IsometricScene.as'
[IO.File]::WriteAllText($isometricPatchedAs,$isometric,(New-Object Text.UTF8Encoding($false)))
$isometricSwf=Join-Path $work '01-isometric.swf'
Replace-Class $current 'game.isometric.IsometricScene' $isometricPatchedAs $isometricSwf 'isometric'
$current=$isometricSwf
Write-Host 'PERF_PATCH_ISOMETRIC=PASS static_tick_ms=50 env_tick_ms=33 pointer_per_frame=true visibility_scan_per_frame=true'

$enemyExport=Export-Class $current 'game.characters.EnemyUnit' 'EnemyUnit.as' 'enemy'
$enemy=[IO.File]::ReadAllText($enemyExport)
if(-not $enemy.Contains('mAndroidPerfReactionAccumulator')){
  $enemyFieldPattern='(?m)^(\s*private\s+var\s+mWaitingForAirplane\s*:\s*Boolean\s*=\s*false\s*;)'
  if(-not [regex]::IsMatch($enemy,$enemyFieldPattern)){throw 'PERF_PATCH=FAIL enemy_field_anchor'}
  $enemyFieldBlock=@'
$1

      private var mAndroidPerfReactionAccumulator:int = 0;
'@
  $enemy=[regex]::Replace($enemy,$enemyFieldPattern,$enemyFieldBlock,1)

  $reactionLocalPattern='(private\s+function\s+updateReactionState\s*\(\s*param1\s*:\s*int\s*\)\s*:\s*void\s*\{)'
  if(-not [regex]::IsMatch($enemy,$reactionLocalPattern)){throw 'PERF_PATCH=FAIL enemy_reaction_anchor'}
  $reactionBlock=@'
$1
         this.mAndroidPerfReactionAccumulator += param1;
         if(this.mAndroidPerfReactionAccumulator < 50)
         {
            return;
         }
         param1 = this.mAndroidPerfReactionAccumulator;
         this.mAndroidPerfReactionAccumulator = 0;
'@
  $enemy=[regex]::Replace($enemy,$reactionLocalPattern,$reactionBlock,1)
}
foreach($marker in @('mAndroidPerfReactionAccumulator','this.mAndroidPerfReactionAccumulator < 50')){Assert-Contains $enemy $marker 'enemy'}
$enemyPatchedAs=Join-Path $work 'EnemyUnit.as'
[IO.File]::WriteAllText($enemyPatchedAs,$enemy,(New-Object Text.UTF8Encoding($false)))
$enemySwf=Join-Path $work '02-enemy.swf'
Replace-Class $current 'game.characters.EnemyUnit' $enemyPatchedAs $enemySwf 'enemy'
$current=$enemySwf
Write-Host 'PERF_PATCH_ENEMY_AI=PASS reaction_tick_ms=50 movement_per_frame=true projectile_per_frame=true'

$smokeExport=Export-Class $current 'game.particles.SmokeEmitter' 'SmokeEmitter.as' 'smoke'
$smoke=[IO.File]::ReadAllText($smokeExport)
$smoke=[regex]::Replace($smoke,'this\.mMaxConcurrentParticles\s*=\s*40\s*;','this.mMaxConcurrentParticles = 18;',1)
$splicePattern='this\.mParticles\.splice\(_loc2_,\s*1\);'
if([regex]::IsMatch($smoke,$splicePattern) -and -not $smoke.Contains('_loc2_--')){
  $smoke=[regex]::Replace($smoke,$splicePattern,('this.mParticles.splice(_loc2_,1);'+[Environment]::NewLine+'               _loc2_--;'),1)
}
Assert-Contains $smoke 'mMaxConcurrentParticles = 18' 'smoke'
Assert-Contains $smoke '_loc2_--' 'smoke'
$smokePatchedAs=Join-Path $work 'SmokeEmitter.as'
[IO.File]::WriteAllText($smokePatchedAs,$smoke,(New-Object Text.UTF8Encoding($false)))
$smokeSwf=Join-Path $work '03-smoke.swf'
Replace-Class $current 'game.particles.SmokeEmitter' $smokePatchedAs $smokeSwf 'smoke'
$current=$smokeSwf
Write-Host 'PERF_PATCH_SMOKE=PASS max_concurrent_particles=18 cleanup_shift_fix=true'

Copy-Item -LiteralPath $current -Destination $OutputSwf -Force
$outputInfo=Get-Item -LiteralPath $OutputSwf
$outputSha=(Get-FileHash -LiteralPath $OutputSwf -Algorithm SHA256).Hash.ToLowerInvariant()
if($outputSha -eq $sourceSha){throw "PERF_PATCH=FAIL output_hash_unchanged sha256=$outputSha"}

$verifyMarkers=[ordered]@{
  'game.isometric.IsometricScene'=@('mAndroidPerfStaticAccumulator','mAndroidPerfEnvAccumulator')
  'game.characters.EnemyUnit'=@('mAndroidPerfReactionAccumulator')
  'game.particles.SmokeEmitter'=@('mMaxConcurrentParticles = 18','_loc2_--')
}
foreach($className in $verifyMarkers.Keys){
  $leaf=($className.Split('.')[-1]+'.as')
  $tag='verify-'+($className.Replace('.','-'))
  $path=Export-Class $OutputSwf $className $leaf $tag
  $text=[IO.File]::ReadAllText($path)
  foreach($marker in $verifyMarkers[$className]){Assert-Contains $text $marker $tag}
}
Write-Host 'PERF_PATCH_VERIFY=PASS classes=3'

$report=[ordered]@{
  schema_version=1
  patch_version='android-perf-v1'
  source_swf=$SourceSwf
  source_size=$sourceInfo.Length
  source_sha256=$sourceSha
  output_swf=$OutputSwf
  output_size=$outputInfo.Length
  output_sha256=$outputSha
  classes=@('game.isometric.IsometricScene','game.characters.EnemyUnit','game.particles.SmokeEmitter')
  policy=[ordered]@{
    movement_per_frame=$true
    camera_per_frame=$true
    projectiles_per_frame=$true
    hud_per_frame=$true
    static_logic_tick_ms=50
    environment_tick_ms=33
    pointer_hover_per_frame=$true
    enemy_reaction_tick_ms=50
    scrolling_visibility_scan_per_frame=$true
    smoke_max_concurrent_particles=18
  }
}
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Host "PERF_PATCH=PASS version=android-perf-v1 source_sha256=$sourceSha output_sha256=$outputSha source_size=$($sourceInfo.Length) output_size=$($outputInfo.Length)"
Write-Host "PERF_PATCH_REPORT=$ReportPath"
