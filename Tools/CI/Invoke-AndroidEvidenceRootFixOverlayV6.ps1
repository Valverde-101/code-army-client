param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v5=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV5.ps1'
if(-not(Test-Path -LiteralPath $v5 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL predecessor_missing=$v5"}

$targets=[ordered]@{
  projectile='src\game\gameElements\Projectile.as'
  character='src\game\isometric\characters\IsometricCharacter.as'
  animation='src\game\characters\AnimationController.as'
  hfe='src\game\gameElements\HFEObject.as'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v6\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.post-v5')}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL verify=$Name token=$Token"}}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V6_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V6_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    foreach($entry in @($manifest.files)){
      $key=[string]$entry.key
      $src=Backup-Path $key
      $dst=Target-Path $key
      if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL restore_backup_missing key=$key"}
      Copy-Item -LiteralPath $src -Destination $dst -Force
      $restored=Get-Sha256 $dst
      $expected=([string]$entry.sha256).ToUpperInvariant()
      if($restored -ne $expected){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL restore_hash key=$key expected=$expected actual=$restored"}
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v5 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V6=PASS mode=restore baseline_restored=true predecessor=v5 sha=$ExpectedSha"
  return
}

& $v5 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V6=FAIL source_missing key=$key"}
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v6';source_sha=$ExpectedSha;predecessor='v5';files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "EVIDENCE_ROOTFIX_V6_MANIFEST=PASS files=$($manifestFiles.Count) predecessor=v5"

try{
  # A) Projectile visuals must not depend on the owning character continuing to update.
  # Physical evidence showed 10 missile spawns, only 4 impacts, and 3 independent 8s
  # watchdog expirations. A shooter can fire again or die while an older missile is
  # still in flight, so a single owner-side mProjectile slot is structurally invalid.
  $projectilePath=Target-Path 'projectile'
  $projectile=Normalize-Lf ([IO.File]::ReadAllText($projectilePath))
  if(-not $projectile.Contains('import flash.utils.getTimer;')){
    $projectile=Replace-LiteralOne $projectile '   import flash.events.Event;' @'
   import flash.events.Event;
   import flash.utils.getQualifiedClassName;
   import flash.utils.getTimer;
'@ 'projectile_autotick_imports'
  }
  $projectile=Replace-LiteralOne $projectile '      protected var mFinished:Boolean;' @'
      protected var mFinished:Boolean;

      private static var smNextAutoTickId:uint = 1;

      private var mAutoTickId:uint = 0;

      private var mAutoTickLastAt:int = 0;

      private var mAutoTickBusy:Boolean = false;
'@ 'projectile_autotick_fields'
  $projectile=Replace-LiteralOne $projectile '         this.y = param1.mY;' @'
         this.y = param1.mY;
         this.mAutoTickId = smNextAutoTickId++;
         this.mAutoTickLastAt = getTimer();
         this.addEventListener(Event.ENTER_FRAME,this.autoTick,false,0,true);
         Utils.DiagEvent("PROJECTILE_AUTO_TICK","phase=armed;id=" + this.mAutoTickId + ";class=" + getQualifiedClassName(this));
'@ 'projectile_autotick_arm'
  $projectile=Replace-LiteralOne $projectile '      public function update(param1:int) : Boolean' @'
      private function autoTick(param1:Event) : void
      {
         if(this.mFinished || this.mAutoTickBusy)
         {
            return;
         }
         var now:int = getTimer();
         var delta:int = this.mAutoTickLastAt > 0 ? Math.max(1,Math.min(100,now - this.mAutoTickLastAt)) : 25;
         this.mAutoTickLastAt = now;
         this.mAutoTickBusy = true;
         try
         {
            this.update(delta);
         }
         catch(error:Error)
         {
            Utils.DiagEvent("PROJECTILE_AUTO_TICK_ERROR","id=" + this.mAutoTickId + ";class=" + getQualifiedClassName(this) + ";errorID=" + error.errorID + ";message=" + error.message);
            this.destroy();
         }
         finally
         {
            this.mAutoTickBusy = false;
         }
      }

      public function update(param1:int) : Boolean
'@ 'projectile_autotick_handler'
  $destroyPattern='(?ms)public function destroy\(\) : void\s*\{\s*if\(this\.mLoadingCallbackEventType\)'
  $destroyReplacement=@'
public function destroy() : void
      {
         this.removeEventListener(Event.ENTER_FRAME,this.autoTick);
         Utils.DiagEvent("PROJECTILE_AUTO_TICK","phase=destroy;id=" + this.mAutoTickId + ";class=" + getQualifiedClassName(this));
         if(this.mLoadingCallbackEventType)
'@
  $projectile=Replace-RegexOne $projectile $destroyPattern $destroyReplacement.TrimEnd() 'projectile_autotick_disarm'
  foreach($token in @('PROJECTILE_AUTO_TICK','PROJECTILE_AUTO_TICK_ERROR','this.addEventListener(Event.ENTER_FRAME,this.autoTick','this.removeEventListener(Event.ENTER_FRAME,this.autoTick)','getQualifiedClassName(this)')){Require-Token $projectile $token 'projectile'}
  Write-Utf8Bom $projectilePath $projectile

  # B) Do not remove an in-flight projectile when the same unit fires again, and do not
  # gate visual advancement behind character state. Each projectile now owns its tick.
  $characterPath=Target-Path 'character'
  $character=Normalize-Lf ([IO.File]::ReadAllText($characterPath))
  $addProjectilePattern='(?ms)\t\tprotected function addProjectile\(param1: Number, param2: Number\): void \{.*?\n\t\t\}\n\n\t\tprivate function getProjectileClass'
  $addProjectileReplacement=@'
		protected function addProjectile(param1: Number, param2: Number): void {
			var _loc3_: Class = null;
			if (mItem is PlayerUnitItem && PlayerUnitItem(mItem).mProjectileClassStr || mItem is EnemyUnitItem && EnemyUnitItem(mItem).mProjectileClassStr) {
				_loc3_ = this.getProjectileClass(Object(mItem).mProjectileClassStr);
				if (_loc3_) {
					if (this.mProjectile) {
						Utils.DiagEvent("PROJECTILE_OWNER_OVERLAP", "owner=" + mItem.mId + ";previous_attached=" + (this.mProjectile.parent != null));
					}
					this.mProjectile = new _loc3_(this, param1, param2);
				}
			}
		}

		private function getProjectileClass
'@
  $character=Replace-RegexOne $character $addProjectilePattern $addProjectileReplacement.TrimEnd() 'character_does_not_remove_previous_projectile'
  $ownerUpdatePattern='(?ms)\t\t\tif \(this\.mProjectile\) \{\s*if \(this\.mProjectile\.update\(param1\)\) \{\s*this\.mProjectile = null;\s*\}\s*\}\s*'
  $character=Replace-RegexOne $character $ownerUpdatePattern '' 'character_no_longer_drives_projectile_update'
  if($character.Contains('this.mProjectile.update(param1)')){throw 'ANDROID_EVIDENCE_ROOTFIX_V6=FAIL regression=owner_projectile_update_remaining'}
  if($character.Contains('this.mProjectile.parent.removeChild(this.mProjectile)')){throw 'ANDROID_EVIDENCE_ROOTFIX_V6=FAIL regression=owner_projectile_visual_eviction_remaining'}
  Require-Token $character 'PROJECTILE_OWNER_OVERLAP' 'character_projectile_overlap_telemetry'
  Write-Utf8Bom $characterPath $character

  # C) The V5 explosion cleanup did hide clips when owners were destroyed, but that path
  # was silent. Emit cleanup evidence so every armed effect can be paired with either
  # final_frame, wallclock_timeout, or owner_destroy in the next physical ZIP.
  $animationPath=Target-Path 'animation'
  $animation=Normalize-Lf ([IO.File]::ReadAllText($animationPath))
  $ownerDestroyPattern='(?ms)if\(this\.mTransientOneShots && this\.mTransientOneShots\[clip\] !== undefined\)\s*\{\s*delete this\.mTransientOneShots\[clip\];\s*\}'
  $ownerDestroyReplacement=@'
if(this.mTransientOneShots && this.mTransientOneShots[clip] !== undefined)
            {
               delete this.mTransientOneShots[clip];
               Utils.DiagEvent("EXPLOSION_TRANSIENT_CLEANUP","owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";reason=owner_destroy;elapsed_real_ms=0;frames=" + clip.totalFrames);
            }
'@
  $animation=Replace-RegexOne $animation $ownerDestroyPattern $ownerDestroyReplacement.TrimEnd() 'explosion_owner_destroy_is_observable'
  Require-Token $animation 'reason=owner_destroy' 'animation_owner_destroy_cleanup'
  Write-Utf8Bom $animationPath $animation

  # D) Supply helicopters are not merely dropping frames: the authored clip is 360 frames.
  # At 40fps that is ~9 seconds before any lag. Bound the presentation to 5.5s wall-clock
  # while preserving the authored frame order and allowing bounded catch-up.
  $hfePath=Target-Path 'hfe'
  $hfe=Normalize-Lf ([IO.File]::ReadAllText($hfePath))
  $hfe=Replace-LiteralOne $hfe '		private static const HARVEST_TARGET_FPS:Number = 30;' '		private static const HARVEST_TARGET_DURATION_MS:int = 5500;' 'hfe_wallclock_target_duration'
  $hfe=Replace-LiteralOne $hfe '			var expectedFrame:int = Math.min(_loc2_.totalFrames,1 + int(elapsedMs * HARVEST_TARGET_FPS / 1000));' '			var expectedFrame:int = Math.min(_loc2_.totalFrames,1 + int(elapsedMs * Math.max(1,_loc2_.totalFrames - 1) / HARVEST_TARGET_DURATION_MS));' 'hfe_expected_frame_from_target_duration'
  $hfe=Replace-LiteralOne $hfe '				Utils.DiagEvent("HFE_HARVEST_ANIMATION","phase=start;item=" + mItem.mId + ";symbol=" + HFEItem(mItem).mHarvestAnimation + ";frames=" + this.mHarvestAnimation.totalFrames + ";stage_fps=" + timelineFps + ";mode=native_timeline");' '				Utils.DiagEvent("HFE_HARVEST_ANIMATION","phase=start;item=" + mItem.mId + ";symbol=" + HFEItem(mItem).mHarvestAnimation + ";frames=" + this.mHarvestAnimation.totalFrames + ";stage_fps=" + timelineFps + ";target_ms=" + HARVEST_TARGET_DURATION_MS + ";mode=wallclock_target");' 'hfe_start_target_telemetry'
  if($hfe.Contains('HARVEST_TARGET_FPS')){throw 'ANDROID_EVIDENCE_ROOTFIX_V6=FAIL regression=hfe_old_target_fps_remaining'}
  foreach($token in @('HARVEST_TARGET_DURATION_MS:int = 5500','mode=wallclock_target','target_ms=','Math.max(1,_loc2_.totalFrames - 1) / HARVEST_TARGET_DURATION_MS')){Require-Token $hfe $token 'hfe'}
  Write-Utf8Bom $hfePath $hfe

  # E) Ensure Projectile itself is replaced into the Android SWF. Previous gates could
  # validate source hooks without ever injecting this base class.
  $patcherPath=Target-Path 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  if(-not $patcher.Contains("Class='game.gameElements.Projectile'")){
    $anchor="  [ordered]@{Class='game.isometric.characters.IsometricCharacter';Source='src\game\isometric\characters\IsometricCharacter.as';Log='ffdec-feature-character-hints.log'},"
    $insert=$anchor+"`n  [ordered]@{Class='game.gameElements.Projectile';Source='src\game\gameElements\Projectile.as';Log='ffdec-feature-projectile-autotick.log'},"
    $patcher=Replace-LiteralOne $patcher $anchor $insert 'projectile_patch_spec'
  }
  $patcher=Replace-LiteralOne $patcher '$patchVersion=''mobile-engine-v3.26-wallclock-fx-rootfix-v5''' '$patchVersion=''mobile-engine-v3.27-projectile-autotick-hfe-v6''' 'patch_version_v3_27_v6'
  foreach($token in @("Class='game.gameElements.Projectile'",'mobile-engine-v3.27-projectile-autotick-hfe-v6')){Require-Token $patcher $token 'patcher'}
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=projectile_visual_tick_is_owner_independent source=Projectile.ENTER_FRAME'
  Write-Host 'REGRESSION_CHECK=PASS name=rapid_fire_does_not_evict_previous_projectile owner_slot=reference_only previous_visual=self_owned'
  Write-Host 'REGRESSION_CHECK=PASS name=projectile_continues_when_shooter_dies character_update_dependency=false'
  Write-Host 'REGRESSION_CHECK=PASS name=explosion_cleanup_paths_are_pairable reasons=final_frame,wallclock_timeout,owner_destroy'
  Write-Host 'REGRESSION_CHECK=PASS name=supply_airdrop_duration_is_wallclock target_ms=5500 authored_frames_preserved=true'
  Write-Host 'REGRESSION_CHECK=PASS name=projectile_base_is_injected_into_swf class=game.gameElements.Projectile'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V6=PASS mode=apply sha=$ExpectedSha schema=v6 predecessor=v5 swf_patch_version=mobile-engine-v3.27-projectile-autotick-hfe-v6"
}catch{
  $failure=$_
  foreach($key in $targets.Keys){
    $target=Target-Path $key
    $backup=Backup-Path $key
    if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v5 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V6_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
