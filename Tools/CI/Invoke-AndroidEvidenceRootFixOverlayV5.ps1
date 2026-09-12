param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v4=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV4.ps1'
if(-not(Test-Path -LiteralPath $v4 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL predecessor_missing=$v4"}

$targets=[ordered]@{
  animation='src\game\characters\AnimationController.as'
  missile='src\game\gameElements\Missile.as'
  character='src\game\isometric\characters\IsometricCharacter.as'
  enemyInstallation='src\game\gameElements\EnemyInstallationObject.as'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v5\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.post-v4')}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL verify=$Name token=$Token"}}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V5_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V5_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    foreach($entry in @($manifest.files)){
      $key=[string]$entry.key
      $src=Backup-Path $key
      $dst=Target-Path $key
      if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL restore_backup_missing key=$key"}
      Copy-Item -LiteralPath $src -Destination $dst -Force
      $restored=Get-Sha256 $dst
      $expected=([string]$entry.sha256).ToUpperInvariant()
      if($restored -ne $expected){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL restore_hash key=$key expected=$expected actual=$restored"}
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v4 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V5=PASS mode=restore baseline_restored=true predecessor=v4 sha=$ExpectedSha"
  return
}

& $v4 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V5=FAIL source_missing key=$key"}
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v5';source_sha=$ExpectedSha;predecessor='v4';files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "EVIDENCE_ROOTFIX_V5_MANIFEST=PASS files=$($manifestFiles.Count) predecessor=v4"

try{
  # A) effect_explosion is not owned only by Missile/Artillery. It is also the authored
  # death/wrecking animation for units and installations. Give the materialized one-shot
  # its own wall-clock lifecycle so a stalled owner cannot leave glowing frames forever.
  $animationPath=Target-Path 'animation'
  $animation=Normalize-Lf ([IO.File]::ReadAllText($animationPath))
  if(-not $animation.Contains('import flash.utils.Dictionary;')){
    $animation=Replace-LiteralOne $animation '   import flash.utils.getTimer;' @'
   import flash.utils.Dictionary;
   import flash.utils.getQualifiedClassName;
   import flash.utils.getTimer;
'@ 'animation_transient_imports'
  }
  $animation=Replace-LiteralOne $animation '      private var mDiagnosticsDestroyed:Boolean = false;' @'
      private var mDiagnosticsDestroyed:Boolean = false;
      private var mTransientOneShots:Dictionary = new Dictionary(true);
'@ 'animation_transient_field'
  $animation=Replace-LiteralOne $animation '               wrapper.addChild(new cls());' @'
               var instance:DisplayObject = new cls();
               wrapper.addChild(instance);
               if(symbol == "effect_explosion" && instance is MovieClip)
               {
                  var transientClip:MovieClip = instance as MovieClip;
                  transientClip.removeEventListener(Event.ENTER_FRAME,this.enterFrame);
                  transientClip.stop();
                  transientClip.gotoAndStop(1);
                  transientClip.visible = false;
                  this.mTransientOneShots[transientClip] = 0;
                  transientClip.addEventListener(Event.ENTER_FRAME,this.enterFrame,false,0,true);
                  Utils.DiagEvent("EXPLOSION_TRANSIENT_ARMED","index=" + param1 + ";owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";resource=" + resource + ";symbol=" + symbol);
               }
'@ 'effect_explosion_owned_one_shot'
  $materializedPattern='Utils\.DiagEvent\("ANIMATION_MATERIALIZED","index=" \+ param1 \+ ";resource=" \+ resource \+ ";symbol=" \+ symbol \+ ";special=" \+ this\.shouldDeferSpecialAnimation\(param1\)\);'
  $materializedReplacement='Utils.DiagEvent("ANIMATION_MATERIALIZED","index=" + param1 + ";resource=" + resource + ";symbol=" + symbol + ";special=" + this.shouldDeferSpecialAnimation(param1) + ";owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null"));'
  $animation=Replace-RegexOne $animation $materializedPattern $materializedReplacement 'animation_materialized_owner_telemetry'

  $playPattern='(?ms)(public function playCurrentAnimation\(\)\s*:\s*void\s*\{.*?while\(i < targets\.length\).*?if\(clip\)\s*\{\s*)clip\.gotoAndPlay\(1\);'
  $playReplacement=@'
$1var transientStarted:* = this.mTransientOneShots ? this.mTransientOneShots[clip] : undefined;
               if(transientStarted !== undefined)
               {
                  this.mTransientOneShots[clip] = getTimer();
                  clip.removeEventListener(Event.ENTER_FRAME,this.enterFrame);
                  clip.visible = true;
                  clip.addEventListener(Event.ENTER_FRAME,this.enterFrame,false,0,true);
                  Utils.DiagEvent("EXPLOSION_TRANSIENT_PLAY","owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";frames=" + clip.totalFrames);
               }
               clip.gotoAndPlay(1);
'@
  $animation=Replace-RegexOne $animation $playPattern $playReplacement.TrimEnd() 'effect_explosion_wallclock_start'

  $enterFramePattern='(?ms)public function enterFrame\(param1:Event\)\s*:\s*void\s*\{.*?\n\s*\}(?=\n\s*private function stopAnim)'
  $enterFrameReplacement=@'
public function enterFrame(param1:Event) : void
      {
         var clip:MovieClip = param1.target as MovieClip;
         if(!clip)
         {
            return;
         }
         var transientStarted:* = this.mTransientOneShots ? this.mTransientOneShots[clip] : undefined;
         var isTransient:Boolean = transientStarted !== undefined;
         var elapsedReal:int = isTransient && int(transientStarted) > 0 ? Math.max(0,getTimer() - int(transientStarted)) : 0;
         var reachedVisualEnd:Boolean = clip.totalFrames > 1 && clip.currentFrame >= clip.totalFrames;
         var transientTimeout:Boolean = isTransient && int(transientStarted) > 0 && elapsedReal >= 2500;
         if(reachedVisualEnd || transientTimeout)
         {
            clip.removeEventListener(Event.ENTER_FRAME,this.enterFrame);
            clip.stop();
            clip.gotoAndStop(1);
            clip.visible = false;
            if(isTransient)
            {
               delete this.mTransientOneShots[clip];
               Utils.DiagEvent("EXPLOSION_TRANSIENT_CLEANUP","owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";reason=" + (reachedVisualEnd ? "final_frame" : "wallclock_timeout") + ";elapsed_real_ms=" + elapsedReal + ";frames=" + clip.totalFrames);
            }
            else
            {
               Utils.DiagEvent("ANIMATION_TRANSIENT_CLEANUP","frames=" + clip.totalFrames + ";reason=shoot_complete");
            }
         }
      }
'@
  $animation=Replace-RegexOne $animation $enterFramePattern $enterFrameReplacement.TrimEnd() 'effect_explosion_wallclock_cleanup'

  $stopAnimPattern='(?ms)private function stopAnim\(param1:DisplayObject, param2:Array\)\s*:\s*void\s*\{.*?\n\s*\}(?=\n\s*public function destroy)'
  $stopAnimReplacement=@'
private function stopAnim(param1:DisplayObject, param2:Array) : void
      {
         if(param1 is MovieClip)
         {
            var clip:MovieClip = param1 as MovieClip;
            clip.removeEventListener(Event.ENTER_FRAME,this.enterFrame);
            if(this.mTransientOneShots && this.mTransientOneShots[clip] !== undefined)
            {
               delete this.mTransientOneShots[clip];
            }
            clip.gotoAndStop(1);
            clip.visible = false;
         }
      }
'@
  $animation=Replace-RegexOne $animation $stopAnimPattern $stopAnimReplacement.TrimEnd() 'effect_explosion_destroy_cleanup'
  $animation=Replace-LiteralOne $animation '         this.mAnimations = null;' @'
         this.mTransientOneShots = null;
         this.mAnimations = null;
'@ 'effect_explosion_dictionary_release'
  foreach($token in @('EXPLOSION_TRANSIENT_ARMED','EXPLOSION_TRANSIENT_PLAY','EXPLOSION_TRANSIENT_CLEANUP','elapsedReal >= 2500','mTransientOneShots:Dictionary',';owner=')){Require-Token $animation $token 'animation'}
  Write-Utf8Bom $animationPath $animation

  # B) Missile interpolation used param1, but physical evidence shows ~1.1-1.5s of
  # logical time over ~8s wall time. Drive segment interpolation from getTimer().
  $missilePath=Target-Path 'missile'
  $missile=Normalize-Lf ([IO.File]::ReadAllText($missilePath))
  $missile=Replace-LiteralOne $missile '      private var mSpawnTimer:int = 0;' @'
      private var mSpawnTimer:int = 0;
      private var mSegmentStartedAt:int = 0;
'@ 'missile_wallclock_segment_field'
  $missile=Replace-LiteralOne $missile '         this.mSpawnTimer = getTimer();' @'
         this.mSpawnTimer = getTimer();
         this.mSegmentStartedAt = this.mSpawnTimer;
'@ 'missile_wallclock_segment_arm'
  $missile=Replace-LiteralOne $missile '         this.mLifetimeMs += param1;' @'
         var wallNow:int = getTimer();
         this.mLifetimeMs = this.mSpawnTimer > 0 ? Math.max(0,wallNow - this.mSpawnTimer) : this.mLifetimeMs + param1;
'@ 'missile_lifetime_uses_wallclock'
  $missile=Replace-LiteralOne $missile '         this.mElapsedTime += param1;' @'
         if(this.mSegmentStartedAt <= 0)
         {
            this.mSegmentStartedAt = wallNow;
         }
         this.mElapsedTime = Math.max(0,wallNow - this.mSegmentStartedAt);
'@ 'missile_visual_progress_uses_wallclock'
  $missile=Replace-LiteralOne $missile '            this.mElapsedTime = 0;' @'
            this.mElapsedTime = 0;
            this.mSegmentStartedAt = wallNow;
'@ 'missile_wallclock_segment_reset'
  foreach($token in @('mSegmentStartedAt:int','var wallNow:int = getTimer();','this.mElapsedTime = Math.max(0,wallNow - this.mSegmentStartedAt)','this.mSegmentStartedAt = wallNow;')){Require-Token $missile $token 'missile'}
  if($missile.Contains('this.mElapsedTime += param1;')){throw 'ANDROID_EVIDENCE_ROOTFIX_V5=FAIL regression=missile_logic_delta_progress_remaining'}
  Write-Utf8Bom $missilePath $missile

  # C) Character death owns CHARACTER_ANIMATION_DYING (index 5), which often resolves
  # to effect_explosion. Bound owner state with wall clock and hide the animation at cleanup.
  $characterPath=Target-Path 'character'
  $character=Normalize-Lf ([IO.File]::ReadAllText($characterPath))
  if(-not $character.Contains('import flash.utils.getTimer;')){
    $character=Replace-LiteralOne $character "`timport flash.geom.Point;" @'
	import flash.geom.Point;
	import flash.utils.getTimer;
'@ 'character_wallclock_import'
  }
  $characterFieldPattern='(?m)^([ \t]*)private var mSafetyTimer:\s*int;\s*$'
  $characterFieldReplacement='$1private var mSafetyTimer: int;' + "`n" + '$1private var mDyingStartedAt: int = 0;'
  $character=Replace-RegexOne $character $characterFieldPattern $characterFieldReplacement 'character_dying_wallclock_field'
  $diePattern='(?ms)(public function die\(\):\s*void\s*\{.*?this\.mSafetyTimer\s*=\s*0;)(\s*hideLoadingBar\(\);)'
  $dieReplacement='$1' + "`n`t`t`t" + 'this.mDyingStartedAt = getTimer();' + '$2'
  $character=Replace-RegexOne $character $diePattern $dieReplacement 'character_dying_wallclock_arm'
  $dyingPattern='(?ms)public function updateDying\(param1:\s*int\):\s*void\s*\{.*?\n\s*\}(?=\n\s*public function isInOpponentsTile)'
  $dyingReplacement=@'
public function updateDying(param1: int): void {
			this.mSafetyTimer += param1;
			var dyingLabel: String = getCurrentAnimationFrameLabel();
			var dyingLimit: int = Math.max(500, GameState.mConfig.GraphicSetup.Explosion.Length);
			var dyingElapsedReal: int = this.mDyingStartedAt > 0 ? Math.max(0, getTimer() - this.mDyingStartedAt) : this.mSafetyTimer;
			if (dyingLabel == "end" || dyingElapsedReal >= dyingLimit) {
				if (mAnimationController) {
					mAnimationController.stopCurrentAnimation();
					var dyingAnimation: MovieClip = mAnimationController.getCurrentAnimation();
					if (dyingAnimation) {
						dyingAnimation.visible = false;
					}
				}
				Utils.DiagEvent("CHARACTER_DYING_CLEANUP", "reason=" + (dyingLabel == "end" ? "end_label" : "wallclock_timeout") + ";elapsed_real_ms=" + dyingElapsedReal + ";elapsed_logic_ms=" + this.mSafetyTimer + ";limit_ms=" + dyingLimit);
				this.mState = STATE_KILLED;
				this.mSafetyTimer = 0;
				this.mDyingStartedAt = 0;
			}
		}
'@
  $character=Replace-RegexOne $character $dyingPattern $dyingReplacement.TrimEnd() 'character_dying_wallclock_cleanup'
  foreach($token in @('mDyingStartedAt: int','dyingElapsedReal','CHARACTER_DYING_CLEANUP','elapsed_logic_ms=')){Require-Token $character $token 'character'}
  Write-Utf8Bom $characterPath $character

  # D) Enemy installation wrecking had a bounded timer, but it also accumulated param1.
  # Convert the bound to wall clock and hide its index-3 effect immediately at cleanup.
  $enemyPath=Target-Path 'enemyInstallation'
  $enemy=Normalize-Lf ([IO.File]::ReadAllText($enemyPath))
  if(-not $enemy.Contains('import flash.utils.getTimer;')){
    $enemy=Replace-LiteralOne $enemy '   import flash.events.MouseEvent;' @'
   import flash.events.MouseEvent;
   import flash.utils.getTimer;
'@ 'installation_wallclock_import'
  }
  $enemy=Replace-LiteralOne $enemy '      private var mWreckingSafetyTimer:int = 0;' @'
      private var mWreckingSafetyTimer:int = 0;
      private var mWreckingStartedAt:int = 0;
'@ 'installation_wallclock_field'
  $wreckLogicPattern='(?ms)case STATE_WRECKING:\s*this\.mWreckingSafetyTimer \+= param1;.*?this\.mNewState = STATE_DESTROYED;\s*\}\s*break;'
  $wreckLogicReplacement=@'
case STATE_WRECKING:
               this.mWreckingSafetyTimer += param1;
               var wreckLabel:String = getCurrentAnimationFrameLabel();
               var wreckLimit:int = Math.max(500,GameState.mConfig.GraphicSetup.Explosion.Length + 250);
               var wreckElapsedReal:int = this.mWreckingStartedAt > 0 ? Math.max(0,getTimer() - this.mWreckingStartedAt) : this.mWreckingSafetyTimer;
               if(wreckLabel == "end" || wreckElapsedReal >= wreckLimit)
               {
                  if(mAnimationController)
                  {
                     mAnimationController.stopCurrentAnimation();
                     var wreckAnimation:MovieClip = mAnimationController.getCurrentAnimation();
                     if(wreckAnimation)
                     {
                        wreckAnimation.visible = false;
                     }
                  }
                  if(wreckElapsedReal >= wreckLimit && wreckLabel != "end")
                  {
                     Utils.DiagEvent("INSTALLATION_WRECKING_TIMEOUT","item=" + mItem.mId + ";elapsed_real_ms=" + wreckElapsedReal + ";elapsed_logic_ms=" + this.mWreckingSafetyTimer + ";limit_ms=" + wreckLimit + ";animation=" + mAnimationController.getCurrentAnimationIndex());
                  }
                  Utils.DiagEvent("INSTALLATION_WRECKING_CLEANUP","item=" + mItem.mId + ";reason=" + (wreckLabel == "end" ? "end_label" : "wallclock_timeout") + ";elapsed_real_ms=" + wreckElapsedReal + ";elapsed_logic_ms=" + this.mWreckingSafetyTimer);
                  this.mWreckingSafetyTimer = 0;
                  this.mWreckingStartedAt = 0;
                  this.mNewState = STATE_DESTROYED;
               }
               break;
'@
  $enemy=Replace-RegexOne $enemy $wreckLogicPattern $wreckLogicReplacement.TrimEnd() 'installation_wrecking_wallclock_cleanup'
  $wreckArmPattern='(?ms)(case STATE_WRECKING:\s*)this\.mWreckingSafetyTimer = 0;'
  $wreckArmReplacement='$1this.mWreckingSafetyTimer = 0;' + "`n               " + 'this.mWreckingStartedAt = getTimer();'
  $enemy=Replace-RegexOne $enemy $wreckArmPattern $wreckArmReplacement 'installation_wrecking_wallclock_arm'
  foreach($token in @('mWreckingStartedAt:int','wreckElapsedReal','elapsed_real_ms=','elapsed_logic_ms=','this.mWreckingStartedAt = getTimer();')){Require-Token $enemy $token 'installation'}
  Write-Utf8Bom $enemyPath $enemy

  # E) Make the exact runtime patch provenance distinguishable from v3.25/v4.
  $patcherPath=Target-Path 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patcher=Replace-LiteralOne $patcher '$patchVersion=''mobile-engine-v3.25-evidence-rootfix-v3''' '$patchVersion=''mobile-engine-v3.26-wallclock-fx-rootfix-v5''' 'patch_version_v3_26_v5'
  Require-Token $patcher 'mobile-engine-v3.26-wallclock-fx-rootfix-v5' 'patcher'
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=effect_explosion_one_shot_has_wallclock_cleanup timeout_ms=2500 owner_telemetry=true'
  Write-Host 'REGRESSION_CHECK=PASS name=effect_explosion_materialization_reports_owner event=ANIMATION_MATERIALIZED'
  Write-Host 'REGRESSION_CHECK=PASS name=missile_visual_progress_is_wallclock authored_duration_ms=1500 logical_delta_independent=true'
  Write-Host 'REGRESSION_CHECK=PASS name=character_dying_cleanup_is_wallclock visual_hidden_on_cleanup=true'
  Write-Host 'REGRESSION_CHECK=PASS name=installation_wrecking_cleanup_is_wallclock visual_hidden_on_cleanup=true'
  Write-Host 'REGRESSION_CHECK=PASS name=runtime_timebase_drift_is_observable fields=elapsed_real_ms,elapsed_logic_ms'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V5=PASS mode=apply sha=$ExpectedSha schema=v5 predecessor=v4 swf_patch_version=mobile-engine-v3.26-wallclock-fx-rootfix-v5"
}catch{
  $failure=$_
  foreach($key in $targets.Keys){
    $target=Target-Path $key
    $backup=Backup-Path $key
    if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v4 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V5_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
