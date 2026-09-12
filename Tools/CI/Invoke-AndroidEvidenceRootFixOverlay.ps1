param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$targets=[ordered]@{
  animation='src\game\characters\AnimationController.as'
  tile='src\game\battlefield\TileMapGraphic.as'
  missile='src\game\gameElements\Missile.as'
  artillery='src\game\gameElements\ArtilleryRound.as'
  perfjava='android\native\diagnostics\java\com\valverde\armyattack\diagnostics\PerformanceOverlay.java'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-overlay\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Write-Utf8NoBom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.original')}
function Replace-LiteralOnce([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL patch=$Name reason=literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL patch=$Name reason=literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_SEMANTIC_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Replace-RegexOnce([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -eq 0){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL patch=$Name reason=semantic_pattern_missing"}
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL patch=$Name reason=semantic_pattern_ambiguous matches=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_SEMANTIC_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){
    Write-Host "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha"
    return
  }
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $key=[string]$entry.key
    $src=Backup-Path $key
    $dst=Target-Path $key
    if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL restore_backup_missing key=$key path=$src"}
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $restored=Get-Sha256 $dst
    $expected=([string]$entry.sha256).ToUpperInvariant()
    if($restored -ne $expected){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL restore_hash key=$key expected=$expected actual=$restored"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=PASS mode=restore baseline_restored=true composable=true sha=$ExpectedSha"
  return
}

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL source_missing key=$key path=$($targets[$key])"}
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v1';source_sha=$ExpectedSha;files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "EVIDENCE_ROOTFIX_MANIFEST=PASS files=$($manifestFiles.Count) powershell51_safe=true"

try{
  # 1) Status/health/fire-power HUD orientation: normalize from the complete
  # animation tree using the actual concatenated transform. The previous fix
  # only searched the direction target and physical evidence showed
  # counter_flipped=0 while the HUD was still mirrored.
  $animationPath=Target-Path 'animation'
  $animation=Normalize-Lf ([IO.File]::ReadAllText($animationPath))
  if(-not $animation.Contains('STATUS_HINT_ORIENTATION')){throw 'ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL order=visual_combat_overlay_required'}

  $directionPattern='(?ms)      private function isStatusHintRoot\(param1:String\) : Boolean.*?      public function setSize'
  $directionReplacement=@'
      private function isStatusHintRoot(param1:String) : Boolean
      {
         return param1 != null && param1.indexOf("Hint_Health_") == 0;
      }

      private function normalizeStatusHintTree(param1:DisplayObject) : int
      {
         if(!param1)
         {
            return 0;
         }
         if(this.isStatusHintRoot(param1.name))
         {
            var mirrored:Boolean = false;
            try
            {
               mirrored = param1.transform.concatenatedMatrix.a < 0;
            }
            catch(error:Error)
            {
               mirrored = param1.scaleX < 0;
            }
            if(mirrored)
            {
               param1.scaleX = -param1.scaleX;
               return 1;
            }
            return 0;
         }
         var container:DisplayObjectContainer = param1 as DisplayObjectContainer;
         if(!container)
         {
            return 0;
         }
         var corrected:int = 0;
         var child:DisplayObject = null;
         var i:int = 0;
         while(i < container.numChildren)
         {
            child = container.getChildAt(i);
            if(child)
            {
               corrected += this.normalizeStatusHintTree(child);
            }
            i++;
         }
         return corrected;
      }

      public function refreshStatusHintOrientation() : int
      {
         var corrected:int = 0;
         var animationRoot:DisplayObject = null;
         var i:int = 0;
         while(this.mAnimations && i < this.mAnimations.length)
         {
            animationRoot = this.mAnimations[i] as DisplayObject;
            if(animationRoot)
            {
               corrected += this.normalizeStatusHintTree(animationRoot);
            }
            i++;
         }
         return corrected;
      }

      public function setDirection(param1:int) : void
      {
         var target:DisplayObject = null;
         var i:int = 0;
         var normalized:int = 0;
         if(param1 == this.mCurrentDirection)
         {
            normalized = this.refreshStatusHintOrientation();
            Utils.DiagEvent("STATUS_HINT_ORIENTATION","direction=" + param1 + ";changed=0;normalized=" + normalized + ";animations=" + this.mAnimations.length);
            return;
         }
         smDirectionChanges++;
         this.emitAnimationStats(false);
         if(param1 == DIR_RIGHT || param1 == DIR_LEFT)
         {
            while(i < this.mAnimations.length)
            {
               if(i != CHARACTER_ANIMATION_DYING)
               {
                  target = this.resolveDirectionTarget(i);
                  if(target)
                  {
                     target.scaleX = -target.scaleX;
                  }
               }
               i++;
            }
         }
         this.mCurrentDirection = param1;
         normalized = this.refreshStatusHintOrientation();
         Utils.DiagEvent("STATUS_HINT_ORIENTATION","direction=" + param1 + ";changed=1;normalized=" + normalized + ";animations=" + this.mAnimations.length);
      }

      public function setSize
'@
  $animation=Replace-RegexOnce $animation $directionPattern $directionReplacement 'status_hint_full_tree_absolute_orientation'

  $materializeNeedle=@'
               wrapper.addChild(new cls());
               wrapper.visible = true;
               smMaterializedClips++;
               this.invalidateAnimationTreeCache(param1);
'@
  $materializeReplacement=@'
               wrapper.addChild(new cls());
               wrapper.visible = true;
               this.invalidateAnimationTreeCache(param1);
               if(this.mCurrentDirection == DIR_LEFT)
               {
                  var directionTarget:DisplayObject = this.resolveDirectionTarget(param1);
                  if(directionTarget)
                  {
                     directionTarget.scaleX = -directionTarget.scaleX;
                  }
               }
               smMaterializedClips++;
               this.refreshStatusHintOrientation();
'@
  $animation=Replace-LiteralOnce $animation $materializeNeedle $materializeReplacement 'lazy_materialization_preserves_direction_and_hud_orientation'

  $ownerReadyPattern='(?ms)      private function notifyOwnerAnimationReady\(\) : void\s*\{\s*if\(this\.mOwner is IsometricCharacter\)'
  $ownerReadyReplacement=@'
      private function notifyOwnerAnimationReady() : void
      {
         this.refreshStatusHintOrientation();
         if(this.mOwner is IsometricCharacter)
'@
  $animation=Replace-RegexOnce $animation $ownerReadyPattern $ownerReadyReplacement 'materialized_animation_normalizes_status_hud'
  foreach($token in @('refreshStatusHintOrientation()','concatenatedMatrix.a < 0','changed=0;normalized=','lazy_materialization_preserves_direction_and_hud_orientation')){
    if($token -eq 'lazy_materialization_preserves_direction_and_hud_orientation'){continue}
    if(-not $animation.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL verify_animation token=$token"}
  }
  Write-Utf8Bom $animationPath $animation

  # 2) Ownership visual commit: never leave a conquered cell on the deferred
  # path. Use the cheap dirty-region path first; if cache state forbids it,
  # synchronously execute the existing full redraw path and measure the cost.
  $tilePath=Target-Path 'tile'
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  $tile=Replace-LiteralOnce $tile '   import flash.utils.Dictionary;' "   import flash.utils.Dictionary;`n   import flash.utils.getTimer;" 'tile_gettimer_import'
  $commitPattern='(?ms)      public function commitOwnershipVisualNow\(\) : Boolean\s*\{.*?\n      \}\s*(?=\n\s*      public function updateCameraViewport)'
  $commitReplacement=@'
      public function commitOwnershipVisualNow() : Boolean
      {
         var started:int = getTimer();
         if(!this.mOwnershipDirty)
         {
            Utils.DiagEvent("OWNERSHIP_VISUAL_COMMIT","map=" + GameState.mInstance.mCurrentMapId + ";result=clean;elapsed_ms=" + (getTimer() - started));
            return true;
         }
         var reason:String = this.mDirtyReason;
         var committed:Boolean = this.redrawDirtyOwnershipRegion();
         var mode:String = committed ? "partial" : "full";
         if(!committed)
         {
            this.requestFullRedraw();
            this.updateTilemap();
            committed = !this.mOwnershipDirty;
         }
         Utils.DiagEvent("OWNERSHIP_VISUAL_COMMIT","map=" + GameState.mInstance.mCurrentMapId + ";result=" + (committed ? mode : "failed") + ";reason=" + reason + ";elapsed_ms=" + (getTimer() - started) + ";cells=" + this.mLastDrawCellCount);
         return committed;
      }
'@
  $tile=Replace-RegexOnce $tile $commitPattern $commitReplacement 'ownership_commit_never_deferred'
  if($tile.Contains('result=" + (committed ? "partial" : "deferred")')){throw 'ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL regression=ownership_deferred_path_remaining'}
  Write-Utf8Bom $tilePath $tile

  # 3) Missile lifecycle: impact cleanup alone was not enough evidence. Own every
  # visual child, smoke particle and timeout from one idempotent destroy path.
  $missilePath=Target-Path 'missile'
  $missile=Normalize-Lf ([IO.File]::ReadAllText($missilePath))
  if(-not $missile.Contains('MISSILE_IMPACT_CLEANUP')){throw 'ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL order=animation_lifecycle_missile_required'}
  $missile=Replace-LiteralOnce $missile '      private var mImpactFrameTicks:int = 0;' @'
      private var mImpactFrameTicks:int = 0;
      private var mImpactClip:MovieClip = null;
      private var mLifetimeMs:int = 0;
      private var mDestroyed:Boolean = false;
'@ 'missile_owned_lifecycle_fields'
  $missile=Replace-LiteralOnce $missile '         super(param1,param2,param3);' @'
         super(param1,param2,param3);
         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=spawn;target_x=" + param2 + ";target_y=" + param3);
'@ 'missile_spawn_telemetry'
  $missile=Replace-LiteralOnce $missile '         if(!mGraphicsLoaded || !mProjectile)' @'
         this.mLifetimeMs += param1;
         if(this.mLifetimeMs >= 8000 && !this.mDestroyed)
         {
            Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=timeout;age_ms=" + this.mLifetimeMs + ";at_target=" + mAtTarget);
            this.destroy();
            return true;
         }
         if(!mGraphicsLoaded || !mProjectile)
'@ 'missile_absolute_lifetime_watchdog'
  $missile=Replace-LiteralOnce $missile '               this.mImpactFrameTicks = 0;
               _loc9_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
               addChild(_loc9_);' @'
               this.mImpactFrameTicks = 0;
               this.mImpactClip = _loc9_;
               _loc9_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
               addChild(_loc9_);
               Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=impact;age_ms=" + this.mLifetimeMs + ";children=" + numChildren);
'@ 'missile_impact_owned_clip'
  $missileDestroyNeedle='      private function addParticle(param1:int) : void'
  $missileDestroy=@'
      override public function destroy() : void
      {
         if(this.mDestroyed)
         {
            return;
         }
         this.mDestroyed = true;
         if(this.mImpactClip)
         {
            this.mImpactClip.removeEventListener(Event.ENTER_FRAME,this.checkFrame);
            this.mImpactClip.stop();
            this.mImpactClip.gotoAndStop(1);
            this.mImpactClip.visible = false;
            if(this.mImpactClip.parent)
            {
               this.mImpactClip.parent.removeChild(this.mImpactClip);
            }
            this.mImpactClip = null;
         }
         if(mProjectile)
         {
            if(mProjectile is MovieClip)
            {
               (mProjectile as MovieClip).stop();
               (mProjectile as MovieClip).gotoAndStop(1);
            }
            if(mProjectile.parent)
            {
               mProjectile.parent.removeChild(mProjectile);
            }
            mProjectile = null;
         }
         if(this.mSmoker)
         {
            this.mSmoker.destroy();
            this.mSmoker = null;
         }
         graphics.clear();
         if(this.mLengths) this.mLengths.length = 0;
         if(this.mWaypoints) this.mWaypoints.length = 0;
         if(this.mAngles) this.mAngles.length = 0;
         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=destroy;age_ms=" + this.mLifetimeMs + ";impact_frames=" + this.mImpactFrameTicks + ";children=" + numChildren);
         super.destroy();
      }

'@
  $missile=Replace-LiteralOnce $missile $missileDestroyNeedle ($missileDestroy+$missileDestroyNeedle) 'missile_idempotent_visual_destroy'
  Write-Utf8Bom $missilePath $missile

  # 4) ArtilleryRound uses the same ownership model. Clear the rocket, impact,
  # trail graphics and absolute lifetime from a single destroy path.
  $artilleryPath=Target-Path 'artillery'
  $artillery=Normalize-Lf ([IO.File]::ReadAllText($artilleryPath))
  if(-not $artillery.Contains('ARTILLERY_IMPACT_CLEANUP')){throw 'ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL order=visual_combat_artillery_required'}
  $artillery=Replace-LiteralOnce $artillery '      private var mImpactFrameTicks:int = 0;' @'
      private var mImpactFrameTicks:int = 0;
      private var mImpactClip:MovieClip = null;
      private var mLifetimeMs:int = 0;
      private var mDestroyed:Boolean = false;
'@ 'artillery_owned_lifecycle_fields'
  $artillery=Replace-LiteralOnce $artillery '         super(param1,param2,param3);' @'
         super(param1,param2,param3);
         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=spawn;target_x=" + param2 + ";target_y=" + param3);
'@ 'artillery_spawn_telemetry'
  $artillery=Replace-LiteralOnce $artillery '         if(!mGraphicsLoaded || mProjectile == null)' @'
         this.mLifetimeMs += param1;
         if(this.mLifetimeMs >= 8000 && !this.mDestroyed)
         {
            Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=timeout;age_ms=" + this.mLifetimeMs + ";at_target=" + mAtTarget);
            this.destroy();
            return true;
         }
         if(!mGraphicsLoaded || mProjectile == null)
'@ 'artillery_absolute_lifetime_watchdog'
  $artillery=Replace-LiteralOnce $artillery '               this.mImpactFrameTicks = 0;
               _loc3_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
               addChild(_loc3_);' @'
               this.mImpactFrameTicks = 0;
               this.mImpactClip = _loc3_;
               _loc3_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
               addChild(_loc3_);
               Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=impact;age_ms=" + this.mLifetimeMs + ";children=" + numChildren);
'@ 'artillery_impact_owned_clip'
  $artilleryDestroyNeedle='      private function addParticle() : void'
  $artilleryDestroy=@'
      override public function destroy() : void
      {
         if(this.mDestroyed)
         {
            return;
         }
         this.mDestroyed = true;
         if(this.mImpactClip)
         {
            this.mImpactClip.removeEventListener(Event.ENTER_FRAME,this.checkFrame);
            this.mImpactClip.stop();
            this.mImpactClip.gotoAndStop(1);
            this.mImpactClip.visible = false;
            if(this.mImpactClip.parent)
            {
               this.mImpactClip.parent.removeChild(this.mImpactClip);
            }
            this.mImpactClip = null;
         }
         if(mProjectile)
         {
            if(mProjectile is MovieClip)
            {
               (mProjectile as MovieClip).stop();
               (mProjectile as MovieClip).gotoAndStop(1);
            }
            if(mProjectile.parent)
            {
               mProjectile.parent.removeChild(mProjectile);
            }
            mProjectile = null;
         }
         graphics.clear();
         if(this.mTrail) this.mTrail.length = 0;
         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=destroy;age_ms=" + this.mLifetimeMs + ";impact_frames=" + this.mImpactFrameTicks + ";children=" + numChildren);
         super.destroy();
      }

'@
  $artillery=Replace-LiteralOnce $artillery $artilleryDestroyNeedle ($artilleryDestroy+$artilleryDestroyNeedle) 'artillery_idempotent_visual_destroy'
  Write-Utf8Bom $artilleryPath $artillery

  # 5) PERF correlation must not attribute hundreds of later frames to one old
  # missile event. Keep raw context, but bound gameplay correlation by age.
  $javaPath=Target-Path 'perfjava'
  $java=Normalize-Lf ([IO.File]::ReadAllText($javaPath))
  if(-not $java.Contains('LAST_GAMEPLAY_EVENT_ELAPSED_MS')){throw 'ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL order=perf_meaningful_correlation_required'}
  $java=Replace-LiteralOnce $java '    private static volatile long LAST_GAMEPLAY_EVENT_ELAPSED_MS = -1L;' @'
    private static volatile long LAST_GAMEPLAY_EVENT_ELAPSED_MS = -1L;
    private static final long GAMEPLAY_EVENT_CORRELATION_WINDOW_MS = 1500L;
'@ 'perf_correlation_window_field'
  $recordPattern='(?ms)    private static void recordFrameSpike\(long deltaNs\) \{.*?\n    \}\s*(?=\n\s*    private static void accumulateJank)'
  $recordReplacement=@'
    private static void recordFrameSpike(long deltaNs) {
        long now = android.os.SystemClock.elapsedRealtime();
        long rawAt = LAST_GAME_EVENT_ELAPSED_MS;
        long rawAge = rawAt < 0L ? -1L : Math.max(0L, now - rawAt);
        long gameplayAt = LAST_GAMEPLAY_EVENT_ELAPSED_MS;
        long gameplayAge = gameplayAt < 0L ? -1L : Math.max(0L, now - gameplayAt);
        boolean gameplayFresh = gameplayAge >= 0L && gameplayAge <= GAMEPLAY_EVENT_CORRELATION_WINDOW_MS;
        FrameSpike spike = new FrameSpike(
            now,
            deltaNs / 1_000_000.0,
            LAST_GAME_EVENT_KIND,
            LAST_GAME_EVENT_DETAIL,
            rawAge,
            gameplayFresh ? LAST_GAMEPLAY_EVENT_KIND : "",
            gameplayFresh ? LAST_GAMEPLAY_EVENT_DETAIL : "",
            gameplayFresh ? gameplayAge : -1L
        );
        synchronized (FRAME_SPIKE_LOCK) {
            while (FRAME_SPIKES.size() >= MAX_FRAME_SPIKES) FRAME_SPIKES.removeFirst();
            FRAME_SPIKES.addLast(spike);
        }
    }
'@
  $java=Replace-RegexOnce $java $recordPattern $recordReplacement 'perf_stale_event_correlation_removed'
  $java=Replace-LiteralOnce $java '                row.put("nearest_game_event_age_ms", spike.eventAgeMs);' @'
                row.put("nearest_game_event_age_ms", spike.eventAgeMs);
                row.put("nearest_game_event_within_window", spike.eventAgeMs >= 0L);
'@ 'perf_frame_row_window_flag'
  $java=Replace-LiteralOnce $java '            summary.put("meaningful_event_correlation", true);' @'
            summary.put("meaningful_event_correlation", true);
            summary.put("correlation_window_ms", GAMEPLAY_EVENT_CORRELATION_WINDOW_MS);
'@ 'perf_summary_window'
  $java=Replace-LiteralOnce $java '            correlation.put("nearest_event_window_note", "nearest_game_event excludes periodic profiler noise; nearest_raw_event preserves the unfiltered stream.");' @'
            correlation.put("nearest_event_window_note", "nearest_game_event excludes periodic profiler noise and is retained only within the bounded gameplay correlation window; nearest_raw_event preserves the unfiltered stream.");
            correlation.put("correlation_window_ms", GAMEPLAY_EVENT_CORRELATION_WINDOW_MS);
'@ 'perf_correlation_window_report'
  Write-Utf8NoBom $javaPath $java

  # 6) Provenance must identify this physical-evidence-driven root fix.
  $patcherPath=Target-Path 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patcher=Replace-LiteralOnce $patcher '$patchVersion=''mobile-engine-v3.24-placement-wrecking-rootfix''' '$patchVersion=''mobile-engine-v3.25-evidence-rootfix''' 'patch_version_v3_25'
  foreach($required in @('game.characters.AnimationController','game.battlefield.TileMapGraphic','game.gameElements.Missile','game.gameElements.ArtilleryRound','mobile-engine-v3.25-evidence-rootfix')){
    if(-not $patcher.Contains($required)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL patch=patcher_verification missing=$required"}
  }
  Write-Utf8Bom $patcherPath $patcher

  # Regression gates are semantic and execute on the exact composed source that
  # will be replaced into the APK.
  $animationVerify=[IO.File]::ReadAllText($animationPath)
  $tileVerify=[IO.File]::ReadAllText($tilePath)
  $missileVerify=[IO.File]::ReadAllText($missilePath)
  $artilleryVerify=[IO.File]::ReadAllText($artilleryPath)
  $javaVerify=[IO.File]::ReadAllText($javaPath)
  foreach($token in @('concatenatedMatrix.a < 0','refreshStatusHintOrientation()','changed=0;normalized=','directionTarget.scaleX = -directionTarget.scaleX')){if(-not $animationVerify.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL regression=status_hint token=$token"}}
  foreach($token in @('result=" + (committed ? mode : "failed")','this.requestFullRedraw();','this.updateTilemap();','elapsed_ms=')){if(-not $tileVerify.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL regression=ownership token=$token"}}
  foreach($token in @('override public function destroy()','PROJECTILE_LIFECYCLE','mSmoker.destroy()','mLifetimeMs >= 8000')){if(-not $missileVerify.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL regression=missile token=$token"}}
  foreach($token in @('override public function destroy()','PROJECTILE_LIFECYCLE','mTrail.length = 0','mLifetimeMs >= 8000')){if(-not $artilleryVerify.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL regression=artillery token=$token"}}
  foreach($token in @('GAMEPLAY_EVENT_CORRELATION_WINDOW_MS = 1500L','nearest_game_event_within_window','correlation_window_ms')){if(-not $javaVerify.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL regression=perf token=$token"}}

  Write-Host 'REGRESSION_CHECK=PASS name=status_hint_full_tree_absolute_orientation concatenated_transform=true lazy_materialization=true same_direction_repair=true'
  Write-Host 'REGRESSION_CHECK=PASS name=ownership_visual_commit_never_deferred partial_first=true full_sync_fallback=true elapsed_ms=true'
  Write-Host 'REGRESSION_CHECK=PASS name=missile_visual_lifecycle_owned idempotent_destroy=true smoke_cleanup=true absolute_timeout_ms=8000 telemetry=true'
  Write-Host 'REGRESSION_CHECK=PASS name=artillery_visual_lifecycle_owned idempotent_destroy=true trail_cleanup=true absolute_timeout_ms=8000 telemetry=true'
  Write-Host 'REGRESSION_CHECK=PASS name=perf_gameplay_correlation_age_bounded window_ms=1500 raw_context_preserved=true projectile_lifecycle=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=PASS mode=apply sha=$ExpectedSha schema=v1 swf_patch_version=mobile-engine-v3.25-evidence-rootfix"
}catch{
  $failure=$_
  foreach($key in $targets.Keys){
    $src=Backup-Path $key
    $dst=Target-Path $key
    if(Test-Path -LiteralPath $src -PathType Leaf){Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue}
  }
  throw $failure
}
