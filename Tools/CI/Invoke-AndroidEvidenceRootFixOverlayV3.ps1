param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V3=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V3=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$targets=[ordered]@{
  animation='src\game\characters\AnimationController.as'
  tile='src\game\battlefield\TileMapGraphic.as'
  missile='src\game\gameElements\Missile.as'
  artillery='src\game\gameElements\ArtilleryRound.as'
  perfjava='android\native\diagnostics\java\com\valverde\armyattack\diagnostics\PerformanceOverlay.java'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v3\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Write-Utf8NoBom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.original')}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V3=FAIL verify=$Name token=$Token"}}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V3=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V3_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V3=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V3=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V3_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){
    Write-Host "ANDROID_EVIDENCE_ROOTFIX_V3=PASS mode=restore status=no_overlay sha=$ExpectedSha"
    return
  }
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V3=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $key=[string]$entry.key
    $src=Backup-Path $key
    $dst=Target-Path $key
    if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V3=FAIL restore_backup_missing key=$key"}
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $restored=Get-Sha256 $dst
    $expected=([string]$entry.sha256).ToUpperInvariant()
    if($restored -ne $expected){throw "ANDROID_EVIDENCE_ROOTFIX_V3=FAIL restore_hash key=$key expected=$expected actual=$restored"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V3=PASS mode=restore baseline_restored=true composable=true sha=$ExpectedSha"
  return
}

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V3=FAIL source_missing key=$key path=$($targets[$key])"}
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v3';source_sha=$ExpectedSha;files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "EVIDENCE_ROOTFIX_V3_MANIFEST=PASS files=$($manifestFiles.Count) static=true semantic=true"

try{
  # 1. Health / fire-power status HUD must stay upright independently of unit facing.
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
  $ownerReadyReplacement=@'
$1this.refreshStatusHintOrientation();
         $2
'@
  $animation=Replace-RegexOne $animation $ownerReadyPattern $ownerReadyReplacement 'owner_ready_hud_normalization'
  foreach($token in @('concatenatedMatrix.a < 0','refreshStatusHintOrientation()','changed=0;normalized=','directionTarget.scaleX = -directionTarget.scaleX')){Require-Token $animation $token 'animation'}
  Write-Utf8Bom $animationPath $animation

  # 2. Ownership visual state is committed in the same action frame.
  $tilePath=Target-Path 'tile'
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  if(-not $tile.Contains('import flash.utils.getTimer;')){
    $tileImportPattern='(?m)^(\s*)import flash\.utils\.Dictionary;\s*$'
    $tileImportReplacement=@'
$1import flash.utils.Dictionary;
$1import flash.utils.getTimer;
'@
    $tile=Replace-RegexOne $tile $tileImportPattern $tileImportReplacement 'tile_gettimer_import'
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
  if($tile.Contains('result=" + (committed ? "partial" : "deferred")')){throw 'ANDROID_EVIDENCE_ROOTFIX_V3=FAIL regression=ownership_deferred_remaining'}
  foreach($token in @('this.requestFullRedraw();','this.updateTilemap();','result=" + (committed ? mode : "failed")','elapsed_ms=')){Require-Token $tile $token 'ownership'}
  Write-Utf8Bom $tilePath $tile

  # 3. Missile owns all transient visual state and can never live indefinitely.
  $missilePath=Target-Path 'missile'
  $missile=Normalize-Lf ([IO.File]::ReadAllText($missilePath))
  Require-Token $missile 'MISSILE_IMPACT_CLEANUP' 'missile_predecessor'
  $missileFieldPattern='(?m)^\s*private var mImpactFrameTicks:int = 0;\s*$'
  $missileFieldReplacement=@'
      private var mImpactFrameTicks:int = 0;
      private var mImpactClip:MovieClip = null;
      private var mLifetimeMs:int = 0;
      private var mDestroyed:Boolean = false;
'@
  $missile=Replace-RegexOne $missile $missileFieldPattern $missileFieldReplacement 'missile_lifecycle_fields'
  $missileCtorPattern='(?m)^\s*super\(param1,param2,param3\);\s*$'
  $missileCtorReplacement=@'
         super(param1,param2,param3);
         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=spawn;target_x=" + param2 + ";target_y=" + param3);
'@
  $missile=Replace-RegexOne $missile $missileCtorPattern $missileCtorReplacement 'missile_spawn'
  $missileUpdatePattern='(?m)^\s*if\(!mGraphicsLoaded\s*\|\|\s*!mProjectile\)\s*$'
  $missileUpdateReplacement=@'
         this.mLifetimeMs += param1;
         if(this.mLifetimeMs >= 8000 && !this.mDestroyed)
         {
            Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=timeout;age_ms=" + this.mLifetimeMs + ";at_target=" + mAtTarget);
            this.destroy();
            return true;
         }
         if(!mGraphicsLoaded || !mProjectile)
'@
  $missile=Replace-RegexOne $missile $missileUpdatePattern $missileUpdateReplacement 'missile_absolute_timeout'
  $missileImpactPattern='(?ms)(this\.mImpactFrameTicks\s*=\s*0;\s*)(_loc9_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);\s*addChild\(_loc9_\);)'
  $missileImpactReplacement=@'
$1this.mImpactClip = _loc9_;
               $2
               Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=Missile;phase=impact;age_ms=" + this.mLifetimeMs + ";children=" + numChildren);
'@
  $missile=Replace-RegexOne $missile $missileImpactPattern $missileImpactReplacement 'missile_impact_ownership'
  $missileDestroyPattern='(?m)^\s*private function addParticle\(param1:int\)\s*:\s*void\s*$'
  $missileDestroyReplacement=@'
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

      private function addParticle(param1:int) : void
'@
  $missile=Replace-RegexOne $missile $missileDestroyPattern $missileDestroyReplacement 'missile_owned_destroy'
  foreach($token in @('PROJECTILE_LIFECYCLE','mSmoker.destroy()','mLifetimeMs >= 8000','override public function destroy()')){Require-Token $missile $token 'missile'}
  Write-Utf8Bom $missilePath $missile

  # 4. Artillery owns impact, projectile and trail state with the same bound.
  $artilleryPath=Target-Path 'artillery'
  $artillery=Normalize-Lf ([IO.File]::ReadAllText($artilleryPath))
  Require-Token $artillery 'ARTILLERY_IMPACT_CLEANUP' 'artillery_predecessor'
  $artilleryFieldPattern='(?m)^\s*private var mImpactFrameTicks:int = 0;\s*$'
  $artilleryFieldReplacement=@'
      private var mImpactFrameTicks:int = 0;
      private var mImpactClip:MovieClip = null;
      private var mLifetimeMs:int = 0;
      private var mDestroyed:Boolean = false;
'@
  $artillery=Replace-RegexOne $artillery $artilleryFieldPattern $artilleryFieldReplacement 'artillery_lifecycle_fields'
  $artilleryCtorPattern='(?m)^\s*super\(param1,param2,param3\);\s*$'
  $artilleryCtorReplacement=@'
         super(param1,param2,param3);
         Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=spawn;target_x=" + param2 + ";target_y=" + param3);
'@
  $artillery=Replace-RegexOne $artillery $artilleryCtorPattern $artilleryCtorReplacement 'artillery_spawn'
  $artilleryUpdatePattern='(?m)^\s*if\(!mGraphicsLoaded\s*\|\|\s*mProjectile\s*==\s*null\)\s*$'
  $artilleryUpdateReplacement=@'
         this.mLifetimeMs += param1;
         if(this.mLifetimeMs >= 8000 && !this.mDestroyed)
         {
            Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=timeout;age_ms=" + this.mLifetimeMs + ";at_target=" + mAtTarget);
            this.destroy();
            return true;
         }
         if(!mGraphicsLoaded || mProjectile == null)
'@
  $artillery=Replace-RegexOne $artillery $artilleryUpdatePattern $artilleryUpdateReplacement 'artillery_absolute_timeout'
  $artilleryImpactPattern='(?ms)(this\.mImpactFrameTicks\s*=\s*0;\s*)(_loc3_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);\s*addChild\(_loc3_\);)'
  $artilleryImpactReplacement=@'
$1this.mImpactClip = _loc3_;
               $2
               Utils.DiagEvent("PROJECTILE_LIFECYCLE","type=ArtilleryRound;phase=impact;age_ms=" + this.mLifetimeMs + ";children=" + numChildren);
'@
  $artillery=Replace-RegexOne $artillery $artilleryImpactPattern $artilleryImpactReplacement 'artillery_impact_ownership'
  $artilleryDestroyPattern='(?m)^\s*private function addParticle\(\)\s*:\s*void\s*$'
  $artilleryDestroyReplacement=@'
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

      private function addParticle() : void
'@
  $artillery=Replace-RegexOne $artillery $artilleryDestroyPattern $artilleryDestroyReplacement 'artillery_owned_destroy'
  foreach($token in @('PROJECTILE_LIFECYCLE','mTrail.length = 0','mLifetimeMs >= 8000','override public function destroy()')){Require-Token $artillery $token 'artillery'}
  Write-Utf8Bom $artilleryPath $artillery

  # 5. Jank attribution expires after 1.5 s; raw event history stays intact.
  $javaPath=Target-Path 'perfjava'
  $java=Normalize-Lf ([IO.File]::ReadAllText($javaPath))
  Require-Token $java 'LAST_GAMEPLAY_EVENT_ELAPSED_MS' 'perf_predecessor'
  $perfFieldPattern='(?m)^\s*private static volatile long LAST_GAMEPLAY_EVENT_ELAPSED_MS = -1L;\s*$'
  $perfFieldReplacement=@'
    private static volatile long LAST_GAMEPLAY_EVENT_ELAPSED_MS = -1L;
    private static final long GAMEPLAY_EVENT_CORRELATION_WINDOW_MS = 1500L;
'@
  $java=Replace-RegexOne $java $perfFieldPattern $perfFieldReplacement 'perf_correlation_window'
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
  $rowPattern='(?m)^(\s*)row\.put\("nearest_game_event_age_ms", spike\.eventAgeMs\);\s*$'
  $rowReplacement=@'
$1row.put("nearest_game_event_age_ms", spike.eventAgeMs);
$1row.put("nearest_game_event_within_window", spike.eventAgeMs >= 0L);
'@
  $java=Replace-RegexOne $java $rowPattern $rowReplacement 'perf_row_window_flag'
  $summaryPattern='(?m)^(\s*)summary\.put\("meaningful_event_correlation", true\);\s*$'
  $summaryReplacement=@'
$1summary.put("meaningful_event_correlation", true);
$1summary.put("correlation_window_ms", GAMEPLAY_EVENT_CORRELATION_WINDOW_MS);
'@
  $java=Replace-RegexOne $java $summaryPattern $summaryReplacement 'perf_summary_window'
  $notePattern='(?m)^(\s*)correlation\.put\("nearest_event_window_note",\s*"nearest_game_event excludes periodic profiler noise; nearest_raw_event preserves the unfiltered stream\."\);\s*$'
  $noteReplacement=@'
$1correlation.put("nearest_event_window_note", "nearest_game_event excludes periodic profiler noise and is retained only within the bounded gameplay correlation window; nearest_raw_event preserves the unfiltered stream.");
$1correlation.put("correlation_window_ms", GAMEPLAY_EVENT_CORRELATION_WINDOW_MS);
'@
  $java=Replace-RegexOne $java $notePattern $noteReplacement 'perf_report_window'
  if(-not $java.Contains('kind.startsWith("PROJECTILE_")')){
    $projectilePattern='(?m)^(\s*)\|\| kind\.startsWith\("FIREMISSION_"\)\s*$'
    $projectileReplacement=@'
$1|| kind.startsWith("FIREMISSION_")
$1|| kind.startsWith("PROJECTILE_")
'@
    $java=Replace-RegexOne $java $projectilePattern $projectileReplacement 'perf_projectile_logcat'
  }
  foreach($token in @('GAMEPLAY_EVENT_CORRELATION_WINDOW_MS = 1500L','nearest_game_event_within_window','correlation_window_ms','kind.startsWith("PROJECTILE_")')){Require-Token $java $token 'perf'}
  Write-Utf8NoBom $javaPath $java

  # 6. Exact provenance for the composed SWF patch.
  $patcherPath=Target-Path 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $oldPatch=@'
$patchVersion='mobile-engine-v3.24-placement-wrecking-rootfix'
'@
  $newPatch=@'
$patchVersion='mobile-engine-v3.25-evidence-rootfix-v3'
'@
  $patcher=Replace-LiteralOne $patcher $oldPatch $newPatch 'patch_version_v3_25_v3'
  foreach($required in @('game.characters.AnimationController','game.battlefield.TileMapGraphic','game.gameElements.Missile','game.gameElements.ArtilleryRound','mobile-engine-v3.25-evidence-rootfix-v3')){Require-Token $patcher $required 'patcher'}
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=status_hint_absolute_orientation_v3 concatenated_transform=true lazy_materialization=true same_direction_repair=true'
  Write-Host 'REGRESSION_CHECK=PASS name=ownership_visual_commit_v3 partial_first=true full_sync_fallback=true deferred=false'
  Write-Host 'REGRESSION_CHECK=PASS name=missile_lifecycle_v3 idempotent_destroy=true smoke_cleanup=true timeout_ms=8000 telemetry=true'
  Write-Host 'REGRESSION_CHECK=PASS name=artillery_lifecycle_v3 idempotent_destroy=true trail_cleanup=true timeout_ms=8000 telemetry=true'
  Write-Host 'REGRESSION_CHECK=PASS name=perf_correlation_v3 window_ms=1500 raw_context=true projectile_logcat=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V3=PASS mode=apply sha=$ExpectedSha schema=v3 swf_patch_version=mobile-engine-v3.25-evidence-rootfix-v3"
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
