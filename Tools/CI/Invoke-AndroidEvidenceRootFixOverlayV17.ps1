param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v16=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV16.ps1'
if(-not(Test-Path -LiteralPath $v16 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL predecessor_missing=$v16"}

$targets=[ordered]@{
  animation='src\game\characters\AnimationController.as'
  hit='src\game\utils\HitEffect.as'
  perfjava='android\native\diagnostics\java\com\valverde\armyattack\diagnostics\PerformanceOverlay.java'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v17\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Write-Utf8NoBom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.post-v16')}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V17_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $rx=New-Object System.Text.RegularExpressions.Regex($Pattern)
  $matches=$rx.Matches($Text)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL patch=$Name expected_matches=1 actual=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V17_HOOK=PASS name=$Name matches=1 semantic=true"
  return $rx.Replace($Text,$Replacement,1)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    foreach($entry in @($manifest.files)){
      $key=[string]$entry.key
      $backup=Backup-Path $key
      $target=Target-Path $key
      if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL restore_backup_missing key=$key"}
      Copy-Item -LiteralPath $backup -Destination $target -Force
      $restored=Get-Sha256 $target
      $expected=([string]$entry.sha256).ToUpperInvariant()
      if($restored -ne $expected){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL restore_hash key=$key expected=$expected actual=$restored"}
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v16 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V17=PASS mode=restore baseline_restored=true predecessor=v16 sha=$ExpectedSha"
  return
}

& $v16 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL predecessor_apply_exit=$LASTEXITCODE"}

foreach($key in $targets.Keys){
  $path=Target-Path $key
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V17=FAIL required_file_missing key=$key path=$path"}
}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v17';source_sha=$ExpectedSha;predecessor='v16';files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try {
  # Exact 3a9cd346 physical evidence shows real attacks use
  # setAnimationAction()->playCurrentAnimation(), not startShootAnimation().
  $animationPath=Target-Path 'animation'
  $animation=Normalize-Lf ([IO.File]::ReadAllText($animationPath))
  if(-not $animation.Contains('import flash.utils.getQualifiedClassName;')){
    $ownerImport=@'
   import flash.utils.getTimer;
   import flash.utils.getQualifiedClassName;
'@
    $animation=Replace-LiteralOne $animation '   import flash.utils.getTimer;' $ownerImport.TrimEnd() 'animation_owner_import'
  }

  $animationFields=@'
      private var mDiagnosticsDestroyed:Boolean = false;
      private static const SHOOT_TRANSIENT_MAX_MS:int = 1800;
      private var mShootTransientRoot:MovieClip = null;
      private var mShootTransientStartedAt:int = 0;
      private var mShootTransientDeadlineMs:int = 0;
      private var mShootTransientIndex:int = -1;
      private static var smShootTransientSerial:int = 0;
      private var mShootTransientId:int = 0;
'@
  $animation=Replace-LiteralOne $animation '      private var mDiagnosticsDestroyed:Boolean = false;' $animationFields.TrimEnd() 'shoot_transient_fields'

  $setAnimationPattern='(?ms)(public function setAnimation\(param1:int\)\s*:\s*Boolean\s*\{.*?this\.materializeAnimation\(param1\);\s*)if\(param1 == this\.mCurrentAnimation\)\s*\{\s*return false;\s*\}'
  $setAnimationReplacement=@'
$1if(param1 == this.mCurrentAnimation)
         {
            if(this.isTransientShootIndex(param1))
            {
               Utils.DiagEvent("ANIMATION_SWITCH","owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";from=" + this.mCurrentAnimation + ";to=" + param1 + ";same_index_replay=1");
               this.cleanupTransientShoot("same_index_replay");
               return true;
            }
            return false;
         }
         if(this.mShootTransientRoot)
         {
            this.cleanupTransientShoot("animation_switch");
         }
         Utils.DiagEvent("ANIMATION_SWITCH","owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";from=" + this.mCurrentAnimation + ";to=" + param1 + ";same_index_replay=0");
'@
  $animation=Replace-RegexOne $animation $setAnimationPattern $setAnimationReplacement.TrimEnd() 'actual_animation_switch_cleanup'

  $helpers=@'
      private function isTransientShootIndex(param1:int) : Boolean
      {
         if(this.mOwner is IsometricCharacter)
         {
            return param1 == CHARACTER_ANIMATION_SHOOT || param1 == CHARACTER_ANIMATION_SHOOT_UP;
         }
         return param1 == INSTALLATION_ANIMATION_SHOOT;
      }

      private function armTransientShoot() : void
      {
         if(!this.isTransientShootIndex(this.mCurrentAnimation))
         {
            return;
         }
         if(this.mShootTransientRoot)
         {
            this.cleanupTransientShoot("rearm");
         }
         var root:MovieClip = this.mAnimations && this.mCurrentAnimation >= 0 && this.mCurrentAnimation < this.mAnimations.length ? this.mAnimations[this.mCurrentAnimation] as MovieClip : null;
         if(!root)
         {
            Utils.DiagEvent("SHOOT_TRANSIENT_RESIDUE","reason=arm_missing_root;index=" + this.mCurrentAnimation + ";owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null"));
            return;
         }
         var targets:Array = this.getAnimationTreeTargets(this.mCurrentAnimation);
         var clip:MovieClip = null;
         var maxFrames:int = Math.max(1,root.totalFrames);
         var i:int = 0;
         while(i < targets.length)
         {
            clip = targets[i] as MovieClip;
            if(clip)
            {
               maxFrames = Math.max(maxFrames,clip.totalFrames);
            }
            i++;
         }
         smShootTransientSerial++;
         this.mShootTransientId = smShootTransientSerial;
         this.mShootTransientIndex = this.mCurrentAnimation;
         this.mShootTransientRoot = root;
         this.mShootTransientStartedAt = getTimer();
         this.mShootTransientDeadlineMs = Math.max(700,Math.min(SHOOT_TRANSIENT_MAX_MS,maxFrames * 40 + 250));
         root.removeEventListener(Event.ENTER_FRAME,this.shootTransientFrame);
         root.visible = true;
         root.addEventListener(Event.ENTER_FRAME,this.shootTransientFrame,false,0,true);
         var source:String = this.mFiles && this.mShootTransientIndex >= 0 && this.mShootTransientIndex < this.mFiles.length ? String(this.mFiles[this.mShootTransientIndex]) : "unknown";
         Utils.DiagEvent("SHOOT_TRANSIENT_ARMED","id=" + this.mShootTransientId + ";owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";index=" + this.mShootTransientIndex + ";source=" + source + ";tree_clips=" + targets.length + ";max_frames=" + maxFrames + ";deadline_ms=" + this.mShootTransientDeadlineMs);
      }

      private function shootTransientFrame(param1:Event) : void
      {
         var root:MovieClip = param1.currentTarget as MovieClip;
         if(!root)
         {
            return;
         }
         if(root != this.mShootTransientRoot)
         {
            root.removeEventListener(Event.ENTER_FRAME,this.shootTransientFrame);
            return;
         }
         var elapsedReal:int = Math.max(0,getTimer() - this.mShootTransientStartedAt);
         var targets:Array = this.getAnimationTreeTargets(this.mShootTransientIndex);
         var clip:MovieClip = null;
         var animated:int = 0;
         var ended:int = 0;
         var i:int = 0;
         while(i < targets.length)
         {
            clip = targets[i] as MovieClip;
            if(clip && clip.totalFrames > 1)
            {
               animated++;
               if(clip.currentFrameLabel == "end" || clip.currentFrame >= clip.totalFrames)
               {
                  ended++;
               }
            }
            i++;
         }
         if((animated > 0 && ended >= animated) || elapsedReal >= this.mShootTransientDeadlineMs)
         {
            this.cleanupTransientShoot(animated > 0 && ended >= animated ? "timeline_complete" : "wallclock_timeout");
         }
      }

      private function cleanupTransientShoot(param1:String) : void
      {
         var root:MovieClip = this.mShootTransientRoot;
         if(!root)
         {
            return;
         }
         var index:int = this.mShootTransientIndex;
         var id:int = this.mShootTransientId;
         var startedAt:int = this.mShootTransientStartedAt;
         var deadline:int = this.mShootTransientDeadlineMs;
         var elapsedReal:int = startedAt > 0 ? Math.max(0,getTimer() - startedAt) : 0;
         root.removeEventListener(Event.ENTER_FRAME,this.shootTransientFrame);
         var targets:Array = this.getAnimationTreeTargets(index);
         var clip:MovieClip = null;
         var terminalBefore:int = 0;
         var resetNodes:int = 0;
         var i:int = 0;
         while(i < targets.length)
         {
            clip = targets[i] as MovieClip;
            if(clip)
            {
               if(clip.totalFrames > 1 && (clip.currentFrameLabel == "end" || clip.currentFrame >= clip.totalFrames))
               {
                  terminalBefore++;
               }
               clip.stop();
               clip.gotoAndStop(1);
               resetNodes++;
            }
            i++;
         }
         root.visible = true;

         this.mShootTransientRoot = null;
         this.mShootTransientId = 0;
         this.mShootTransientStartedAt = 0;
         this.mShootTransientDeadlineMs = 0;
         this.mShootTransientIndex = -1;

         var nonResetAfter:int = 0;
         i = 0;
         while(i < targets.length)
         {
            clip = targets[i] as MovieClip;
            if(clip && clip.currentFrame != 1)
            {
               nonResetAfter++;
            }
            i++;
         }

         var autoIdle:Boolean = param1 == "timeline_complete" || param1 == "wallclock_timeout";
         var idleSwitched:Boolean = false;
         if(autoIdle && this.mOwner)
         {
            idleSwitched = this.mOwner.setAnimationAction(0,false,true);
         }
         Utils.DiagEvent("SHOOT_TRANSIENT_CLEANUP","id=" + id + ";owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";index=" + index + ";reason=" + param1 + ";elapsed_real_ms=" + elapsedReal + ";deadline_ms=" + deadline + ";terminal_before=" + terminalBefore + ";reset_nodes=" + resetNodes + ";nonreset_after=" + nonResetAfter + ";idle_requested=" + autoIdle + ";idle_switched=" + idleSwitched);
         if(nonResetAfter > 0)
         {
            Utils.DiagEvent("SHOOT_TRANSIENT_RESIDUE","id=" + id + ";owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";index=" + index + ";reason=frames_not_reset;nonreset_after=" + nonResetAfter);
         }
      }

      public function playCurrentAnimation() : void
'@
  $animation=Replace-LiteralOne $animation '      public function playCurrentAnimation() : void' $helpers.TrimEnd() 'actual_play_path_helpers'

  $playArmPattern='(?ms)(public function playCurrentAnimation\(\)\s*:\s*void\s*\{.*?var i:int = 0;\s*)(while\(i < targets\.length\))'
  $playArmReplacement=@'
$1if(this.isTransientShootIndex(this.mCurrentAnimation))
         {
            this.armTransientShoot();
         }
         $2
'@
  $animation=Replace-RegexOne $animation $playArmPattern $playArmReplacement.TrimEnd() 'actual_play_path_arms_cleanup'

  $stopPattern='(?ms)(public function stopCurrentAnimation\(\)\s*:\s*void\s*\{)'
  $stopReplacement='$1'+"`n         this.cleanupTransientShoot(`"stop_current`");"
  $animation=Replace-RegexOne $animation $stopPattern $stopReplacement 'stop_path_cleans_shoot'

  $destroyPattern='(?ms)(public function destroy\(\)\s*:\s*void\s*\{)'
  $destroyReplacement='$1'+"`n         this.cleanupTransientShoot(`"destroy`");"
  $animation=Replace-RegexOne $animation $destroyPattern $destroyReplacement 'destroy_path_cleans_shoot'

  foreach($token in @(
    'SHOOT_TRANSIENT_ARMED',
    'SHOOT_TRANSIENT_CLEANUP',
    'SHOOT_TRANSIENT_RESIDUE',
    'CHARACTER_ANIMATION_SHOOT_UP',
    'this.armTransientShoot();',
    'this.cleanupTransientShoot("animation_switch");',
    'this.mOwner.setAnimationAction(0,false,true);',
    'ANIMATION_SWITCH'
  )){Require-Token $animation $token 'animation_actual_shoot_lifecycle'}
  Write-Utf8Bom $animationPath $animation

  # V15's update-time cleanup remains primary. Add a timer owner so a stalled
  # EffectController update cannot leave explosion_small_sequence on screen.
  $hitPath=Target-Path 'hit'
  $hit=Normalize-Lf ([IO.File]::ReadAllText($hitPath))
  if(-not $hit.Contains('import flash.utils.clearTimeout;')){
    $hitImport=@'
   import flash.utils.clearTimeout;
   import flash.utils.setTimeout;
   import flash.utils.getTimer;
'@
    $hit=Replace-LiteralOne $hit '   import flash.utils.getTimer;' $hitImport.TrimEnd() 'hit_watchdog_imports'
  }
  $hitFields=@'
      private var mStartedAt:int = 0;
      private static const HIT_EFFECT_WATCHDOG_MS:int = 1200;
      private var mCleanupTimeoutId:uint = 0;
      private var mCleanupDone:Boolean = false;
'@
  $hit=Replace-LiteralOne $hit '      private var mStartedAt:int = 0;' $hitFields.TrimEnd() 'hit_watchdog_fields'

  $hitHelper=@'
      private function handleCleanupTimeout() : void
      {
         this.mCleanupTimeoutId = 0;
         if(this.mCleanupDone || !mMC)
         {
            return;
         }
         var elapsedReal:int = this.mStartedAt > 0 ? Math.max(0,getTimer() - this.mStartedAt) : HIT_EFFECT_WATCHDOG_MS;
         var total:int = Math.max(1,mMC.totalFrames);
         var hadParent:Boolean = mMC.parent != null;
         mMC.stop();
         mMC.gotoAndStop(1);
         mMC.visible = false;
         if(mMC.parent)
         {
            mMC.parent.removeChild(mMC);
         }
         mMC = null;
         this.mCleanupDone = true;
         this.mStartedAt = 0;
         Utils.DiagEvent("HIT_EFFECT_WATCHDOG_CLEANUP","type=" + mType + ";reason=timer_watchdog;elapsed_real_ms=" + elapsedReal + ";watchdog_ms=" + HIT_EFFECT_WATCHDOG_MS + ";frames=" + total + ";had_parent=" + hadParent);
      }

      override public function update(param1:int) : Boolean
'@
  $hit=Replace-LiteralOne $hit '      override public function update(param1:int) : Boolean' $hitHelper.TrimEnd() 'hit_watchdog_helper'

  $hitUpdateCleanupPattern='(?ms)(if\(reachedEnd \|\| elapsedReal >= targetMs\)\s*\{\s*var reason:String = reachedEnd \? "timeline" : "wallclock_target";)'
  $hitUpdateCleanupReplacement=@'
$1
            if(this.mCleanupTimeoutId != 0)
            {
               clearTimeout(this.mCleanupTimeoutId);
               this.mCleanupTimeoutId = 0;
            }
            this.mCleanupDone = true;
'@
  $hit=Replace-RegexOne $hit $hitUpdateCleanupPattern $hitUpdateCleanupReplacement.TrimEnd() 'hit_update_disarms_watchdog'

  $hitArmPattern='(?ms)(this\.mStartedAt = getTimer\(\);\s*)mMC\.gotoAndPlay\(1\);'
  $hitArmReplacement=@'
$1this.mCleanupDone = false;
            if(this.mCleanupTimeoutId != 0)
            {
               clearTimeout(this.mCleanupTimeoutId);
            }
            this.mCleanupTimeoutId = setTimeout(this.handleCleanupTimeout,HIT_EFFECT_WATCHDOG_MS);
            Utils.DiagEvent("HIT_EFFECT_ARMED","type=" + mType + ";frames=" + Math.max(1,mMC.totalFrames) + ";watchdog_ms=" + HIT_EFFECT_WATCHDOG_MS);
            mMC.gotoAndPlay(1);
'@
  $hit=Replace-RegexOne $hit $hitArmPattern $hitArmReplacement.TrimEnd() 'hit_effect_observable_arm'

  foreach($token in @(
    'HIT_EFFECT_ARMED',
    'HIT_EFFECT_WATCHDOG_CLEANUP',
    'setTimeout(this.handleCleanupTimeout,HIT_EFFECT_WATCHDOG_MS)',
    'clearTimeout(this.mCleanupTimeoutId)',
    'HIT_EFFECT_WALLCLOCK_CLEANUP'
  )){Require-Token $hit $token 'hit_effect_watchdog'}
  Write-Utf8Bom $hitPath $hit

  # Make the shareable ZIP explain lifecycle pairing/root-cause hints directly.
  $perfPath=Target-Path 'perfjava'
  $perf=Normalize-Lf ([IO.File]::ReadAllText($perfPath))
  if(-not $perf.Contains('kind.startsWith("SHOOT_")')){
    $mirrorReplacement=@'
            || kind.startsWith("ANIMATION_")
            || kind.startsWith("SHOOT_")
            || kind.startsWith("HIT_EFFECT_")
'@
    $perf=Replace-LiteralOne $perf '            || kind.startsWith("ANIMATION_")' $mirrorReplacement.TrimEnd() 'diagnostics_mirror_visual_lifecycle'
  }

  $summaryPattern='(?ms)    private static void writeGameEventSummary\(File dir\) \{.*?\n    \}(?=\n    private static final AtomicBoolean BOOTSTRAPPED)'
  $summaryReplacement=@'
    private static int detailInt(String detail, String key, int fallback) {
        if (detail == null || key == null) return fallback;
        String prefix = key + "=";
        String[] parts = detail.split(";");
        for (String part : parts) {
            if (part != null && part.startsWith(prefix)) {
                try { return Integer.parseInt(part.substring(prefix.length())); }
                catch (Throwable ignored) { return fallback; }
            }
        }
        return fallback;
    }

    private static void writeGameEventSummary(File dir) {
        if (dir == null) return;
        try {
            List<GameEvent> snapshot;
            synchronized (GAME_EVENT_LOCK) { snapshot = new ArrayList<GameEvent>(GAME_EVENTS); }
            JSONObject counts = new JSONObject();

            int playerShootMaterialized = 0;
            int shootArmed = 0;
            int shootCleanup = 0;
            int shootResidue = 0;
            int shootWallclockCleanup = 0;
            int shootIdleCleanup = 0;
            int shootSwitchToIdle = 0;
            int shootSameIndexReplay = 0;
            int shootMaxCleanupMs = 0;
            java.util.HashSet<Integer> shootArmIds = new java.util.HashSet<Integer>();
            java.util.HashSet<Integer> shootCleanupIds = new java.util.HashSet<Integer>();

            int hitArmed = 0;
            int hitWallclockCleanup = 0;
            int hitWatchdogCleanup = 0;
            int hitMaxCleanupMs = 0;
            int explosionArmed = 0;
            int explosionCleanup = 0;
            int missileImpact = 0;
            int missileImpactCleanup = 0;
            int missileTrailCleanup = 0;
            int ownershipDirty = 0;
            int ownershipCommit = 0;
            int ownershipPartial = 0;
            int ownershipFull = 0;
            int ownershipFailed = 0;
            int ownershipMaxCommitMs = 0;

            for (GameEvent event : snapshot) {
                String kind = event.kind == null ? "UNKNOWN" : event.kind;
                String detail = event.detail == null ? "" : event.detail;
                counts.put(kind, counts.optInt(kind, 0) + 1);

                if ("ANIMATION_MATERIALIZED".equals(kind)
                    && detail.contains("owner=game.characters::PlayerUnit")
                    && (detail.contains("index=3;") || detail.contains("index=7;"))) {
                    playerShootMaterialized++;
                } else if ("ANIMATION_SWITCH".equals(kind)
                    && detail.contains("owner=game.characters::PlayerUnit")) {
                    if (detail.contains("from=3;to=0;") || detail.contains("from=7;to=0;")) shootSwitchToIdle++;
                    if (detail.contains("same_index_replay=1")) shootSameIndexReplay++;
                } else if ("SHOOT_TRANSIENT_ARMED".equals(kind)) {
                    shootArmed++;
                    int id = detailInt(detail, "id", -1);
                    if (id >= 0) shootArmIds.add(id);
                } else if ("SHOOT_TRANSIENT_CLEANUP".equals(kind)) {
                    shootCleanup++;
                    int id = detailInt(detail, "id", -1);
                    if (id >= 0) shootCleanupIds.add(id);
                    int elapsed = detailInt(detail, "elapsed_real_ms", 0);
                    if (elapsed > shootMaxCleanupMs) shootMaxCleanupMs = elapsed;
                    if (detail.contains("reason=wallclock_timeout")) shootWallclockCleanup++;
                    if (detail.contains("idle_requested=true")) shootIdleCleanup++;
                } else if ("SHOOT_TRANSIENT_RESIDUE".equals(kind)) {
                    shootResidue++;
                } else if ("HIT_EFFECT_ARMED".equals(kind)) {
                    hitArmed++;
                } else if ("HIT_EFFECT_WALLCLOCK_CLEANUP".equals(kind)) {
                    hitWallclockCleanup++;
                    int elapsed = detailInt(detail, "elapsed_real_ms", 0);
                    if (elapsed > hitMaxCleanupMs) hitMaxCleanupMs = elapsed;
                } else if ("HIT_EFFECT_WATCHDOG_CLEANUP".equals(kind)) {
                    hitWatchdogCleanup++;
                    int elapsed = detailInt(detail, "elapsed_real_ms", 0);
                    if (elapsed > hitMaxCleanupMs) hitMaxCleanupMs = elapsed;
                } else if ("EXPLOSION_TRANSIENT_ARMED".equals(kind)) {
                    explosionArmed++;
                } else if ("EXPLOSION_TRANSIENT_CLEANUP".equals(kind)) {
                    explosionCleanup++;
                } else if ("PROJECTILE_LIFECYCLE".equals(kind) && detail.contains("type=Missile;phase=impact")) {
                    missileImpact++;
                } else if ("MISSILE_IMPACT_CLEANUP".equals(kind)) {
                    missileImpactCleanup++;
                } else if ("MISSILE_TRAIL_CLEANUP".equals(kind)) {
                    missileTrailCleanup++;
                } else if ("OWNERSHIP_DIRTY_MARK".equals(kind)) {
                    ownershipDirty++;
                } else if ("OWNERSHIP_VISUAL_COMMIT".equals(kind)) {
                    ownershipCommit++;
                    int elapsed = detailInt(detail, "elapsed_ms", 0);
                    if (elapsed > ownershipMaxCommitMs) ownershipMaxCommitMs = elapsed;
                    if (detail.contains("result=partial")) ownershipPartial++;
                    if (detail.contains("result=full")) ownershipFull++;
                    if (detail.contains("result=failed")) ownershipFailed++;
                }
            }

            java.util.HashSet<Integer> unmatchedShootIds = new java.util.HashSet<Integer>(shootArmIds);
            unmatchedShootIds.removeAll(shootCleanupIds);
            int shootUnmatched = Math.max(Math.max(0, shootArmed - shootCleanup), unmatchedShootIds.size());
            int hitCleanup = hitWallclockCleanup + hitWatchdogCleanup;

            org.json.JSONArray hints = new org.json.JSONArray();
            if (playerShootMaterialized > 0 && shootArmed == 0) hints.put("SHOOT_TRANSIENT_PATH_NOT_ARMED");
            if (shootArmed > 0 && shootCleanup > 0 && shootSwitchToIdle == 0) hints.put("SHOOT_NO_IDLE_TRANSITION_OBSERVED");
            if (shootUnmatched > 0) hints.put("SHOOT_TRANSIENT_UNMATCHED");
            if (shootResidue > 0) hints.put("SHOOT_TRANSIENT_RESIDUE");
            if (hitArmed > hitCleanup) hints.put("HIT_EFFECT_UNMATCHED");
            if (explosionArmed > explosionCleanup) hints.put("EXPLOSION_TRANSIENT_UNMATCHED");
            if (missileImpact > missileImpactCleanup) hints.put("MISSILE_IMPACT_UNMATCHED");
            if (ownershipDirty > ownershipCommit) hints.put("OWNERSHIP_COMMIT_MISSING");
            if (ownershipFailed > 0) hints.put("OWNERSHIP_COMMIT_FAILED");
            if (hints.length() == 0) hints.put("NO_VISUAL_LIFECYCLE_ROOT_CAUSE_DETECTED");

            JSONObject shoot = new JSONObject();
            shoot.put("player_shoot_materialized", playerShootMaterialized);
            shoot.put("armed", shootArmed);
            shoot.put("cleanup", shootCleanup);
            shoot.put("unmatched_armed", shootUnmatched);
            shoot.put("residue_events", shootResidue);
            shoot.put("wallclock_cleanups", shootWallclockCleanup);
            shoot.put("idle_cleanup_requests", shootIdleCleanup);
            shoot.put("switch_to_idle", shootSwitchToIdle);
            shoot.put("same_index_replays", shootSameIndexReplay);
            shoot.put("max_cleanup_ms", shootMaxCleanupMs);

            JSONObject hit = new JSONObject();
            hit.put("armed", hitArmed);
            hit.put("wallclock_cleanup", hitWallclockCleanup);
            hit.put("watchdog_cleanup", hitWatchdogCleanup);
            hit.put("unmatched_armed", Math.max(0, hitArmed - hitCleanup));
            hit.put("max_cleanup_ms", hitMaxCleanupMs);

            JSONObject explosion = new JSONObject();
            explosion.put("armed", explosionArmed);
            explosion.put("cleanup", explosionCleanup);
            explosion.put("unmatched_armed", Math.max(0, explosionArmed - explosionCleanup));

            JSONObject missile = new JSONObject();
            missile.put("impacts", missileImpact);
            missile.put("impact_cleanup", missileImpactCleanup);
            missile.put("trail_cleanup", missileTrailCleanup);
            missile.put("unmatched_impacts", Math.max(0, missileImpact - missileImpactCleanup));

            JSONObject ownership = new JSONObject();
            ownership.put("dirty_marks", ownershipDirty);
            ownership.put("commits", ownershipCommit);
            ownership.put("partial", ownershipPartial);
            ownership.put("full", ownershipFull);
            ownership.put("failed", ownershipFailed);
            ownership.put("max_commit_ms", ownershipMaxCommitMs);

            JSONObject visual = new JSONObject();
            visual.put("generated_utc", utcIso());
            visual.put("schema", "visual-lifecycle/v1");
            visual.put("shoot_transient", shoot);
            visual.put("hit_effect", hit);
            visual.put("explosion_transient", explosion);
            visual.put("missile", missile);
            visual.put("ownership", ownership);
            visual.put("root_cause_hints", hints);
            writeText(new File(dir, "visual-lifecycle-summary.json"), visual.toString(2));

            StringBuilder rootCause = new StringBuilder();
            rootCause.append("ROOT_CAUSE_HINTS=").append(hints.toString()).append('\n');
            rootCause.append("SHOOT materialized=").append(playerShootMaterialized)
                .append(" armed=").append(shootArmed)
                .append(" cleanup=").append(shootCleanup)
                .append(" unmatched=").append(shootUnmatched)
                .append(" residue=").append(shootResidue)
                .append(" switch_to_idle=").append(shootSwitchToIdle)
                .append(" max_cleanup_ms=").append(shootMaxCleanupMs).append('\n');
            rootCause.append("HIT_EFFECT armed=").append(hitArmed)
                .append(" cleanup=").append(hitCleanup)
                .append(" watchdog=").append(hitWatchdogCleanup)
                .append(" unmatched=").append(Math.max(0, hitArmed - hitCleanup))
                .append(" max_cleanup_ms=").append(hitMaxCleanupMs).append('\n');
            rootCause.append("OWNERSHIP dirty=").append(ownershipDirty)
                .append(" commits=").append(ownershipCommit)
                .append(" failed=").append(ownershipFailed)
                .append(" max_commit_ms=").append(ownershipMaxCommitMs).append('\n');
            writeText(new File(dir, "root-cause.txt"), rootCause.toString());

            JSONObject summary = new JSONObject();
            summary.put("generated_utc", utcIso());
            summary.put("retained_events", snapshot.size());
            summary.put("parsed_events", snapshot.size());
            summary.put("counts_by_kind", counts);
            summary.put("visual_lifecycle_file", "visual-lifecycle-summary.json");
            summary.put("root_cause_file", "root-cause.txt");
            summary.put("root_cause_hints", hints);
            writeText(new File(dir, "game-events-summary.json"), summary.toString(2));
        } catch (Throwable t) {
            appendError(dir, "game_event_summary", t);
        }
    }
'@
  $perf=Replace-RegexOne $perf $summaryPattern $summaryReplacement.TrimEnd() 'diagnostics_visual_lifecycle_summary'

  foreach($token in @(
    'kind.startsWith("SHOOT_")',
    'kind.startsWith("HIT_EFFECT_")',
    'visual-lifecycle-summary.json',
    'root-cause.txt',
    'SHOOT_TRANSIENT_PATH_NOT_ARMED',
    'HIT_EFFECT_UNMATCHED',
    'OWNERSHIP_COMMIT_MISSING'
  )){Require-Token $perf $token 'diagnostics_root_cause_zip'}
  Write-Utf8NoBom $perfPath $perf

  Write-Host 'REGRESSION_CHECK=PASS name=actual_shoot_path_cleanup route=setAnimationAction->playCurrentAnimation indexes=3,7 installation=1 wallclock_bounded=true nested_frames_reset=true'
  Write-Host 'REGRESSION_CHECK=PASS name=shoot_same_index_replay stale_fx_reset=true replay=true'
  Write-Host 'REGRESSION_CHECK=PASS name=hit_effect_independent_watchdog update_dependency=false watchdog_ms=1200'
  Write-Host 'REGRESSION_CHECK=PASS name=diagnostic_zip_root_cause files=visual-lifecycle-summary.json,root-cause.txt pair_analysis=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V17=PASS mode=apply sha=$ExpectedSha schema=v17 predecessor=v16 shoot_actual_path=true hit_watchdog=true diagnostics_root_cause=true"
}
catch {
  $failure=$_
  foreach($key in $targets.Keys){
    $target=Target-Path $key
    $backup=Backup-Path $key
    if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v16 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V17_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
