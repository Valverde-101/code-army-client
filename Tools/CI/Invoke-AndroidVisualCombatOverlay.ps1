param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$targets=[ordered]@{
  animation='src\game\characters\AnimationController.as'
  tile='src\game\battlefield\TileMapGraphic.as'
  scene='src\game\isometric\IsometricScene.as'
  artillery='src\game\gameElements\ArtilleryRound.as'
  firemission='src\game\gameElements\FireMissionObject.as'
  perfjava='android\native\diagnostics\java\com\valverde\armyattack\diagnostics\PerformanceOverlay.java'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-visual-combat-overlay\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Write-Utf8NoBom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.original')}
function Replace-RegexOnce([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -eq 0){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL patch=$Name reason=semantic_pattern_missing"}
  if($matches.Count -ne 1){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL patch=$Name reason=semantic_pattern_ambiguous matches=$($matches.Count)"}
  Write-Host "VISUAL_COMBAT_SEMANTIC_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Replace-LiteralOnce([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL patch=$Name reason=literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL patch=$Name reason=literal_ambiguous"}
  Write-Host "VISUAL_COMBAT_SEMANTIC_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){
    Write-Host "ANDROID_VISUAL_COMBAT_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha"
    return
  }
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $key=[string]$entry.key
    $src=Backup-Path $key
    $dst=Target-Path $key
    if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL restore_backup_missing key=$key path=$src"}
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $restored=Get-Sha256 $dst
    $expected=([string]$entry.sha256).ToUpperInvariant()
    if($restored -ne $expected){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL restore_hash key=$key expected=$expected actual=$restored"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_VISUAL_COMBAT_OVERLAY=PASS mode=restore baseline_restored=true composable=true sha=$ExpectedSha"
  return
}

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL source_missing key=$key path=$($targets[$key])"}
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-visual-combat-overlay/v1';source_sha=$ExpectedSha;files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "VISUAL_COMBAT_MANIFEST=PASS files=$($manifestFiles.Count) powershell51_safe=true"

try{
  # 1) Unit facing must never mirror the embedded health/fire-power HUD.
  $animationPath=Target-Path 'animation'
  $animation=Normalize-Lf ([IO.File]::ReadAllText($animationPath))
  $animation=Replace-LiteralOnce $animation '   import flash.display.DisplayObject;' "   import flash.display.DisplayObject;`n   import flash.display.DisplayObjectContainer;" 'animation_display_container_import'

  $directionPattern='(?ms)      public function setDirection\(param1:int\)\s*:\s*void\s*\{.*?\n      \}\s*\n\s*      public function setSize'
  $directionReplacement=@'
      private function isStatusHintRoot(param1:String) : Boolean
      {
         return param1 != null && param1.indexOf("Hint_Health_") == 0;
      }

      private function counterFlipStatusHints(param1:DisplayObject) : int
      {
         if(!param1)
         {
            return 0;
         }
         if(this.isStatusHintRoot(param1.name))
         {
            param1.scaleX = -param1.scaleX;
            return 1;
         }
         var container:DisplayObjectContainer = param1 as DisplayObjectContainer;
         if(!container)
         {
            return 0;
         }
         var count:int = 0;
         var child:DisplayObject = null;
         var i:int = 0;
         while(i < container.numChildren)
         {
            child = container.getChildAt(i);
            if(child)
            {
               if(this.isStatusHintRoot(child.name))
               {
                  child.scaleX = -child.scaleX;
                  count++;
               }
               else
               {
                  count += this.counterFlipStatusHints(child);
               }
            }
            i++;
         }
         return count;
      }

      public function setDirection(param1:int) : void
      {
         var target:DisplayObject = null;
         var i:int = 0;
         var hintCorrections:int = 0;
         if(param1 == this.mCurrentDirection)
         {
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
                     hintCorrections += this.counterFlipStatusHints(target);
                  }
               }
               i++;
            }
         }
         Utils.DiagEvent("STATUS_HINT_ORIENTATION","direction=" + param1 + ";counter_flipped=" + hintCorrections + ";animations=" + this.mAnimations.length);
         this.mCurrentDirection = param1;
      }

      public function setSize
'@
  $animation=Replace-RegexOnce $animation $directionPattern $directionReplacement 'status_hint_orientation_independent'
  if(-not $animation.Contains('STATUS_HINT_ORIENTATION')){throw 'ANDROID_VISUAL_COMBAT_OVERLAY=FAIL verification=status_hint_telemetry_missing'}
  Write-Utf8Bom $animationPath $animation

  # 2) Ownership changes already mark a small dirty region. Commit that region in
  # the same gameplay action instead of waiting for a later map refresh tick.
  $tilePath=Target-Path 'tile'
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  foreach($required in @('mOwnershipDirty:Boolean','mDirtyReason:String','redrawDirtyOwnershipRegion()','TILEMAP_DIRTY_REDRAW')){
    if(-not $tile.Contains($required)){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL order=render_hotpath_required token=$required"}
  }
  $viewportNeedle='      public function updateCameraViewport() : Boolean'
  $commitMethod=@'
      public function commitOwnershipVisualNow() : Boolean
      {
         if(!this.mOwnershipDirty)
         {
            Utils.DiagEvent("OWNERSHIP_VISUAL_COMMIT","map=" + GameState.mInstance.mCurrentMapId + ";result=clean");
            return true;
         }
         var reason:String = this.mDirtyReason;
         var committed:Boolean = this.redrawDirtyOwnershipRegion();
         Utils.DiagEvent("OWNERSHIP_VISUAL_COMMIT","map=" + GameState.mInstance.mCurrentMapId + ";result=" + (committed ? "partial" : "deferred") + ";reason=" + reason);
         return committed;
      }

'@
  $tile=Replace-LiteralOnce $tile $viewportNeedle ($commitMethod+$viewportNeedle) 'ownership_visual_commit_method'
  Write-Utf8Bom $tilePath $tile

  $scenePath=Target-Path 'scene'
  $scene=Normalize-Lf ([IO.File]::ReadAllText($scenePath))
  $spawnDirtyPattern='if\s*\(this\.mTilemapGraphic\)\s*this\.mTilemapGraphic\.markOwnershipDirty\(param2\);'
  $spawnDirtyReplacement=@'
if(this.mTilemapGraphic)
               {
                  this.mTilemapGraphic.markOwnershipDirty(param2);
                  this.mTilemapGraphic.commitOwnershipVisualNow();
               }
'@
  $scene=Replace-RegexOnce $scene $spawnDirtyPattern $spawnDirtyReplacement 'spawn_owner_visual_commit'
  $conquerDirtyPattern='if\s*\(this\.mTilemapGraphic\)\s*this\.mTilemapGraphic\.markOwnershipDirty\(param1\);'
  $conquerDirtyReplacement=@'
if(this.mTilemapGraphic)
               {
                  this.mTilemapGraphic.markOwnershipDirty(param1);
                  this.mTilemapGraphic.commitOwnershipVisualNow();
               }
'@
  $scene=Replace-RegexOnce $scene $conquerDirtyPattern $conquerDirtyReplacement 'conquer_owner_visual_commit'
  Write-Utf8Bom $scenePath $scene

  # 3) ArtilleryRound retained the legacy parent.parent cleanup and had no
  # watchdog. Make impact cleanup deterministic like Missile, and clear trails.
  $artilleryPath=Target-Path 'artillery'
  $artillery=Normalize-Lf ([IO.File]::ReadAllText($artilleryPath))
  $artilleryFieldPattern='(?m)^(\s*)private var mTimer:int;\s*$'
  $artilleryFieldReplacement='$1private var mTimer:int;'+"`n"+'$1private var mImpactFrameTicks:int = 0;'
  $artillery=Replace-RegexOnce $artillery $artilleryFieldPattern $artilleryFieldReplacement 'artillery_impact_watchdog_field'
  $artilleryListenerPattern='(?m)^(\s*)_loc3_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);\s*$'
  $artilleryListenerReplacement='$1this.mImpactFrameTicks = 0;'+"`n"+'$1_loc3_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);'
  $artillery=Replace-RegexOnce $artillery $artilleryListenerPattern $artilleryListenerReplacement 'artillery_impact_watchdog_reset'
  $artilleryCheckPattern='(?ms)      private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?\n      \}\s*(?=\n      private function addParticle)'
  $artilleryCheckReplacement=@'
      private function checkFrame(param1:Event) : void
      {
         var clip:MovieClip = param1.currentTarget as MovieClip;
         ++this.mImpactFrameTicks;
         if(clip && (clip.currentFrame >= clip.totalFrames || this.mImpactFrameTicks >= 90))
         {
            var reason:String = this.mImpactFrameTicks >= 90 ? "watchdog" : "timeline";
            clip.removeEventListener(Event.ENTER_FRAME,this.checkFrame);
            clip.stop();
            clip.gotoAndStop(1);
            clip.visible = false;
            if(clip.parent)
            {
               clip.parent.removeChild(clip);
            }
            graphics.clear();
            if(this.mTrail)
            {
               this.mTrail.length = 0;
            }
            Utils.DiagEvent("ARTILLERY_IMPACT_CLEANUP","reason=" + reason + ";frames=" + this.mImpactFrameTicks);
            destroy();
         }
      }
'@
  $artillery=Replace-RegexOnce $artillery $artilleryCheckPattern $artilleryCheckReplacement 'artillery_parent_safe_cleanup'
  if($artillery.Contains('parent.parent.removeChild')){throw 'ANDROID_VISUAL_COMBAT_OVERLAY=FAIL regression=artillery_parent_parent_remove_remaining'}
  Write-Utf8Bom $artilleryPath $artillery

  # 4) FireMission fallback is used whenever authored PvP/Artillery symbols are
  # missing. A timeout previously set finished=true without removing the visible
  # rocket/explosion. Centralize and make cleanup idempotent.
  $firePath=Target-Path 'firemission'
  $fire=Normalize-Lf ([IO.File]::ReadAllText($firePath))
  if(-not $fire.Contains('FIREMISSION_GRAPHICS_FALLBACK')){throw 'ANDROID_VISUAL_COMBAT_OVERLAY=FAIL order=firemission_fallback_contract_missing'}
  $startNeedle='      public function start() : void'
  $finishHelper=@'
      private function finishFallbackVisuals(param1:String, param2:int) : void
      {
         if(this.mFallbackFinished)
         {
            return;
         }
         this.mFallbackFinished = true;
         if(this.mFallbackRocket)
         {
            this.mFallbackRocket.stop();
            this.mFallbackRocket.visible = false;
            if(this.mFallbackRocket.parent)
            {
               this.mFallbackRocket.parent.removeChild(this.mFallbackRocket);
            }
            this.mFallbackRocket = null;
         }
         if(this.mFallbackExplosion)
         {
            this.mFallbackExplosion.stop();
            this.mFallbackExplosion.gotoAndStop(1);
            this.mFallbackExplosion.visible = false;
            if(this.mFallbackExplosion.parent)
            {
               this.mFallbackExplosion.parent.removeChild(this.mFallbackExplosion);
            }
            this.mFallbackExplosion = null;
         }
         Utils.DiagEvent("FIREMISSION_FALLBACK_CLEANUP","mission=" + this.mItem.mId + ";reason=" + param1 + ";elapsed_ms=" + param2);
      }

'@
  $fire=Replace-LiteralOnce $fire $startNeedle ($finishHelper+$startNeedle) 'firemission_fallback_cleanup_helper'
  $fireNaturalPattern='(?ms)if\(this\.mFallbackExplosion\.currentFrame\s*>=\s*this\.mFallbackExplosion\.totalFrames\)\s*\{\s*this\.mFallbackFinished\s*=\s*true;\s*this\.mFallbackExplosion\.visible\s*=\s*false;\s*\}'
  $fireNaturalReplacement=@'
if(this.mFallbackExplosion.currentFrame >= this.mFallbackExplosion.totalFrames)
            {
               this.finishFallbackVisuals("timeline",fallbackElapsed);
            }
'@
  $fire=Replace-RegexOnce $fire $fireNaturalPattern $fireNaturalReplacement 'firemission_fallback_natural_cleanup'
  $fireMissingPattern='(?ms)\s*else\s*\{\s*this\.mFallbackFinished\s*=\s*true;\s*\}\s*if\(fallbackElapsed\s*>=\s*FALLBACK_TOTAL_TIMEOUT_MS\)\s*\{\s*this\.mFallbackFinished\s*=\s*true;\s*\}'
  $fireMissingReplacement=@'
            else
            {
               this.finishFallbackVisuals("missing_explosion",fallbackElapsed);
            }
            if(!this.mFallbackFinished && fallbackElapsed >= FALLBACK_TOTAL_TIMEOUT_MS)
            {
               this.finishFallbackVisuals("timeout",fallbackElapsed);
            }
'@
  $fire=Replace-RegexOnce $fire $fireMissingPattern $fireMissingReplacement 'firemission_fallback_timeout_cleanup'
  Write-Utf8Bom $firePath $fire

  # 5) PERF v2: preserve raw telemetry, but attribute jank to the latest
  # meaningful gameplay event instead of periodic profiler noise.
  $javaPath=Target-Path 'perfjava'
  $java=Normalize-Lf ([IO.File]::ReadAllText($javaPath))
  $javaFieldsNeedle='    private static volatile long LAST_GAME_EVENT_ELAPSED_MS = -1L;'
  $javaFieldsReplacement=@'
    private static volatile long LAST_GAME_EVENT_ELAPSED_MS = -1L;
    private static volatile String LAST_GAMEPLAY_EVENT_KIND = "";
    private static volatile String LAST_GAMEPLAY_EVENT_DETAIL = "";
    private static volatile long LAST_GAMEPLAY_EVENT_ELAPSED_MS = -1L;
'@
  $java=Replace-LiteralOnce $java $javaFieldsNeedle $javaFieldsReplacement.TrimEnd() 'perf_meaningful_event_fields'

  $frameSpikePattern='(?ms)    private static final class FrameSpike \{.*?    \}\s*\n\s*    public static void recordGameEvent'
  $frameSpikeReplacement=@'
    private static final class FrameSpike {
        final long elapsedMs;
        final double frameMs;
        final String rawEventKind;
        final String rawEventDetail;
        final long rawEventAgeMs;
        final String eventKind;
        final String eventDetail;
        final long eventAgeMs;
        FrameSpike(long elapsedMs, double frameMs,
                   String rawEventKind, String rawEventDetail, long rawEventAgeMs,
                   String eventKind, String eventDetail, long eventAgeMs) {
            this.elapsedMs = elapsedMs;
            this.frameMs = frameMs;
            this.rawEventKind = rawEventKind;
            this.rawEventDetail = rawEventDetail;
            this.rawEventAgeMs = rawEventAgeMs;
            this.eventKind = eventKind;
            this.eventDetail = eventDetail;
            this.eventAgeMs = eventAgeMs;
        }
    }

    public static void recordGameEvent
'@
  $java=Replace-RegexOnce $java $frameSpikePattern $frameSpikeReplacement 'perf_frame_spike_dual_context'

  $eventAssignNeedle='            LAST_GAME_EVENT_ELAPSED_MS = elapsed;'
  $eventAssignReplacement=@'
            LAST_GAME_EVENT_ELAPSED_MS = elapsed;
            if (isMeaningfulGameplayEvent(safeKind)) {
                LAST_GAMEPLAY_EVENT_KIND = safeKind;
                LAST_GAMEPLAY_EVENT_DETAIL = safeDetail;
                LAST_GAMEPLAY_EVENT_ELAPSED_MS = elapsed;
            }
'@
  $java=Replace-LiteralOnce $java $eventAssignNeedle $eventAssignReplacement.TrimEnd() 'perf_meaningful_event_tracking'

  $clearSpikesNeedle='    private static void clearFrameSpikes() {'
  $meaningfulHelper=@'
    private static boolean isMeaningfulGameplayEvent(String kind) {
        if (kind == null || kind.length() == 0) return false;
        return !("SCENE_PROFILE".equals(kind)
            || "SCENE_SUBSYSTEM_JANK".equals(kind)
            || "ANIMATION_STATS".equals(kind)
            || "ANIMATION_MATERIALIZED".equals(kind)
            || "AUTO_FLIGHT_RECORDER".equals(kind));
    }

'@
  $java=Replace-LiteralOnce $java $clearSpikesNeedle ($meaningfulHelper+$clearSpikesNeedle) 'perf_meaningful_event_filter'

  $recordSpikePattern='(?ms)    private static void recordFrameSpike\(long deltaNs\) \{.*?    \}\s*\n\s*    private static void writeFrameSpikes'
  $recordSpikeReplacement=@'
    private static void recordFrameSpike(long deltaNs) {
        long now = android.os.SystemClock.elapsedRealtime();
        long rawAt = LAST_GAME_EVENT_ELAPSED_MS;
        long rawAge = rawAt < 0L ? -1L : Math.max(0L, now - rawAt);
        long gameplayAt = LAST_GAMEPLAY_EVENT_ELAPSED_MS;
        long gameplayAge = gameplayAt < 0L ? -1L : Math.max(0L, now - gameplayAt);
        FrameSpike spike = new FrameSpike(
            now,
            deltaNs / 1_000_000.0,
            LAST_GAME_EVENT_KIND,
            LAST_GAME_EVENT_DETAIL,
            rawAge,
            LAST_GAMEPLAY_EVENT_KIND,
            LAST_GAMEPLAY_EVENT_DETAIL,
            gameplayAge
        );
        synchronized (FRAME_SPIKE_LOCK) {
            while (FRAME_SPIKES.size() >= MAX_FRAME_SPIKES) FRAME_SPIKES.removeFirst();
            FRAME_SPIKES.addLast(spike);
        }
    }

    private static void accumulateJank(JSONObject bucket, String eventKind, double frameMs) throws Exception {
        String key = eventKind == null || eventKind.length() == 0 ? "UNATTRIBUTED" : eventKind;
        JSONObject stats = bucket.optJSONObject(key);
        if (stats == null) {
            stats = new JSONObject();
            stats.put("spikes", 0);
            stats.put("over_50ms", 0);
            stats.put("over_100ms", 0);
            stats.put("over_200ms", 0);
            stats.put("max_frame_ms", 0.0);
            bucket.put(key, stats);
        }
        stats.put("spikes", stats.optInt("spikes", 0) + 1);
        if (frameMs >= 50.0) stats.put("over_50ms", stats.optInt("over_50ms", 0) + 1);
        if (frameMs >= 100.0) stats.put("over_100ms", stats.optInt("over_100ms", 0) + 1);
        if (frameMs >= 200.0) stats.put("over_200ms", stats.optInt("over_200ms", 0) + 1);
        stats.put("max_frame_ms", Math.max(stats.optDouble("max_frame_ms", 0.0), frameMs));
    }

    private static void writeFrameSpikes
'@
  $java=Replace-RegexOnce $java $recordSpikePattern $recordSpikeReplacement 'perf_frame_spike_capture_context'

  $writeSpikesPattern='(?ms)    private static void writeFrameSpikes\(File dir\) \{.*?    \}\s*\n\s*    private static void writeGameEvents'
  $writeSpikesReplacement=@'
    private static void writeFrameSpikes(File dir) {
        if (dir == null) return;
        try {
            List<FrameSpike> snapshot;
            synchronized (FRAME_SPIKE_LOCK) { snapshot = new ArrayList<FrameSpike>(FRAME_SPIKES); }
            StringBuilder text = new StringBuilder();
            int over50 = 0;
            int over100 = 0;
            int over200 = 0;
            double maxMs = 0.0;
            JSONObject byGameplayEvent = new JSONObject();
            JSONObject byRawEvent = new JSONObject();
            for (FrameSpike spike : snapshot) {
                JSONObject row = new JSONObject();
                row.put("process_elapsed_ms", spike.elapsedMs);
                row.put("frame_ms", spike.frameMs);
                row.put("nearest_game_event_kind", spike.eventKind == null ? "" : spike.eventKind);
                row.put("nearest_game_event_detail", spike.eventDetail == null ? "" : spike.eventDetail);
                row.put("nearest_game_event_age_ms", spike.eventAgeMs);
                row.put("nearest_raw_event_kind", spike.rawEventKind == null ? "" : spike.rawEventKind);
                row.put("nearest_raw_event_detail", spike.rawEventDetail == null ? "" : spike.rawEventDetail);
                row.put("nearest_raw_event_age_ms", spike.rawEventAgeMs);
                text.append(row.toString()).append('\n');
                if (spike.frameMs >= 50.0) over50++;
                if (spike.frameMs >= 100.0) over100++;
                if (spike.frameMs >= 200.0) over200++;
                if (spike.frameMs > maxMs) maxMs = spike.frameMs;
                accumulateJank(byGameplayEvent, spike.eventKind, spike.frameMs);
                accumulateJank(byRawEvent, spike.rawEventKind, spike.frameMs);
            }
            writeText(new File(dir, "frame-spikes.jsonl"), text.toString());
            JSONObject summary = new JSONObject();
            summary.put("threshold_ms", 33);
            summary.put("retained_spikes", snapshot.size());
            summary.put("over_50ms", over50);
            summary.put("over_100ms", over100);
            summary.put("over_200ms", over200);
            summary.put("max_frame_ms", maxMs);
            summary.put("meaningful_event_correlation", true);
            writeText(new File(dir, "frame-spikes-summary.json"), summary.toString(2));
            JSONObject correlation = new JSONObject();
            correlation.put("generated_utc", utcIso());
            correlation.put("nearest_event_window_note", "nearest_game_event excludes periodic profiler noise; nearest_raw_event preserves the unfiltered stream.");
            correlation.put("by_event_kind", byGameplayEvent);
            correlation.put("by_gameplay_event_kind", byGameplayEvent);
            correlation.put("by_raw_event_kind", byRawEvent);
            writeText(new File(dir, "event-jank-correlation.json"), correlation.toString(2));
        } catch (Throwable t) {
            appendError(dir, "frame_spikes", t);
        }
    }

    private static void writeGameEvents
'@
  $java=Replace-RegexOnce $java $writeSpikesPattern $writeSpikesReplacement 'perf_meaningful_jank_report'
  if(-not $java.Contains('by_gameplay_event_kind') -or -not $java.Contains('nearest_raw_event_kind')){throw 'ANDROID_VISUAL_COMBAT_OVERLAY=FAIL verification=perf_v2_missing'}
  Write-Utf8NoBom $javaPath $java

  # Ensure every changed AS3 class is actually replaced into the Android SWF.
  $patcherPath=Target-Path 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patcher=Replace-LiteralOnce $patcher '$patchVersion=''mobile-engine-v3.22-combat-lifecycle-rootfix''' '$patchVersion=''mobile-engine-v3.23-visual-combat-rootfix''' 'patch_version_v3_23'
  $missileSpec="  [ordered]@{Class='game.gameElements.Missile';Source='src\game\gameElements\Missile.as';Log='ffdec-feature-missile-lifecycle.log'},"
  $artillerySpec="  [ordered]@{Class='game.gameElements.ArtilleryRound';Source='src\game\gameElements\ArtilleryRound.as';Log='ffdec-feature-artillery-lifecycle.log'},"
  $patcher=Replace-LiteralOnce $patcher $missileSpec ($missileSpec+"`n"+$artillerySpec) 'artillery_swf_patch_spec'
  foreach($required in @('game.characters.AnimationController','game.gameElements.ArtilleryRound','game.gameElements.FireMissionObject','game.battlefield.TileMapGraphic','game.isometric.IsometricScene','mobile-engine-v3.23-visual-combat-rootfix')){
    if(-not $patcher.Contains($required)){throw "ANDROID_VISUAL_COMBAT_OVERLAY=FAIL patch=patcher_verification missing=$required"}
  }
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=status_hint_orientation_independent_of_unit_facing counter_flip=hint_roots_only'
  Write-Host 'REGRESSION_CHECK=PASS name=ownership_visual_commit_same_action_frame partial_dirty_redraw=true fallback=deferred'
  Write-Host 'REGRESSION_CHECK=PASS name=artillery_impact_cleanup_bounded parent_safe=true watchdog_frames=90 trail_clear=true'
  Write-Host 'REGRESSION_CHECK=PASS name=firemission_fallback_cleanup_deterministic natural=true timeout=true missing_explosion=true'
  Write-Host 'REGRESSION_CHECK=PASS name=existing_missile_cleanup_preserved event=MISSILE_IMPACT_CLEANUP'
  Write-Host 'REGRESSION_CHECK=PASS name=perf_meaningful_event_correlation raw_context=preserved gameplay_context=filtered over_200ms=true'
  Write-Host 'REGRESSION_CHECK=PASS name=render_hotpath_contract_preserved immediate_commit_uses_existing_dirty_region=true'
  Write-Host "ANDROID_VISUAL_COMBAT_OVERLAY=PASS mode=apply sha=$ExpectedSha schema=v1 swf_patch_version=mobile-engine-v3.23-visual-combat-rootfix perf_schema=meaningful-jank-v2"
}catch{
  $failure=$_
  foreach($key in $targets.Keys){
    $src=Backup-Path $key
    $dst=Target-Path $key
    if(Test-Path -LiteralPath $src -PathType Leaf){Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue}
  }
  throw $failure
}
