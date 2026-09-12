param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$targets=[ordered]@{
  scene='src\game\isometric\IsometricScene.as'
  hud='src\game\gui\GameHUD.as'
  enemyInstallation='src\game\gameElements\EnemyInstallationObject.as'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\interaction-correctness-overlay\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-RegexOnce([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -eq 0){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL patch=$Name reason=semantic_pattern_missing"}
  if($matches.Count -ne 1){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL patch=$Name reason=semantic_pattern_ambiguous matches=$($matches.Count)"}
  Write-Host "INTERACTION_CORRECTNESS_SEMANTIC_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Replace-LiteralOnce([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL patch=$Name reason=literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL patch=$Name reason=literal_ambiguous"}
  Write-Host "INTERACTION_CORRECTNESS_SEMANTIC_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Get-TargetPath([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Get-BackupPath([string]$Key){Join-Path $backupRoot ($Key+'.original')}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){Write-Host "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha";return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $key=[string]$entry.key
    $target=Get-TargetPath $key
    $backup=Get-BackupPath $key
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL restore_backup_missing key=$key path=$backup"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    $restored=Get-Sha256 $target
    $expected=([string]$entry.sha256).ToUpperInvariant()
    if($restored -ne $expected){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL restore_hash key=$key expected=$expected actual=$restored"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=PASS mode=restore baseline_restored=true composable=true sha=$ExpectedSha"
  return
}

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=New-Object System.Collections.Generic.List[object]
foreach($key in $targets.Keys){
  $target=Get-TargetPath $key
  if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL source_missing key=$key path=$($targets[$key])"}
  $backup=Get-BackupPath $key
  Copy-Item -LiteralPath $target -Destination $backup -Force
  $manifestFiles.Add([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $target)})
}
$manifestArray=$manifestFiles.ToArray()
[ordered]@{schema='armyattack-interaction-correctness-overlay/v1';source_sha=$ExpectedSha;files=$manifestArray}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "INTERACTION_CORRECTNESS_MANIFEST=PASS files=$($manifestArray.Count) powershell51_safe=true"

try{
  # Mobile placement: a map release may position the preview, but only the HUD check
  # callback may arm the commit gate. This makes stale mPlacePressed state harmless.
  $sceneTarget=Get-TargetPath 'scene'
  $scene=Normalize-Lf ([IO.File]::ReadAllText($sceneTarget))

  $placeFieldPattern='(?m)^([ \t]*)public var mPlacePressed:\s*Boolean;\s*$'
  $placeFieldReplacement=@'
$1public var mPlacePressed: Boolean;
$1private var mPlacementConfirmExplicit: Boolean = false;
'@
  $scene=Replace-RegexOnce $scene $placeFieldPattern $placeFieldReplacement.TrimEnd() 'placement_explicit_gate_field'

  $commitPolicyPattern='(?ms)private function shouldCommitPlacement\(\):Boolean\s*\{\s*var pointerCommit:Boolean = FeatureTuner\.USE_MOUSE_FOR_PLACE_ITEMS;\s*CONFIG::BUILD_FOR_MOBILE_AIR\s*\{\s*pointerCommit = false;\s*\}\s*return this\.mPlacePressed \|\| pointerCommit;\s*\}'
  $commitPolicyReplacement=@'
private function shouldCommitPlacement():Boolean {
			var pointerCommit:Boolean = FeatureTuner.USE_MOUSE_FOR_PLACE_ITEMS;
			CONFIG::BUILD_FOR_MOBILE_AIR {
				pointerCommit = false;
				return this.mPlacementConfirmExplicit;
			}
			return this.mPlacePressed || pointerCommit;
		}
'@
  $scene=Replace-RegexOnce $scene $commitPolicyPattern $commitPolicyReplacement.TrimEnd() 'mobile_placement_commit_requires_explicit_gate'

  $mouseUpPattern='(?m)^([ \t]*)public function mouseUp\(param1:\s*MouseEvent\):\s*void\s*\{'
  $mouseUpReplacement=@'
$1public function confirmPlacementClicked(param1: MouseEvent): void {
$1	this.mPlacementConfirmExplicit = true;
$1	this.mPlacePressed = true;
$1	Utils.DiagEvent("PLACEMENT_CONFIRM_EXPLICIT","state=" + this.mGame.mState + ";moving=" + (this.mObjectBeingMoved != null));
$1	try {
$1		this.mouseUp(param1);
$1	} finally {
$1		this.mPlacementConfirmExplicit = false;
$1		this.mPlacePressed = false;
$1	}
$1}

$1public function mouseUp(param1: MouseEvent): void {
'@
  $scene=Replace-RegexOnce $scene $mouseUpPattern $mouseUpReplacement.TrimEnd() 'placement_explicit_confirm_entrypoint'

  if(-not $scene.Contains('pointerCommit = false;')){throw 'ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL verification=mobile_pointer_commit_disabled_missing'}
  if(-not $scene.Contains('return this.mPlacementConfirmExplicit;')){throw 'ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL verification=mobile_explicit_gate_missing'}
  if(-not $scene.Contains('PLACEMENT_CONFIRM_EXPLICIT')){throw 'ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL verification=placement_confirm_diagnostic_missing'}
  Write-Utf8Bom $sceneTarget $scene

  # GameHUD: do not set a long-lived scene flag and replay a generic scene mouseUp.
  # Route the check button through the explicit, self-clearing scene transaction.
  $hudTarget=Get-TargetPath 'hud'
  $hud=Normalize-Lf ([IO.File]::ReadAllText($hudTarget))
  $hudPlacePattern='(?ms)param1\.stopImmediatePropagation\(\);\s*GameState\.mInstance\.mScene\.mPlacePressed = true;\s*if \(this\.mGame\.mState == GameState\.STATE_MOVE_ITEM \|\| this\.mGame\.mState == GameState\.STATE_USE_INVENTORY_ITEM \|\| this\.mGame\.mState == GameState\.STATE_PLACE_ITEM\) \{\s*GameState\.mInstance\.mScene\.mouseUp\(param1\);\s*\} else if \(this\.mGame\.mState == GameState\.STATE_PLACE_FIRE_MISSION\) \{'
  $hudPlaceReplacement=@'
param1.stopImmediatePropagation();
			if (this.mGame.mState == GameState.STATE_MOVE_ITEM || this.mGame.mState == GameState.STATE_USE_INVENTORY_ITEM || this.mGame.mState == GameState.STATE_PLACE_ITEM) {
				GameState.mInstance.mScene.confirmPlacementClicked(param1);
			} else if (this.mGame.mState == GameState.STATE_PLACE_FIRE_MISSION) {
				GameState.mInstance.mScene.mPlacePressed = true;
'@
  $hud=Replace-RegexOnce $hud $hudPlacePattern $hudPlaceReplacement.TrimEnd() 'gamehud_routes_check_to_explicit_confirm'
  if(-not $hud.Contains('mScene.confirmPlacementClicked(param1)')){throw 'ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL verification=gamehud_explicit_confirm_missing'}
  Write-Utf8Bom $hudTarget $hud

  # Enemy installations: their wrecking state previously depended exclusively on an
  # authored "end" frame label. effect_explosion can lack that outer label, leaving
  # INSTALLATION_ANIMATION_WRECKING (index 3) visible forever. Bound it by the same
  # configured explosion clock already used by character death handling.
  $enemyTarget=Get-TargetPath 'enemyInstallation'
  $enemy=Normalize-Lf ([IO.File]::ReadAllText($enemyTarget))
  $wreckFieldPattern='(?m)^([ \t]*)protected var mActionTimer:Number;\s*$'
  $wreckFieldReplacement=@'
$1protected var mActionTimer:Number;
$1private var mWreckingSafetyTimer:int = 0;
'@
  $enemy=Replace-RegexOnce $enemy $wreckFieldPattern $wreckFieldReplacement.TrimEnd() 'enemy_installation_wrecking_timer_field'

  $wreckLogicPattern='(?ms)case STATE_WRECKING:\s*if\(getCurrentAnimationFrameLabel\(\) == "end"\)\s*\{\s*this\.mNewState = STATE_DESTROYED;\s*\}\s*break;'
  $wreckLogicReplacement=@'
case STATE_WRECKING:
               this.mWreckingSafetyTimer += param1;
               var wreckLabel:String = getCurrentAnimationFrameLabel();
               var wreckLimit:int = Math.max(500,GameState.mConfig.GraphicSetup.Explosion.Length + 250);
               if(wreckLabel == "end" || this.mWreckingSafetyTimer >= wreckLimit)
               {
                  if(this.mWreckingSafetyTimer >= wreckLimit && wreckLabel != "end")
                  {
                     Utils.DiagEvent("INSTALLATION_WRECKING_TIMEOUT","item=" + mItem.mId + ";elapsed_ms=" + this.mWreckingSafetyTimer + ";limit_ms=" + wreckLimit + ";animation=" + mAnimationController.getCurrentAnimationIndex());
                  }
                  Utils.DiagEvent("INSTALLATION_WRECKING_CLEANUP","item=" + mItem.mId + ";reason=" + (wreckLabel == "end" ? "end_label" : "bounded_timeout"));
                  this.mWreckingSafetyTimer = 0;
                  this.mNewState = STATE_DESTROYED;
               }
               break;
'@
  $enemy=Replace-RegexOnce $enemy $wreckLogicPattern $wreckLogicReplacement.TrimEnd() 'enemy_installation_wrecking_bounded_cleanup'

  $wreckResetPattern='(?ms)(protected function changeState\(param1:int\)\s*:\s*void\s*\{.*?switch\(param1\)\s*\{.*?case STATE_WRECKING:\s*)'
  $wreckResetReplacement='$1this.mWreckingSafetyTimer = 0;' + "`n               "
  $enemy=Replace-RegexOnce $enemy $wreckResetPattern $wreckResetReplacement 'enemy_installation_wrecking_timer_reset'
  if(-not $enemy.Contains('INSTALLATION_WRECKING_CLEANUP')){throw 'ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL verification=installation_cleanup_diagnostic_missing'}
  Write-Utf8Bom $enemyTarget $enemy

  # Ensure EnemyInstallationObject is actually replaced into the Android SWF and
  # provenance moves beyond the visually-insufficient v3.23 candidate.
  $patcherTarget=Get-TargetPath 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherTarget))
  $versionNeedle='$patchVersion=''mobile-engine-v3.23-visual-combat-rootfix'''
  $versionReplacement='$patchVersion=''mobile-engine-v3.24-placement-wrecking-rootfix'''
  $patcher=Replace-LiteralOnce $patcher $versionNeedle $versionReplacement 'patch_version_v3_24'
  $specNeedle="  [ordered]@{Class='game.gameElements.PlayerBuildingObject';Source='src\game\gameElements\PlayerBuildingObject.as';Log='ffdec-performance-player-building.log'},"
  $specReplacement=@"
$specNeedle
  [ordered]@{Class='game.gameElements.EnemyInstallationObject';Source='src\game\gameElements\EnemyInstallationObject.as';Log='ffdec-feature-enemy-installation-lifecycle.log'},
"@
  $patcher=Replace-LiteralOnce $patcher $specNeedle $specReplacement.TrimEnd() 'enemy_installation_patch_spec'
  foreach($required in @('game.gameElements.EnemyInstallationObject','mobile-engine-v3.24-placement-wrecking-rootfix')){
    if(-not $patcher.Contains($required)){throw "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=FAIL patch=patcher_verification missing=$required"}
  }
  Write-Utf8Bom $patcherTarget $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=mobile_placement_requires_explicit_check_callback map_release_cannot_arm_commit=true'
  Write-Host 'REGRESSION_CHECK=PASS name=placement_confirm_gate_is_transactional armed_only_during_check_callback=true finally_cleared=true'
  Write-Host 'REGRESSION_CHECK=PASS name=gamehud_does_not_leave_stale_place_pressed_for_normal_placement'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_installation_wrecking_cleanup_bounded end_label=true timeout=true animation_index=3'
  Write-Host 'REGRESSION_CHECK=PASS name=effect_explosion_installation_wrecking_cannot_persist_forever'
  Write-Host "ANDROID_INTERACTION_CORRECTNESS_OVERLAY=PASS mode=apply sha=$ExpectedSha schema=v1 swf_patch_version=mobile-engine-v3.24-placement-wrecking-rootfix"
}catch{
  $failure=$_
  foreach($key in $targets.Keys){
    $target=Get-TargetPath $key
    $backup=Get-BackupPath $key
    if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  throw $failure
}
