param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V2=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V2=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$targets=[ordered]@{
  animation='src\game\characters\AnimationController.as'
  tile='src\game\battlefield\TileMapGraphic.as'
  missile='src\game\gameElements\Missile.as'
  artillery='src\game\gameElements\ArtilleryRound.as'
  perfjava='android\native\diagnostics\java\com\valverde\armyattack\diagnostics\PerformanceOverlay.java'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-overlay-v2\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Write-Utf8NoBom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.original')}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V2=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V2_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Require-Token([string]$Text,[string]$Token,[string]$Name){
  if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V2=FAIL verify=$Name token=$Token"}
}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){
    Write-Host "ANDROID_EVIDENCE_ROOTFIX_V2=PASS mode=restore status=no_overlay sha=$ExpectedSha"
    return
  }
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V2=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $key=[string]$entry.key
    $src=Backup-Path $key
    $dst=Target-Path $key
    if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V2=FAIL restore_backup_missing key=$key"}
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $restored=Get-Sha256 $dst
    $expected=([string]$entry.sha256).ToUpperInvariant()
    if($restored -ne $expected){throw "ANDROID_EVIDENCE_ROOTFIX_V2=FAIL restore_hash key=$key expected=$expected actual=$restored"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V2=PASS mode=restore baseline_restored=true composable=true sha=$ExpectedSha"
  return
}

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V2=FAIL source_missing key=$key path=$($targets[$key])"}
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v2';source_sha=$ExpectedSha;files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "EVIDENCE_ROOTFIX_V2_MANIFEST=PASS files=$($manifestFiles.Count) semantic=true powershell51_safe=true"

try{
  # A) HUD orientation. Replace the previous counter-flip implementation as a
  # semantic block, then repair every materialized animation regardless of the
  # formatting/order produced by earlier overlays.
  $animationPath=Target-Path 'animation'
  $animation=Normalize-Lf ([IO.File]::ReadAllText($animationPath))
  Require-Token $animation 'STATUS_HINT_ORIENTATION' 'visual_combat_predecessor'
  $directionPattern='(?ms)\s*private function isStatusHintRoot\(param1:String\)\s*:\s*Boolean.*?\s*public function setSize'
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
  $animation=Replace-RegexOne $animation $directionPattern $directionReplacement 'status_hint_absolute_orientation'

  $materializePattern='(?ms)\s*wrapper\.addChild\(new cls\(\)\);\s*wrapper\.visible\s*=\s*true;\s*(?:(?:smMaterializedClips\+\+;\s*this\.invalidateAnimationTreeCache\(param1\);)|(?:this\.invalidateAnimationTreeCache\(param1\);\s*smMaterializedClips\+\+;))'
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
  $animation=Replace-RegexOne $animation $materializePattern $materializeReplacement 'lazy_materialization_direction_and_hud'
  $ownerReadyPattern='(?ms)(private function notifyOwnerAnimationReady\(\)\s*:\s*void\s*\{\s*)(if\s*\(this\.mOwner is IsometricCharacter\))'
  $ownerReadyReplacement='$1this.refreshStatusHintOrientation();'+"`n         "+'$2'
  $animation=Replace-RegexOne $animation $ownerReadyPattern $ownerReadyReplacement 'owner_ready_hud_normalization'
  foreach($token in @('concatenatedMatrix.a < 0','refreshStatusHintOrientation()','changed=0;normalized=','directionTarget.scaleX = -directionTarget.scaleX')){Require-Token $animation $token 'animation'}
  Write-Utf8Bom $animationPath $animation

  # B) Ownership changes are visually committed in the action frame. Partial
  # redraw stays first choice; an invalid cache falls back to the existing full
  # redraw synchronously rather than leaving a stale/deferred ownership state.
  $tilePath=Target-Path 'tile'
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  if(-not $tile.Contains('import flash.utils.getTimer;')){
    $tile=Replace-RegexOne $tile '(?m)^(\s*)import flash\.utils\.Dictionary;\s*$' ('$1import flash.utils.Dictionary;'+"`n"+'$1import flash.utils.getTimer;') 'tile_gettimer_import'
  }
  $commitPattern='(?ms)\s*public function commitOwnershipVisualNow\(\)\s*:\s*Boolean\s*\{.*?\n\s*\}\s*(?=\n\s*public function updateCameraViewport)'
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
  $tile=Replace-RegexOne $tile $commitPattern $commitReplacement 'ownership_commit_never_deferred'
  if($tile.Contains('"deferred"')){throw 'ANDROID_EVIDENCE_ROOTFIX_V2=FAIL regression=ownership_deferred_remaining'}
  foreach($token in @('this.requestFullRedraw();','this.updateTilemap();','result=" + (committed ? mode : "failed")','elapsed_ms=')){Require-Token $tile $token 'ownership'}
  Write-Utf8Bom $tilePath $tile

  # C) Missile owns all transient visuals and has an absolute lifetime watchdog.
  $missilePath=Target-Path 'missile'
  $missile=Normalize-Lf ([IO.File]::ReadAllText($missilePath))
  Require-Token $missile 'MISSILE_IMPACT_CLEANUP' 'missile_predecessor'
  if($missile.Contains('override public function destroy()')){throw 'ANDROID_EVIDENCE_ROOTFIX_V2=FAIL missile_destroy_already_present'}
  $missile=Replace-RegexOne $missile '(?m)^(\s*)private var mImpactFrameTicks:int = 0;\s*$' ('$1private var mImpactFrameTicks:int = 0;'+"`n"+'$1private var mImpactClip:MovieClip = null;'+"`n"+'$1private var mLifetimeMs:int = 0;'+"`n"+'$1private var mDestroyed:Boolean = false;') 'missile_lifecycle_fields'
  $missile=Replace-RegexOne $missile '(?m)^(\s*)super\(param1,param2,param3\);\s*$' ('$1super(param1,param2,param3);'+"`n"+'$1Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=spawn;target_x=" + param2 + ";target_y=" + param3);') 'missile_spawn'
  $missile=Replace-RegexOne $missile '(?m)^(\s*)if\(!mGraphicsLoaded\s*\|\|\s*!mProjectile\)\s*$' ('$1this.mLifetimeMs += param1;'+"`n"+'$1if(this.mLifetimeMs >= 8000 && !this.mDestroyed)'+"`n"+'$1{'+"`n"+'$1   Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=timeout;age_ms=" + this.mLifetimeMs + ";at_target=" + mAtTarget);'+"`n"+'$1   this.destroy();'+"`n"+'$1   return true;'+"`n"+'$1}'+"`n"+'$1if(!mGraphicsLoaded || !mProjectile)') 'missile_absolute_timeout'
  $missile=Replace-RegexOne $missile '(?ms)(this\.mImpactFrameTicks\s*=\s*0;\s*)(_loc9_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);\s*addChild\(_loc9_\);)' ('$1this.mImpactClip = _loc9_;'+"`n               "+'$2'+"`n               Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=impact;age_ms=" + this.mLifetimeMs + ";children=" + numChildren);') 'missile_impact_ownership'
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

      private function addParticle
'@
  $missile=Replace-RegexOne $missile '(?m)^\s*private function addParticle\s*$' $missileDestroy 'missile_owned_destroy'
  foreach($token in @('PROJECTILE_LIFECYCLE','mSmoker.destroy()','mLifetimeMs >= 8000','override public function destroy()')){Require-Token $missile $token 'missile'}
  Write-Utf8Bom $missilePath $missile

  # D) Artillery follows the same ownership contract and clears its trail.
  $artilleryPath=Target-Path 'artillery'
  $artillery=Normalize-Lf ([IO.File]::ReadAllText($artilleryPath))
  Require-Token $artillery 'ARTILLERY_IMPACT_CLEANUP' 'artillery_predecessor'
  if($artillery.Contains('override public function destroy()')){throw 'ANDROID_EVIDENCE_ROOTFIX_V2=FAIL artillery_destroy_already_present'}
  $artillery=Replace-RegexOne $artillery '(?m)^(\s*)private var mImpactFrameTicks:int = 0;\s*$' ('$1private var mImpactFrameTicks:int = 0;'+"`n"+'$1private var mImpactClip:MovieClip = null;'+"`n"+'$1private var mLifetimeMs:int = 0;'+"`n"+'$1private var mDestroyed:Boolean = false;') 'artillery_lifecycle_fields'
  $artillery=Replace-RegexOne $artillery '(?m)^(\s*)super\(param1,param2,param3\);\s*$' ('$1super(param1,param2,param3);'+"`n"+'$1Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=spawn;target_x=" + param2 + ";target_y=" + param3);') 'artillery_spawn'
  $artillery=Replace-RegexOne $artillery '(?m)^(\s*)if\(!mGraphicsLoaded\s*\|\|\s*mProjectile\s*==\s*null\)\s*$' ('$1this.mLifetimeMs += param1;'+"`n"+'$1if(this.mLifetimeMs >= 8000 && !this.mDestroyed)'+"`n"+'$1{'+"`n"+'$1   Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=timeout;age_ms=" + this.mLifetimeMs + ";at_target=" + mAtTarget);'+"`n"+'$1   this.destroy();'+"`n"+'$1   return true;'+"`n"+'$1}'+"`n"+'$1if(!mGraphicsLoaded || mProjectile == null)') 'artillery_absolute_timeout'
  $artillery=Replace-RegexOne $artillery '(?ms)(this\.mImpactFrameTicks\s*=\s*0;\s*)(_loc3_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);\s*addChild\(_loc3_\);)' ('$1this.mImpactClip = _loc3_;'+"`n               "+'$2'+"`n               Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=impact;age_ms=" + this.mLifetimeMs + ";children=" + numChildren);') 'artillery_impact_ownership'
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

      private function addParticle
'@
  $artillery=Replace-RegexOne $artillery '(?m)^\s*private function addParticle\s*$' $artilleryDestroy 'artillery_owned_destroy'
  foreach($token in @('PROJECTILE_LIFECYCLE','mTrail.length = 0','mLifetimeMs >= 8000','override public function destroy()')){Require-Token $artillery $token 'artillery'}
  Write-Utf8Bom $artilleryPath $artillery

  # E) PERF keeps raw history but gameplay attribution expires after 1.5 s.
  $javaPath=Target-Path 'perfjava'
  $java=Normalize-Lf ([IO.File]::ReadAllText($javaPath))
  Require-Token $java 'LAST_GAMEPLAY_EVENT_ELAPSED_MS' 'perf_predecessor'
  $java=Replace-RegexOne $java '(?m)^(\s*)private static volatile long LAST_GAMEPLAY_EVENT_ELAPSED_MS = -1L;\s*$' ('$1private static volatile long LAST_GAMEPLAY_EVENT_ELAPSED_MS = -1L;'+"`n"+'$1private static final long GAMEPLAY_EVENT_CORRELATION_WINDOW_MS = 1500L;') 'perf_correlation_window'
  $recordPattern='(?ms)\s*private static void recordFrameSpike\(long deltaNs\)\s*\{.*?\n\s*\}\s*(?=\n\s*private static void accumulateJank)'
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
  $java=Replace-RegexOne $java $recordPattern $recordReplacement 'perf_stale_correlation_removed'
  $java=Replace-RegexOne $java '(?m)^(\s*)row\.put\("nearest_game_event_age_ms", spike\.eventAgeMs\);\s*$' ('$1row.put("nearest_game_event_age_ms", spike.eventAgeMs);'+"`n"+'$1row.put("nearest_game_event_within_window", spike.eventAgeMs >= 0L);') 'perf_row_window_flag'
  $java=Replace-RegexOne $java '(?m)^(\s*)summary\.put\("meaningful_event_correlation", true\);\s*$' ('$1summary.put("meaningful_event_correlation", true);'+"`n"+'$1summary.put("correlation_window_ms", GAMEPLAY_EVENT_CORRELATION_WINDOW_MS);') 'perf_summary_window'
  $java=Replace-RegexOne $java '(?m)^(\s*)correlation\.put\("nearest_event_window_note",\s*"nearest_game_event excludes periodic profiler noise; nearest_raw_event preserves the unfiltered stream\."\);\s*$' ('$1correlation.put("nearest_event_window_note", "nearest_game_event excludes periodic profiler noise and is retained only within the bounded gameplay correlation window; nearest_raw_event preserves the unfiltered stream.");'+"`n"+'$1correlation.put("correlation_window_ms", GAMEPLAY_EVENT_CORRELATION_WINDOW_MS);') 'perf_report_window'
  if(-not $java.Contains('kind.startsWith("PROJECTILE_")')){
    $java=Replace-RegexOne $java '(?m)^(\s*)\|\| kind\.startsWith\("FIREMISSION_"\)\s*$' ('$1|| kind.startsWith("FIREMISSION_")'+"`n"+'$1|| kind.startsWith("PROJECTILE_")') 'perf_projectile_logcat'
  }
  foreach($token in @('GAMEPLAY_EVENT_CORRELATION_WINDOW_MS = 1500L','nearest_game_event_within_window','correlation_window_ms','kind.startsWith("PROJECTILE_")')){Require-Token $java $token 'perf'}
  Write-Utf8NoBom $javaPath $java

  # F) Build provenance names the exact composed patch.
  $patcherPath=Target-Path 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patcher=Replace-RegexOne $patcher "(?m)^\s*\$patchVersion='mobile-engine-v3\.24-placement-wrecking-rootfix'\s*$" '$patchVersion=''mobile-engine-v3.25-evidence-rootfix-v2''' 'patch_version_v3_25_v2'
  foreach($required in @('game.characters.AnimationController','game.battlefield.TileMapGraphic','game.gameElements.Missile','game.gameElements.ArtilleryRound','mobile-engine-v3.25-evidence-rootfix-v2')){Require-Token $patcher $required 'patcher'}
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=status_hint_absolute_orientation_v2 semantic=true concatenated_transform=true lazy_materialization=true same_direction_repair=true'
  Write-Host 'REGRESSION_CHECK=PASS name=ownership_visual_commit_v2 partial_first=true full_sync_fallback=true deferred=false'
  Write-Host 'REGRESSION_CHECK=PASS name=missile_lifecycle_v2 owned_visuals=true idempotent_destroy=true smoke_cleanup=true timeout_ms=8000'
  Write-Host 'REGRESSION_CHECK=PASS name=artillery_lifecycle_v2 owned_visuals=true idempotent_destroy=true trail_cleanup=true timeout_ms=8000'
  Write-Host 'REGRESSION_CHECK=PASS name=perf_correlation_v2 window_ms=1500 raw_context=true projectile_logcat=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V2=PASS mode=apply sha=$ExpectedSha schema=v2 swf_patch_version=mobile-engine-v3.25-evidence-rootfix-v2"
}catch{
  $failure=$_
  foreach($key in $targets.Keys){
    $src=Backup-Path $key
    $dst=Target-Path $key
    if(Test-Path -LiteralPath $src -PathType Leaf){Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue}
  throw $failure
}
