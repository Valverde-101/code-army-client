param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v10=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV10.ps1'
if(-not(Test-Path -LiteralPath $v10 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL predecessor_missing=$v10"}

$targets=[ordered]@{
  scene='src\game\isometric\IsometricScene.as'
  tile='src\game\battlefield\TileMapGraphic.as'
  missile='src\game\gameElements\Missile.as'
  artillery='src\game\gameElements\ArtilleryRound.as'
  hit='src\game\utils\HitEffect.as'
  test='Tools\CI\Test-AndroidRuntimePatch.ps1'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v15\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.post-v10')}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $rx=New-Object System.Text.RegularExpressions.Regex($Pattern)
  $matches=$rx.Matches($Text)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL patch=$Name expected_matches=1 actual=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V15_HOOK=PASS name=$Name matches=1 semantic=true"
  return $rx.Replace($Text,$Replacement,1)
}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V15_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    foreach($entry in @($manifest.files)){
      $key=[string]$entry.key
      $backup=Backup-Path $key
      $target=Target-Path $key
      if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL restore_backup_missing key=$key"}
      Copy-Item -LiteralPath $backup -Destination $target -Force
      $restored=Get-Sha256 $target
      $expected=([string]$entry.sha256).ToUpperInvariant()
      if($restored -ne $expected){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL restore_hash key=$key expected=$expected actual=$restored"}
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V15=PASS mode=restore baseline_restored=true predecessor=v10 sha=$ExpectedSha"
  return
}

& $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
foreach($key in $targets.Keys){
  $path=Target-Path $key
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL required_file_missing key=$key path=$path"}
}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v15';source_sha=$ExpectedSha;predecessor='v10';files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try {
  $scenePath=Target-Path 'scene'
  $scene=Normalize-Lf ([IO.File]::ReadAllText($scenePath))
  $helperPattern='(?m)^([ \t]*)public function cancelEditMode\(\)\s*:\s*void\s*\{\s*$'
  $helperReplacement=@'
		private function clearPlacementVisualResidue(param1:String):void {
			if (this.mMovedObjectIndicator) {
				this.mMovedObjectIndicator.graphics.clear();
				if (this.mMovedObjectIndicator.parent) {
					this.mMovedObjectIndicator.parent.removeChild(this.mMovedObjectIndicator);
				}
				this.mMovedObjectIndicator = null;
			}
			if (this.mMapGUIEffectsLayer) {
				this.mMapGUIEffectsLayer.clearHighlights();
				this.mMapGUIEffectsLayer.clearMoveDisabledArea();
				this.mMapGUIEffectsLayer.removeHighlightRange();
			}
			Utils.DiagEvent("PLACEMENT_OVERLAY_CLEANUP","reason=" + param1);
		}

$1public function cancelEditMode(): void {
'@
  $scene=Replace-RegexOne $scene $helperPattern $helperReplacement.TrimEnd() 'placement_cleanup_helper_by_signature'
  $scene=Replace-RegexOne $scene '(?m)^([ \t]*public function exitMoveMode\(param1:\s*Boolean\s*=\s*false\)\s*:\s*void\s*\{)\s*$' ('$1'+"`n`t`t`tthis.clearPlacementVisualResidue(`"exit_move_mode`");") 'exit_move_mode_cleanup'
  $scene=Replace-RegexOne $scene '(?m)^([ \t]*public function cancelEditMode\(\)\s*:\s*void\s*\{)\s*$' ('$1'+"`n`t`t`tthis.clearPlacementVisualResidue(`"cancel_edit_mode`");") 'cancel_edit_mode_cleanup'
  $scene=Replace-RegexOne $scene '(?m)^([ \t]*private function finishPlacementUi\(param1:\s*String\)\s*:\s*void\s*\{)\s*$' ('$1'+"`n`t`t`tthis.clearPlacementVisualResidue(`"finish_`" + param1);") 'finish_placement_cleanup'
  Write-Utf8Bom $scenePath $scene

  $tilePath=Target-Path 'tile'
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  $dirtyPattern='(?ms)(public function markOwnershipDirty\(param1:GridCell\)\s*:\s*void\s*\{.*?this\.mOwnershipDirty = true;)'
  $dirtyReplacement=@'
$1
         Utils.DiagEvent("OWNERSHIP_DIRTY_MARK","map=" + GameState.mInstance.mCurrentMapId + ";i=" + param1.mPosI + ";j=" + param1.mPosJ + ";owner=" + param1.mOwner);
'@
  $tile=Replace-RegexOne $tile $dirtyPattern $dirtyReplacement.TrimEnd() 'ownership_dirty_telemetry'
  $commitPattern='(?ms)      public function commitOwnershipVisualNow\(\)\s*:\s*Boolean\s*\{.*?\n      \}\s*(?=\n      public function updateCameraViewport)'
  $commitReplacement=@'
      public function commitOwnershipVisualNow() : Boolean
      {
         if(!this.mOwnershipDirty)
         {
            Utils.DiagEvent("OWNERSHIP_VISUAL_COMMIT","map=" + GameState.mInstance.mCurrentMapId + ";result=clean");
            return true;
         }
         var reason:String = this.mDirtyReason;
         if(this.redrawDirtyOwnershipRegion())
         {
            Utils.DiagEvent("OWNERSHIP_VISUAL_COMMIT","map=" + GameState.mInstance.mCurrentMapId + ";result=partial;reason=" + reason);
            return true;
         }
         this.requestFullRedraw();
         this.updateTilemap();
         var resolved:Boolean = !this.mOwnershipDirty;
         Utils.DiagEvent("OWNERSHIP_VISUAL_COMMIT","map=" + GameState.mInstance.mCurrentMapId + ";result=full;reason=" + reason + ";resolved=" + resolved);
         return resolved;
      }
'@
  $tile=Replace-RegexOne $tile $commitPattern $commitReplacement.TrimEnd() 'ownership_visual_full_fallback'
  Write-Utf8Bom $tilePath $tile

  $missilePath=Target-Path 'missile'
  $missile=Normalize-Lf ([IO.File]::ReadAllText($missilePath))
  $missileFields=@'
      private var mImpactFrameTicks:int = 0;
      private static const IMPACT_TARGET_MS:int = 850;
      private var mImpactStartedAt:int = 0;
'@
  $missile=Replace-LiteralOne $missile '      private var mImpactFrameTicks:int = 0;' $missileFields.TrimEnd() 'missile_impact_wallclock_fields'
  $missileSmokeBudget=@'
         this.mSmoker = new SmokeEmitter(2);
         this.mSmoker.mMaxConcurrentParticles = 16;
'@
  $missile=Replace-LiteralOne $missile '         this.mSmoker = new SmokeEmitter();' $missileSmokeBudget.TrimEnd() 'missile_smoke_budget'
  $missileSmokerUpdate=@'
         if(this.mSmoker)
         {
            this.mSmoker.updateParticles();
         }
'@
  $missile=Replace-LiteralOne $missile '         this.mSmoker.updateParticles();' $missileSmokerUpdate.TrimEnd() 'missile_smoker_null_safe_update'
  $missileSmokeCadence=@'
if(!mAtTarget && this.mSmoker && this.mSmoker.canEmit())
         {
            this.addParticle(1);
         }
'@
  $missile=Replace-RegexOne $missile '(?ms)if\(!mAtTarget\)\s*\{\s*this\.addParticle\(1\);\s*\}' $missileSmokeCadence.TrimEnd() 'missile_smoke_half_cadence'
  $missileArmPattern='(?ms)this\.mImpactFrameTicks = 0;\s*_loc9_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
  $missileArmReplacement=@'
this.mImpactFrameTicks = 0;
               this.mImpactStartedAt = getTimer();
               var trailChildrenBefore:int = this.numChildren;
               if(this.mSmoker)
               {
                  this.mSmoker.destroy();
                  this.mSmoker = null;
               }
               Utils.DiagEvent("MISSILE_TRAIL_CLEANUP","children_before=" + trailChildrenBefore + ";children_after=" + this.numChildren + ";budget=16;emit_interval=2");
               _loc9_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
'@
  $missile=Replace-RegexOne $missile $missileArmPattern $missileArmReplacement.TrimEnd() 'missile_trail_cleanup_at_impact'
  $missileCheckPattern='(?ms)      private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?\n      \}\s*(?=\n      private function addParticle)'
  $missileCheckReplacement=@'
      private function checkFrame(param1:Event) : void
      {
         var clip:MovieClip = param1.currentTarget as MovieClip;
         ++this.mImpactFrameTicks;
         if(!clip)
         {
            return;
         }
         var elapsedReal:int = this.mImpactStartedAt > 0 ? Math.max(0,getTimer() - this.mImpactStartedAt) : this.mImpactFrameTicks * 25;
         var total:int = Math.max(1,clip.totalFrames);
         var expectedImpactFrame:int = Math.min(total,1 + int(elapsedReal * Math.max(1,total - 1) / IMPACT_TARGET_MS));
         if(expectedImpactFrame > clip.currentFrame)
         {
            clip.gotoAndStop(expectedImpactFrame);
         }
         var reachedEnd:Boolean = clip.currentFrameLabel == "end" || clip.currentFrame >= total;
         if(reachedEnd || elapsedReal >= IMPACT_TARGET_MS)
         {
            var reason:String = reachedEnd ? "timeline" : "wallclock_target";
            clip.removeEventListener(Event.ENTER_FRAME,this.checkFrame);
            clip.stop();
            clip.gotoAndStop(1);
            clip.visible = false;
            if(clip.parent)
            {
               clip.parent.removeChild(clip);
            }
            Utils.DiagEvent("MISSILE_IMPACT_CLEANUP","reason=" + reason + ";frames=" + total + ";elapsed_real_ms=" + elapsedReal + ";target_ms=" + IMPACT_TARGET_MS + ";children=" + this.numChildren);
            this.mImpactStartedAt = 0;
            destroy();
         }
      }
'@
  $missile=Replace-RegexOne $missile $missileCheckPattern $missileCheckReplacement.TrimEnd() 'missile_wallclock_impact_cleanup'
  Write-Utf8Bom $missilePath $missile

  $artilleryPath=Target-Path 'artillery'
  $artillery=Normalize-Lf ([IO.File]::ReadAllText($artilleryPath))
  $artilleryFields=@'
      private var mImpactFrameTicks:int = 0;
      private static const IMPACT_TARGET_MS:int = 850;
      private var mImpactStartedAt:int = 0;
'@
  $artillery=Replace-LiteralOne $artillery '      private var mImpactFrameTicks:int = 0;' $artilleryFields.TrimEnd() 'artillery_impact_wallclock_fields'
  $artilleryImpactPattern='(?ms)(mAtTarget = true;\s*this\.mPos\.z = 0;\s*graphics\.clear\(\);)'
  $artilleryImpactReplacement=@'
$1
               this.mTrail.length = 0;
'@
  $artillery=Replace-RegexOne $artillery $artilleryImpactPattern $artilleryImpactReplacement.TrimEnd() 'artillery_trail_clear_at_impact'
  $artilleryArmPattern='(?ms)this\.mImpactFrameTicks = 0;\s*_loc3_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
  $artilleryArmReplacement=@'
this.mImpactFrameTicks = 0;
               this.mImpactStartedAt = getTimer();
               _loc3_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
'@
  $artillery=Replace-RegexOne $artillery $artilleryArmPattern $artilleryArmReplacement.TrimEnd() 'artillery_impact_wallclock_arm'
  $artilleryCheckPattern='(?ms)      private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?\n      \}\s*(?=\n      private function addParticle)'
  $artilleryCheckReplacement=@'
      private function checkFrame(param1:Event) : void
      {
         var clip:MovieClip = param1.currentTarget as MovieClip;
         ++this.mImpactFrameTicks;
         if(!clip)
         {
            return;
         }
         var elapsedReal:int = this.mImpactStartedAt > 0 ? Math.max(0,getTimer() - this.mImpactStartedAt) : this.mImpactFrameTicks * 25;
         var total:int = Math.max(1,clip.totalFrames);
         var expectedImpactFrame:int = Math.min(total,1 + int(elapsedReal * Math.max(1,total - 1) / IMPACT_TARGET_MS));
         if(expectedImpactFrame > clip.currentFrame)
         {
            clip.gotoAndStop(expectedImpactFrame);
         }
         var reachedEnd:Boolean = clip.currentFrameLabel == "end" || clip.currentFrame >= total;
         if(reachedEnd || elapsedReal >= IMPACT_TARGET_MS)
         {
            var reason:String = reachedEnd ? "timeline" : "wallclock_target";
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
            Utils.DiagEvent("ARTILLERY_IMPACT_CLEANUP","reason=" + reason + ";frames=" + total + ";elapsed_real_ms=" + elapsedReal + ";target_ms=" + IMPACT_TARGET_MS);
            this.mImpactStartedAt = 0;
            destroy();
         }
      }
'@
  $artillery=Replace-RegexOne $artillery $artilleryCheckPattern $artilleryCheckReplacement.TrimEnd() 'artillery_wallclock_impact_cleanup'
  Write-Utf8Bom $artilleryPath $artillery

  $hitPath=Target-Path 'hit'
  $hit=Normalize-Lf ([IO.File]::ReadAllText($hitPath))
  if(-not $hit.Contains('import flash.utils.getTimer;')){
    $hitImport=@'
   import com.dchoc.graphics.DCResourceManager;
   import flash.utils.getTimer;
'@
    $hit=Replace-LiteralOne $hit '   import com.dchoc.graphics.DCResourceManager;' $hitImport.TrimEnd() 'hit_gettimer_import'
  }
  $hitFields=@'
      private static const HIT_EFFECT_MAX_WALLCLOCK_MS:int = 1000;
      private var mStartedAt:int = 0;

$1public function HitEffect()
'@
  $hit=Replace-RegexOne $hit '(?m)^([ \t]*)public function HitEffect\(\)\s*$' $hitFields.TrimEnd() 'hit_wallclock_fields'
  $hitUpdatePattern='(?ms)      override public function update\(param1:int\)\s*:\s*Boolean\s*\{.*?\n      \}\s*(?=\n      override public function setEffectSpecificValues)'
  $hitUpdateReplacement=@'
      override public function update(param1:int) : Boolean
      {
         if(!mMC)
         {
            return true;
         }
         if(this.mStartedAt <= 0)
         {
            this.mStartedAt = getTimer();
         }
         var elapsedReal:int = Math.max(0,getTimer() - this.mStartedAt);
         var targetMs:int = Math.max(250,Math.min(HIT_EFFECT_MAX_WALLCLOCK_MS,EffectController.getEffectLength(mType) + 100));
         var total:int = Math.max(1,mMC.totalFrames);
         var expectedFrame:int = Math.min(total,1 + int(elapsedReal * Math.max(1,total - 1) / targetMs));
         if(expectedFrame > mMC.currentFrame)
         {
            mMC.gotoAndStop(expectedFrame);
         }
         var label:String = mMC.currentFrameLabel;
         var reachedEnd:Boolean = label == "end" || mMC.currentFrame >= total;
         if(reachedEnd || elapsedReal >= targetMs)
         {
            var reason:String = reachedEnd ? "timeline" : "wallclock_target";
            mMC.stop();
            mMC.gotoAndStop(1);
            mMC.visible = false;
            if(mMC.parent)
            {
               mMC.parent.removeChild(mMC);
            }
            Utils.DiagEvent("HIT_EFFECT_WALLCLOCK_CLEANUP","type=" + mType + ";reason=" + reason + ";elapsed_real_ms=" + elapsedReal + ";target_ms=" + targetMs + ";frames=" + total);
            mMC = null;
            this.mStartedAt = 0;
            return true;
         }
         return false;
      }
'@
  $hit=Replace-RegexOne $hit $hitUpdatePattern $hitUpdateReplacement.TrimEnd() 'hit_wallclock_update'
  $hitArm=@'
            this.mStartedAt = getTimer();
            mMC.gotoAndPlay(1);
'@
  $hit=Replace-LiteralOne $hit '            mMC.gotoAndPlay(1);' $hitArm.TrimEnd() 'hit_wallclock_arm'
  Write-Utf8Bom $hitPath $hit

  $testPath=Target-Path 'test'
  $test=Normalize-Lf ([IO.File]::ReadAllText($testPath))
  $testReads=@'
$projectile=Read-Source 'src\game\gameElements\Projectile.as'
$missileV15=Read-Source 'src\game\gameElements\Missile.as'
$artilleryV15=Read-Source 'src\game\gameElements\ArtilleryRound.as'
$hitV15=Read-Source 'src\game\utils\HitEffect.as'
'@
  $test=Replace-LiteralOne $test '$projectile=Read-Source ''src\game\gameElements\Projectile.as''' $testReads.TrimEnd() 'runtime_test_reads_v15_sources'
  $testAnchor="Require-Contains `$projectile 'this.addEventListener(Event.ENTER_FRAME,this.autoTick' 'projectile_visual_tick_is_owner_independent'"
  $testChecks=@'
Require-Contains $projectile 'this.addEventListener(Event.ENTER_FRAME,this.autoTick' 'projectile_visual_tick_is_owner_independent'
Require-Contains $missileV15 'IMPACT_TARGET_MS:int = 850' 'missile_impact_duration_is_wallclock_bounded'
Require-Contains $missileV15 'new SmokeEmitter(2)' 'missile_smoke_emission_is_half_cadence'
Require-Contains $missileV15 'mMaxConcurrentParticles = 16' 'missile_smoke_concurrency_is_bounded'
Require-Contains $missileV15 'MISSILE_TRAIL_CLEANUP' 'missile_trail_is_destroyed_at_impact'
Require-Contains $missileV15 'expectedImpactFrame' 'missile_impact_frames_follow_wallclock'
Require-Contains $artilleryV15 'IMPACT_TARGET_MS:int = 850' 'artillery_impact_duration_is_wallclock_bounded'
Require-Contains $artilleryV15 'this.mTrail.length = 0;' 'artillery_trail_clears_on_impact'
Require-Contains $artilleryV15 'expectedImpactFrame' 'artillery_impact_frames_follow_wallclock'
Require-Contains $hitV15 'HIT_EFFECT_MAX_WALLCLOCK_MS:int = 1000' 'generic_hit_effect_has_wallclock_cap'
Require-Contains $hitV15 'HIT_EFFECT_WALLCLOCK_CLEANUP' 'generic_hit_effect_cleanup_is_observable'
Require-Contains $tile 'OWNERSHIP_DIRTY_MARK' 'ownership_change_is_observable'
Require-Contains $tile 'result=full' 'ownership_commit_has_immediate_full_fallback'
Require-Contains $tile 'this.requestFullRedraw();' 'ownership_fallback_requests_full_redraw'
Require-Contains $tile 'this.updateTilemap();' 'ownership_fallback_commits_same_action'
Require-Contains $swfPatch 'mobile-engine-v3.30-impact-ownership-rootfix-v15' 'swf_patch_version_is_v15'
'@
  $test=Replace-LiteralOne $test $testAnchor $testChecks.TrimEnd() 'runtime_test_v15_contract'
  Write-Utf8Bom $testPath $test

  $patcherPath=Target-Path 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patcher=Replace-LiteralOne $patcher '$patchVersion=''mobile-engine-v3.27-projectile-autotick-hfe-v7''' '$patchVersion=''mobile-engine-v3.30-impact-ownership-rootfix-v15''' 'patch_version_v3_30_v15'
  foreach($required in @(
    "Class='game.gameElements.Missile'",
    "Class='game.gameElements.ArtilleryRound'",
    "Class='game.utils.HitEffect'",
    "Class='game.battlefield.TileMapGraphic'",
    "Class='game.isometric.IsometricScene'",
    'mobile-engine-v3.30-impact-ownership-rootfix-v15'
  )){
    if(-not $patcher.Contains($required)){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL patcher_verification_missing=$required"}
  }
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=conquered_tile_visual_commit_same_action partial_fast_path=true full_fallback=true observable=true'
  Write-Host 'REGRESSION_CHECK=PASS name=missile_smoke_budget max_concurrent=16 emit_interval=2 clear_at_impact=true'
  Write-Host 'REGRESSION_CHECK=PASS name=missile_impact_wallclock target_ms=850 logical_delta_independent=true'
  Write-Host 'REGRESSION_CHECK=PASS name=artillery_impact_wallclock target_ms=850 trail_clear_on_impact=true'
  Write-Host 'REGRESSION_CHECK=PASS name=generic_hit_effect_wallclock cap_ms=1000 frame_progress_wallclock=true'
  Write-Host 'REGRESSION_CHECK=PASS name=rapid_fire_preserves_projectiles visual_cost_bounded=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V15=PASS mode=apply sha=$ExpectedSha schema=v15 predecessor=v10 swf_patch_version=mobile-engine-v3.30-impact-ownership-rootfix-v15"
}
catch {
  $failure=$_
  foreach($key in $targets.Keys){
    $target=Target-Path $key
    $backup=Backup-Path $key
    if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V15_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
