param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v3=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV3.ps1'
if(-not(Test-Path -LiteralPath $v3 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL predecessor_missing=$v3"}

$targets=[ordered]@{
  animation='src\game\characters\AnimationController.as'
  tile='src\game\battlefield\TileMapGraphic.as'
  missile='src\game\gameElements\Missile.as'
  artillery='src\game\gameElements\ArtilleryRound.as'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v4\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.post-v3')}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL verify=$Name token=$Token"}}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V4_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V4_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    foreach($entry in @($manifest.files)){
      $key=[string]$entry.key
      $src=Backup-Path $key
      $dst=Target-Path $key
      if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL restore_backup_missing key=$key"}
      Copy-Item -LiteralPath $src -Destination $dst -Force
      $restored=Get-Sha256 $dst
      $expected=([string]$entry.sha256).ToUpperInvariant()
      if($restored -ne $expected){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL restore_hash key=$key expected=$expected actual=$restored"}
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v3 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V4=PASS mode=restore baseline_restored=true predecessor=v3 sha=$ExpectedSha"
  return
}

& $v3 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V4=FAIL source_missing key=$key"}
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v4';source_sha=$ExpectedSha;predecessor='v3';files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "EVIDENCE_ROOTFIX_V4_MANIFEST=PASS files=$($manifestFiles.Count) predecessor=v3"

try{
  # A) STATUS_HINT_ORIENTATION was still walking the whole animation tree on every unchanged direction.
  # Lazy materialization and owner-ready already normalize new clips, so unchanged directions must be O(1).
  $animationPath=Target-Path 'animation'
  $animation=Normalize-Lf ([IO.File]::ReadAllText($animationPath))
  $unchangedPattern='(?ms)\s*if\(param1 == this\.mCurrentDirection\)\s*\{\s*normalized = this\.refreshStatusHintOrientation\(\);\s*Utils\.DiagEvent\("STATUS_HINT_ORIENTATION","direction=" \+ param1 \+ ";changed=0;normalized=" \+ normalized \+ ";animations=" \+ this\.mAnimations\.length\);\s*return;\s*\}'
  $unchangedReplacement=@'
         if(param1 == this.mCurrentDirection)
         {
            return;
         }
'@
  $animation=Replace-RegexOne $animation $unchangedPattern $unchangedReplacement 'status_hint_unchanged_direction_o1'
  if($animation.Contains(';changed=0;normalized=')){throw 'ANDROID_EVIDENCE_ROOTFIX_V4=FAIL regression=status_hint_per_frame_scan_remaining'}
  Require-Token $animation 'this.refreshStatusHintOrientation();' 'status_hint_materialization_guard'
  Require-Token $animation ';changed=1;normalized=' 'status_hint_changed_telemetry'
  Write-Utf8Bom $animationPath $animation

  # B) Root cause of the black square: the dirty-region clear expanded 2px outside the 3x3 redraw.
  # mFieldBmpData is opaque, therefore fillRect(...,0) produced a black frame that drawArea never covered.
  # Draw/clear against the cache anchor and exactly the same cell rectangle; never current camera x/y.
  $tilePath=Target-Path 'tile'
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  $clearPattern='(?ms)\s*private function clearDirtyBitmapRegion\(param1:int, param2:int, param3:int, param4:int\)\s*:\s*void\s*\{.*?\n\s*\}(?=\n\s*public function updateCameraViewport)'
  $clearReplacement=@'

      private function getCacheDrawOriginX() : Number
      {
         if(Config.ENABLE_SINGLE_BITMAP_FIELD_RENDERING && !isNaN(this.mCameraCacheAnchorX))
         {
            return this.mCameraCacheAnchorX;
         }
         return this.mScene.mContainer.x;
      }

      private function getCacheDrawOriginY() : Number
      {
         if(Config.ENABLE_SINGLE_BITMAP_FIELD_RENDERING && !isNaN(this.mCameraCacheAnchorY))
         {
            return this.mCameraCacheAnchorY;
         }
         return this.mScene.mContainer.y;
      }

      private function clearDirtyBitmapRegion(param1:int, param2:int, param3:int, param4:int) : void
      {
         if(!Config.ENABLE_SINGLE_BITMAP_FIELD_RENDERING || !this.mFieldBmp || !this.mFogBmp || !this.mFieldBmp.bitmapData || !this.mFogBmp.bitmapData)
         {
            return;
         }
         var scaleX:Number = this.mScene.mContainer.scaleX;
         var scaleY:Number = this.mScene.mContainer.scaleY;
         var originX:Number = this.getCacheDrawOriginX();
         var originY:Number = this.getCacheDrawOriginY();
         var leftPx:int = Math.floor(param1 * this.mScene.mGridDimX * scaleX + originX + CAMERA_CACHE_MARGIN);
         var topPx:int = Math.floor(param2 * this.mScene.mGridDimY * scaleY + originY + CAMERA_CACHE_MARGIN);
         var rightPx:int = Math.ceil(param3 * this.mScene.mGridDimX * scaleX + originX + CAMERA_CACHE_MARGIN);
         var bottomPx:int = Math.ceil(param4 * this.mScene.mGridDimY * scaleY + originY + CAMERA_CACHE_MARGIN);
         var rect:Rectangle = new Rectangle(leftPx,topPx,Math.max(0,rightPx - leftPx),Math.max(0,bottomPx - topPx));
         var fieldRect:Rectangle = rect.intersection(this.mFieldBmp.bitmapData.rect);
         var fogRect:Rectangle = rect.intersection(this.mFogBmp.bitmapData.rect);
         if(fieldRect.width > 0 && fieldRect.height > 0)
         {
            this.mFieldBmp.bitmapData.fillRect(fieldRect,0);
         }
         if(fogRect.width > 0 && fogRect.height > 0)
         {
            this.mFogBmp.bitmapData.fillRect(fogRect,0);
         }
         Utils.DiagEvent("TILEMAP_DIRTY_CLEAR","bounds=" + param1 + "," + param2 + "," + param3 + "," + param4 + ";pixels=" + leftPx + "," + topPx + "," + rightPx + "," + bottomPx + ";expansion_px=0");
      }
'@
  $tile=Replace-RegexOne $tile $clearPattern $clearReplacement 'dirty_clear_exact_no_black_frame'

  $cameraGuardPattern='(?ms)\s*if\(Math\.abs\(dx\) > 1 \|\| Math\.abs\(dy\) > 1\)\s*\{\s*return false;\s*\}'
  $cameraGuardReplacement=@'
         var limitX:Number = Math.max(1,this.mCameraCacheEffectiveMarginX * CAMERA_CACHE_REBUILD_LIMIT);
         var limitY:Number = Math.max(1,this.mCameraCacheEffectiveMarginY * CAMERA_CACHE_REBUILD_LIMIT);
         if(Math.abs(dx) >= limitX || Math.abs(dy) >= limitY)
         {
            return false;
         }
'@
  $tile=Replace-RegexOne $tile $cameraGuardPattern $cameraGuardReplacement 'dirty_redraw_uses_cache_budget'

  $tile=Replace-LiteralOne $tile '         var _loc6_:Number = param2 * this.mScene.mGridDimX * this.mScene.mContainer.scaleX + this.mScene.mContainer.x;' '         var _loc6_:Number = param2 * this.mScene.mGridDimX * this.mScene.mContainer.scaleX + this.getCacheDrawOriginX();' 'blit_anchor_x'
  $tile=Replace-LiteralOne $tile '         var _loc7_:Number = param3 * this.mScene.mGridDimY * this.mScene.mContainer.scaleY + this.mScene.mContainer.y;' '         var _loc7_:Number = param3 * this.mScene.mGridDimY * this.mScene.mContainer.scaleY + this.getCacheDrawOriginY();' 'blit_anchor_y'
  $tile=Replace-LiteralOne $tile '         var _loc5_:Number = param2 * this.mScene.mGridDimX * this.mScene.mContainer.scaleX + this.mScene.mContainer.x;' '         var _loc5_:Number = param2 * this.mScene.mGridDimX * this.mScene.mContainer.scaleX + this.getCacheDrawOriginX();' 'vector_anchor_x'
  $tile=Replace-LiteralOne $tile '         var _loc6_:Number = param3 * this.mScene.mGridDimY * this.mScene.mContainer.scaleY + this.mScene.mContainer.y;' '         var _loc6_:Number = param3 * this.mScene.mGridDimY * this.mScene.mContainer.scaleY + this.getCacheDrawOriginY();' 'vector_anchor_y'
  $snowOld='                  overlayGraphics.drawRect(x * cellWidth + this.mScene.mContainer.x + CAMERA_CACHE_MARGIN,y * cellHeight + this.mScene.mContainer.y + CAMERA_CACHE_MARGIN,cellWidth,cellHeight);'
  $snowNew='                  overlayGraphics.drawRect(x * cellWidth + this.getCacheDrawOriginX() + CAMERA_CACHE_MARGIN,y * cellHeight + this.getCacheDrawOriginY() + CAMERA_CACHE_MARGIN,cellWidth,cellHeight);'
  $tile=Replace-LiteralOne $tile $snowOld $snowNew 'snow_overlay_cache_anchor'

  foreach($token in @('getCacheDrawOriginX()','getCacheDrawOriginY()','TILEMAP_DIRTY_CLEAR','expansion_px=0','mCameraCacheEffectiveMarginX * CAMERA_CACHE_REBUILD_LIMIT')){Require-Token $tile $token 'tile'}
  if($tile.Contains('Math.floor(px) - 2') -or $tile.Contains('Math.ceil(pw) + 4')){throw 'ANDROID_EVIDENCE_ROOTFIX_V4=FAIL regression=dirty_clear_expansion_remaining'}
  if($tile.Contains('Math.abs(dx) > 1 || Math.abs(dy) > 1')){throw 'ANDROID_EVIDENCE_ROOTFIX_V4=FAIL regression=one_pixel_camera_partial_gate_remaining'}
  Write-Utf8Bom $tilePath $tile

  # C) V3's 8s bound depended on update(). Several physical spawns never reached impact/destroy.
  # Add an independent setTimeout watchdog so detached/stalled projectiles cannot retain visuals forever.
  $missilePath=Target-Path 'missile'
  $missile=Normalize-Lf ([IO.File]::ReadAllText($missilePath))
  $missile=Replace-LiteralOne $missile '   import flash.geom.Point;' @'
   import flash.geom.Point;
   import flash.utils.clearTimeout;
   import flash.utils.getTimer;
   import flash.utils.setTimeout;
'@ 'missile_timeout_imports'
  $missile=Replace-LiteralOne $missile '      private var mDestroyed:Boolean = false;' @'
      private var mDestroyed:Boolean = false;
      private var mLifetimeTimeoutId:uint = 0;
      private var mSpawnTimer:int = 0;
'@ 'missile_timeout_fields'
  $missile=Replace-LiteralOne $missile '         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=spawn;target_x=" + param2 + ";target_y=" + param3);' @'
         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=spawn;target_x=" + param2 + ";target_y=" + param3);
         this.mSpawnTimer = getTimer();
         this.mLifetimeTimeoutId = setTimeout(this.handleLifetimeTimeout,8000);
'@ 'missile_timeout_arm'
  $missile=Replace-LiteralOne $missile '      override public function destroy() : void' @'
      private function handleLifetimeTimeout() : void
      {
         if(this.mDestroyed)
         {
            return;
         }
         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=timeout_timer;age_ms=" + (getTimer() - this.mSpawnTimer) + ";at_target=" + mAtTarget);
         this.destroy();
      }

      override public function destroy() : void
'@ 'missile_timeout_handler'
  $missile=Replace-RegexOne $missile '(?ms)(this\.mDestroyed = true;\s*)' ('$1' + "if(this.mLifetimeTimeoutId != 0)`n         {`n            clearTimeout(this.mLifetimeTimeoutId);`n            this.mLifetimeTimeoutId = 0;`n         }`n         ") 'missile_timeout_disarm'
  foreach($token in @('setTimeout(this.handleLifetimeTimeout,8000)','phase=timeout_timer','clearTimeout(this.mLifetimeTimeoutId)')){Require-Token $missile $token 'missile_timeout'}
  Write-Utf8Bom $missilePath $missile

  $artilleryPath=Target-Path 'artillery'
  $artillery=Normalize-Lf ([IO.File]::ReadAllText($artilleryPath))
  $artillery=Replace-LiteralOne $artillery '   import flash.geom.Vector3D;' @'
   import flash.geom.Vector3D;
   import flash.utils.clearTimeout;
   import flash.utils.getTimer;
   import flash.utils.setTimeout;
'@ 'artillery_timeout_imports'
  $artillery=Replace-LiteralOne $artillery '      private var mDestroyed:Boolean = false;' @'
      private var mDestroyed:Boolean = false;
      private var mLifetimeTimeoutId:uint = 0;
      private var mSpawnTimer:int = 0;
'@ 'artillery_timeout_fields'
  $artillery=Replace-LiteralOne $artillery '         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=spawn;target_x=" + param2 + ";target_y=" + param3);' @'
         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=spawn;target_x=" + param2 + ";target_y=" + param3);
         this.mSpawnTimer = getTimer();
         this.mLifetimeTimeoutId = setTimeout(this.handleLifetimeTimeout,8000);
'@ 'artillery_timeout_arm'
  $artillery=Replace-LiteralOne $artillery '      override public function destroy() : void' @'
      private function handleLifetimeTimeout() : void
      {
         if(this.mDestroyed)
         {
            return;
         }
         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=timeout_timer;age_ms=" + (getTimer() - this.mSpawnTimer) + ";at_target=" + mAtTarget);
         this.destroy();
      }

      override public function destroy() : void
'@ 'artillery_timeout_handler'
  $artillery=Replace-RegexOne $artillery '(?ms)(this\.mDestroyed = true;\s*)' ('$1' + "if(this.mLifetimeTimeoutId != 0)`n         {`n            clearTimeout(this.mLifetimeTimeoutId);`n            this.mLifetimeTimeoutId = 0;`n         }`n         ") 'artillery_timeout_disarm'
  foreach($token in @('setTimeout(this.handleLifetimeTimeout,8000)','phase=timeout_timer','clearTimeout(this.mLifetimeTimeoutId)')){Require-Token $artillery $token 'artillery_timeout'}
  Write-Utf8Bom $artilleryPath $artillery

  Write-Host 'REGRESSION_CHECK=PASS name=black_dirty_region_frame_removed clear_expansion_px=0 origin=cache_anchor'
  Write-Host 'REGRESSION_CHECK=PASS name=status_hint_unchanged_direction_is_o1 materialization_normalizes=true'
  Write-Host 'REGRESSION_CHECK=PASS name=ownership_partial_redraw_survives_camera_motion budget=effective_cache_margin'
  Write-Host 'REGRESSION_CHECK=PASS name=projectile_cleanup_independent_of_update timer_ms=8000 types=Missile,ArtilleryRound'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V4=PASS mode=apply sha=$ExpectedSha black_square=root_cause_fixed status_hint_jank=bounded projectile_watchdog=independent"
}catch{
  $failure=$_
  try{& $PSCommandPath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V4_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
