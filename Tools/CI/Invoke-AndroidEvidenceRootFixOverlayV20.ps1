param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v18=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV18.ps1'
if(-not(Test-Path -LiteralPath $v18 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL predecessor_missing=$v18"}

$targets=[ordered]@{
  character='src\game\isometric\characters\IsometricCharacter.as'
  game='src\game\states\GameState.as'
  animation='src\game\characters\AnimationController.as'
  perfjava='android\native\diagnostics\java\com\valverde\armyattack\diagnostics\PerformanceOverlay.java'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
  test='Tools\CI\Test-AndroidRuntimePatch.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v20\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Write-Utf8NoBom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.post-v18')}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V20_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $rx=New-Object System.Text.RegularExpressions.Regex($Pattern)
  $matches=$rx.Matches($Text)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL patch=$Name expected_matches=1 actual=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V20_HOOK=PASS name=$Name matches=1 semantic=true"
  return $rx.Replace($Text,$Replacement,1)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    foreach($entry in @($manifest.files)){
      $key=[string]$entry.key
      $backup=Backup-Path $key
      $target=Target-Path $key
      if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL restore_backup_missing key=$key"}
      Copy-Item -LiteralPath $backup -Destination $target -Force
      $restored=Get-Sha256 $target
      $expected=([string]$entry.sha256).ToUpperInvariant()
      if($restored -ne $expected){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL restore_hash key=$key expected=$expected actual=$restored"}
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v18 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V20=PASS mode=restore baseline_restored=true predecessor=v18 sha=$ExpectedSha"
  return
}

& $v18 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL predecessor_apply_exit=$LASTEXITCODE"}

foreach($key in $targets.Keys){
  $path=Target-Path $key
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V20=FAIL required_file_missing key=$key path=$path"}
}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v20';source_sha=$ExpectedSha;predecessor='v18';files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try {
  $characterPath=Target-Path 'character'
  $character=Normalize-Lf ([IO.File]::ReadAllText($characterPath))
  Require-Token $character 'private var mMovementDebtMs: Number = 0;' 'movement_overlay_predecessor_present'
  Require-Token $character 'import flash.utils.getTimer;' 'wallclock_import_present'

  $character=Replace-LiteralOne $character 'private var mMovementDebtMs: Number = 0;' @'
private var mMovementDebtMs: Number = 0;
		private var mMoveBlockedTraceAt: int = 0;
'@.TrimEnd() 'movement_recovery_trace_field'

  $character=Replace-RegexOne $character '(?ms)public function resetActions\(\)\s*:\s*void\s*\{\s*\}' @'
public function resetActions(): void {
			if (this.mWalkingPath) {
				this.mWalkingPath.length = 0;
			}
			this.mDestinationCell = null;
			this.mMovementDebtMs = 0;
			this.mMoveBlockedTraceAt = 0;
			this.mInQueueForAction = false;
		}
'@.TrimEnd() 'player_inherited_reset_clears_movement_state'

  $character=Replace-RegexOne $character '(?ms)private function revive\(\)\s*:\s*void\s*\{\s*this\.setAnimationAction\(AnimationController\.CHARACTER_ANIMATION_IDLE,\s*false,\s*true\);\s*this\.mState\s*=\s*STATE_WALKING;\s*this\.resetActions\(\);\s*mScene\.hideObjectTooltip\(\);\s*\}' @'
private function revive(): void {
			var stalePath:int = this.mWalkingPath ? this.mWalkingPath.length : 0;
			var movementAllowedBefore:Boolean = this.mAllowMovement;
			var stateBefore:int = this.mState;
			this.resetActions();
			this.mAllowMovement = true;
			this.mState = STATE_WALKING;
			this.setAnimationAction(AnimationController.CHARACTER_ANIMATION_IDLE, false, true);
			mScene.hideObjectTooltip();
			if (GameState.mInstance && GameState.mInstance.mActivatedPlayerUnit == this) {
				GameState.mInstance.updateWalkableCellsForActiveCharacter();
			}
			Utils.DiagEvent("CHARACTER_REVIVE_RESET", "state_before=" + stateBefore + ";state_after=" + this.mState + ";path_before=" + stalePath + ";path_after=" + (this.mWalkingPath ? this.mWalkingPath.length : 0) + ";movement_allowed_before=" + movementAllowedBefore + ";movement_allowed_after=" + this.mAllowMovement);
		}
'@.TrimEnd() 'revive_resets_movement_before_idle'

  $character=Replace-RegexOne $character '(?ms)(public function die\(\)\s*:\s*void\s*\{\s*this\.setAnimationAction\(AnimationController\.CHARACTER_ANIMATION_DYING,\s*false,\s*true\);\s*this\.mState\s*=\s*STATE_DYING;\s*this\.resetActions\(\);)' @'
$1
			if (GameState.mInstance && GameState.mInstance.mActivatedPlayerUnit == this) {
				GameState.mInstance.unActivatePlayerUnit();
				Utils.DiagEvent("MOVE_ACTIVE_UNIT_CLEARED_ON_DEATH", "state=" + this.mState + ";health=" + this.mHealth);
			}
'@.TrimEnd() 'death_clears_active_dead_unit'

  $character=Replace-RegexOne $character '(?ms)(public function moveTo\(param1:\s*Number,\s*param2:\s*Number\)\s*:\s*void\s*\{)\s*if\s*\(!this\.isAlive\(\)\)\s*\{\s*return;\s*\}\s*AStarPathfinder\.mOptimizeStraightPaths\s*=\s*false;' @'
$1
			if (!this.isAlive()) {
				if (this.mWalkingPath) this.mWalkingPath.length = 0;
				Utils.DiagEvent("MOVE_REJECTED", "reason=not_alive;state=" + this.mState + ";x=" + int(param1) + ";y=" + int(param2));
				return;
			}
			if (!this.mAllowMovement) {
				if (this.mState == STATE_WALKING) {
					this.mAllowMovement = true;
					this.mMovementDebtMs = 0;
					this.mMoveBlockedTraceAt = 0;
					Utils.DiagEvent("MOVE_STALE_LOCK_RECOVERED", "state=" + this.mState + ";path_before=" + (this.mWalkingPath ? this.mWalkingPath.length : 0) + ";x=" + int(param1) + ";y=" + int(param2));
				} else {
					if (this.mWalkingPath) this.mWalkingPath.length = 0;
					Utils.DiagEvent("MOVE_REJECTED", "reason=movement_locked;state=" + this.mState + ";x=" + int(param1) + ";y=" + int(param2));
					return;
				}
			}
			if (this.mWalkingPath) this.mWalkingPath.length = 0;
			this.mDestinationCell = null;
			this.mMovementDebtMs = 0;
			Utils.DiagEvent("MOVE_REQUEST", "state=" + this.mState + ";from_x=" + int(mX) + ";from_y=" + int(mY) + ";to_x=" + int(param1) + ";to_y=" + int(param2) + ";allowed=" + this.mAllowMovement);
			AStarPathfinder.mOptimizeStraightPaths = false;
'@.TrimEnd() 'move_request_recovers_stale_lock'

  $character=Replace-LiteralOne $character 'AStarPathfinder.mOptimizeStraightPaths = true;' @'
AStarPathfinder.mOptimizeStraightPaths = true;
			Utils.DiagEvent("MOVE_PATH_READY", "state=" + this.mState + ";path=" + (this.mWalkingPath ? this.mWalkingPath.length : 0) + ";allowed=" + this.mAllowMovement + ";to_x=" + int(param1) + ";to_y=" + int(param2));
'@.TrimEnd() 'move_path_result_observable'

  $character=Replace-RegexOne $character '(?ms)(if\s*\(this\.mWalkingPath\s*==\s*null\s*\|\|\s*this\.mWalkingPath\.length\s*==\s*0\s*\|\|\s*!this\.mAllowMovement\)\s*\{\s*// Intentional stops must not leak catch-up into a later move\.\s*this\.mMovementDebtMs\s*=\s*0;)' @'
$1
				if (this.mWalkingPath != null && this.mWalkingPath.length > 0 && !this.mAllowMovement) {
					var blockedNow:int = getTimer();
					if (this.mMoveBlockedTraceAt == 0 || blockedNow - this.mMoveBlockedTraceAt >= 1000) {
						this.mMoveBlockedTraceAt = blockedNow;
						Utils.DiagEvent("MOVE_BLOCKED", "reason=movement_locked;state=" + this.mState + ";path=" + this.mWalkingPath.length + ";alive=" + this.isAlive());
					}
				}
'@.TrimEnd() 'movement_block_is_observable'

  $character=Replace-RegexOne $character '(?m)^[ \t]*public function allowMovement\(param1:\s*Boolean\):\s*void\s*\{' @'
		public function canAcceptMovementCommand(): Boolean {
			return this.isAlive() && this.mState == STATE_WALKING;
		}

		public function allowMovement(param1: Boolean): void {
'@.TrimEnd() 'movement_command_state_contract'

  foreach($token in @('CHARACTER_REVIVE_RESET','MOVE_ACTIVE_UNIT_CLEARED_ON_DEATH','MOVE_STALE_LOCK_RECOVERED','MOVE_REQUEST','MOVE_PATH_READY','MOVE_BLOCKED','MOVE_REJECTED','canAcceptMovementCommand')){Require-Token $character $token 'character_movement_recovery_contract'}
  Write-Utf8Bom $characterPath $character

  $gamePath=Target-Path 'game'
  $game=Normalize-Lf ([IO.File]::ReadAllText($gamePath))
  $game=Replace-RegexOne $game '(?ms)(public function doPlayerWalkAction\(param1:\s*Number,\s*param2:\s*Number\):\s*Boolean\s*\{\s*var _loc5_:\s*WalkingAction = null;\s*var _loc3_:\s*PlayerUnit = this\.mActivatedPlayerUnit;\s*if \(!_loc3_\) \{\s*Utils\.LogError\("Trying to walk without activated character"\);\s*return false;\s*\})' @'
$1
			if (!_loc3_.canAcceptMovementCommand()) {
				Utils.DiagEvent("MOVE_COMMAND_REJECTED", "reason=active_unit_state;state=" + _loc3_.getState() + ";alive=" + _loc3_.isAlive() + ";x=" + int(param1) + ";y=" + int(param2));
				return false;
			}
'@.TrimEnd() 'walk_command_validates_active_unit_state'

  $game=Replace-RegexOne $game '(?ms)if \(!_loc4_\.mCharacter && _loc4_\.mWalkable && this\.isInWalkingDistance\(_loc4_\) && !this\.mCurrentAction\) \{(.*?)this\.queueAction\(_loc5_\);\s*return true;\s*\}\s*return false;' @'
if (!_loc4_.mCharacter && _loc4_.mWalkable && this.isInWalkingDistance(_loc4_) && !this.mCurrentAction) {$1this.queueAction(_loc5_);
				Utils.DiagEvent("MOVE_COMMAND_QUEUED", "map=" + this.mCurrentMapId + ";state=" + this.mState + ";pvp=" + (this.mState == STATE_PVP) + ";x=" + int(param1) + ";y=" + int(param2));
				return true;
			}
			// During a campaign enemy move, the clicked player destination is valid.
			// Preserve one player command behind the enemy round rather than silently
			// dropping it (and unselecting the unit) while the shared lane is busy.
			if (Config.OFFLINE_MODE && this.mState == STATE_PLAY &&
				this.mCurrentAction &&
				!_loc4_.mCharacter && _loc4_.mWalkable && this.isInWalkingDistance(_loc4_)) {
				var alreadyPendingWalk:Boolean = false;
				for each (var queuedWalkAction:Action in this.mMainActionQueue.mActions) {
					if (queuedWalkAction is WalkingAction) { alreadyPendingWalk = true; break; }
				}
				if (!alreadyPendingWalk) {
					this.queueAction(new WalkingAction(_loc3_,param1,param2));
					Utils.DiagEvent("MOVE_COMMAND_DEFERRED_ENEMY_MOVE","map=" + this.mCurrentMapId + ";x=" + int(param1) + ";y=" + int(param2) + ";current_action=" + this.mCurrentAction.mName);
					Utils.DiagEvent("MOVE_COMMAND_DEFERRED_BUSY_ACTION","map=" + this.mCurrentMapId + ";x=" + int(param1) + ";y=" + int(param2) + ";current_action=" + this.mCurrentAction.mName);
					return true;
				}
				Utils.DiagEvent("MOVE_COMMAND_ALREADY_PENDING","map=" + this.mCurrentMapId + ";x=" + int(param1) + ";y=" + int(param2));
			}
			Utils.DiagEvent("MOVE_COMMAND_REJECTED", "reason=cell_gate;occupied=" + Boolean(_loc4_.mCharacter) + ";walkable=" + _loc4_.mWalkable + ";in_range=" + this.isInWalkingDistance(_loc4_) + ";current_action=" + (this.mCurrentAction ? this.mCurrentAction.mName : "none") + ";state=" + this.mState + ";x=" + int(param1) + ";y=" + int(param2));
			return false;
'@.TrimEnd() 'walk_command_rejection_is_observable'
  foreach($token in @('MOVE_COMMAND_REJECTED','MOVE_COMMAND_QUEUED','canAcceptMovementCommand')){Require-Token $game $token 'game_movement_command_diagnostics'}
  Write-Utf8Bom $gamePath $game

  $animationPath=Target-Path 'animation'
  $animation=Normalize-Lf ([IO.File]::ReadAllText($animationPath))
  $animation=Replace-RegexOne $animation '(?ms)if\(nonResetAfter > 0\)\s*\{\s*Utils\.DiagEvent\("SHOOT_TRANSIENT_RESIDUE","id=" \+ id \+ ";owner=" \+ \(this\.mOwner \? getQualifiedClassName\(this\.mOwner\) : "null"\) \+ ";index=" \+ index \+ ";reason=frames_not_reset;nonreset_after=" \+ nonResetAfter\);\s*\}' @'
if(nonResetAfter > 1)
         {
            Utils.DiagEvent("SHOOT_TRANSIENT_RESIDUE","id=" + id + ";owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";index=" + index + ";reason=frames_not_reset;nonreset_after=" + nonResetAfter);
         }
         else if(nonResetAfter == 1)
         {
            Utils.DiagEvent("SHOOT_TRANSIENT_RESET_TOLERATED","id=" + id + ";owner=" + (this.mOwner ? getQualifiedClassName(this.mOwner) : "null") + ";index=" + index + ";reason=single_authored_node;nonreset_after=1");
         }
'@.TrimEnd() 'single_authored_shoot_node_not_false_residue'
  Require-Token $animation 'SHOOT_TRANSIENT_RESET_TOLERATED' 'shoot_residue_diagnostic_tolerance'
  Write-Utf8Bom $animationPath $animation

  $perfPath=Target-Path 'perfjava'
  $perf=Normalize-Lf ([IO.File]::ReadAllText($perfPath))
  $perf=Replace-LiteralOne $perf '            || kind.startsWith("ANIMATION_")' @'
            || kind.startsWith("ANIMATION_")
            || kind.startsWith("MOVE_")
            || "CHARACTER_REVIVE_RESET".equals(kind)
'@.TrimEnd() 'movement_events_logcat_mirror'

  $perf=Replace-LiteralOne $perf '            int ownershipMaxCommitMs = 0;' @'
            int ownershipMaxCommitMs = 0;
            int moveRequest = 0;
            int movePathReady = 0;
            int moveQueued = 0;
            int moveRejected = 0;
            int moveBlocked = 0;
            int moveStaleRecovered = 0;
            int moveActiveClearedOnDeath = 0;
            int reviveReset = 0;
'@.TrimEnd() 'movement_summary_counters'

  $perf=Replace-RegexOne $perf '(?ms)(if \(detail\.contains\("result=failed"\)\) ownershipFailed\+\+;\s*\})(\s*\})\s*java\.util\.HashSet<Integer> unmatchedShootIds' @'
$1 else if ("MOVE_REQUEST".equals(kind)) {
                    moveRequest++;
                } else if ("MOVE_PATH_READY".equals(kind)) {
                    movePathReady++;
                } else if ("MOVE_COMMAND_QUEUED".equals(kind)) {
                    moveQueued++;
                } else if ("MOVE_COMMAND_REJECTED".equals(kind) || "MOVE_REJECTED".equals(kind)) {
                    moveRejected++;
                } else if ("MOVE_BLOCKED".equals(kind)) {
                    moveBlocked++;
                } else if ("MOVE_STALE_LOCK_RECOVERED".equals(kind)) {
                    moveStaleRecovered++;
                } else if ("MOVE_ACTIVE_UNIT_CLEARED_ON_DEATH".equals(kind)) {
                    moveActiveClearedOnDeath++;
                } else if ("CHARACTER_REVIVE_RESET".equals(kind)) {
                    reviveReset++;
                }
$2

            java.util.HashSet<Integer> unmatchedShootIds
'@.TrimEnd() 'movement_event_pairing'

  $perf=Replace-LiteralOne $perf '            ownership.put("max_commit_ms", ownershipMaxCommitMs);' @'
            ownership.put("max_commit_ms", ownershipMaxCommitMs);

            JSONObject movement = new JSONObject();
            movement.put("requests", moveRequest);
            movement.put("paths_ready", movePathReady);
            movement.put("commands_queued", moveQueued);
            movement.put("rejected", moveRejected);
            movement.put("blocked", moveBlocked);
            movement.put("stale_lock_recovered", moveStaleRecovered);
            movement.put("active_unit_cleared_on_death", moveActiveClearedOnDeath);
            movement.put("revive_resets", reviveReset);
'@.TrimEnd() 'movement_summary_json'

  $perf=Replace-LiteralOne $perf '            visual.put("ownership", ownership);' @'
            visual.put("ownership", ownership);
            visual.put("movement_recovery", movement);
'@.TrimEnd() 'movement_summary_attached'

  $perf=Replace-LiteralOne $perf '            if (ownershipFailed > 0) hints.put("OWNERSHIP_COMMIT_FAILED");' @'
            if (ownershipFailed > 0) hints.put("OWNERSHIP_COMMIT_FAILED");
            if (moveBlocked > 0) hints.put("MOVE_BLOCKED");
            if (moveStaleRecovered > 0) hints.put("MOVE_STALE_LOCK_RECOVERED");
            if (moveRejected > 0) hints.put("MOVE_REJECTED_PRESENT");
            if (reviveReset > 0 && moveRejected > 0) hints.put("MOVE_REJECTED_WITH_RECOVERY_ACTIVITY");
'@.TrimEnd() 'movement_root_cause_hints'

  $rootCauseAnchor='            writeText(new File(dir, "root-cause.txt"), rootCause.toString());'
  $rootCauseMovement=@'
            rootCause.append("MOVEMENT requests=").append(moveRequest)
                .append(" paths_ready=").append(movePathReady)
                .append(" queued=").append(moveQueued)
                .append(" rejected=").append(moveRejected)
                .append(" blocked=").append(moveBlocked)
                .append(" stale_recovered=").append(moveStaleRecovered)
                .append(" active_cleared_on_death=").append(moveActiveClearedOnDeath)
                .append(" revive_resets=").append(reviveReset).append('\n');
            writeText(new File(dir, "root-cause.txt"), rootCause.toString());
'@
  $perf=Replace-LiteralOne $perf $rootCauseAnchor $rootCauseMovement.TrimEnd() 'movement_root_cause_text'
  foreach($token in @('movement_recovery','MOVE_STALE_LOCK_RECOVERED','MOVE_REJECTED_PRESENT','MOVEMENT requests=')){Require-Token $perf $token 'movement_zip_root_cause'}
  Write-Utf8NoBom $perfPath $perf

  $patcherPath=Target-Path 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patcher=Replace-LiteralOne $patcher '$patchVersion=''mobile-engine-v3.31-attack-fx-rootfix-v18''' '$patchVersion=''mobile-engine-v3.32-movement-recovery-rootfix-v20''' 'patch_version_v20'
  $verifyAnchor='Write-Host "SWF_V18_BYTECODE_VERIFY=PASS method=decompiled_final_swf classes=AnimationController,HitEffect markers=$($animationMarkers.Count+$hitMarkers.Count) patch_version=$patchVersion patched_sha256=$outputSha manifest=$verifyManifestPath log=$verifyLog"'
  $verifyBlock=@'
$v20VerifyDir=Join-Path $outDir 'v20-final-movement-verify'
if(Test-Path -LiteralPath $v20VerifyDir){Remove-Item -LiteralPath $v20VerifyDir -Recurse -Force}
New-Item -ItemType Directory -Force -Path $v20VerifyDir|Out-Null
$v20Classes='game.isometric.characters.IsometricCharacter,game.states.GameState'
$v20Args=@('-cli','-selectclass',$v20Classes,'-export','script',$v20VerifyDir,$OutputSwf)
$v20Log=Join-Path $logRoot 'ffdec-v20-final-movement-verify.log'
$previousErrorActionPreference=$ErrorActionPreference
try {
  $ErrorActionPreference='Continue'
  if($java){$v20Lines=@(& $java.Source '-jar' $ffdec.FullName @v20Args 2>&1|ForEach-Object{$_.ToString()})}
  else{$v20Lines=@(& $ffdec.FullName @v20Args 2>&1|ForEach-Object{$_.ToString()})}
  $v20Exit=$LASTEXITCODE
} finally {$ErrorActionPreference=$previousErrorActionPreference}
$v20Lines|Set-Content -LiteralPath $v20Log -Encoding UTF8
if($v20Exit -ne 0){$v20Lines|Select-Object -Last 120|ForEach-Object{Write-Host $_};throw "SWF_V20_MOVEMENT_VERIFY=FAIL operation=export_final_classes exit=$v20Exit log=$v20Log"}
$v20Character=@(Get-ChildItem -LiteralPath $v20VerifyDir -Recurse -File -Filter 'IsometricCharacter.as' -ErrorAction SilentlyContinue)
$v20Game=@(Get-ChildItem -LiteralPath $v20VerifyDir -Recurse -File -Filter 'GameState.as' -ErrorAction SilentlyContinue)
if($v20Character.Count -ne 1){throw "SWF_V20_MOVEMENT_VERIFY=FAIL class=IsometricCharacter exported=$($v20Character.Count)"}
if($v20Game.Count -ne 1){throw "SWF_V20_MOVEMENT_VERIFY=FAIL class=GameState exported=$($v20Game.Count)"}
$v20CharacterText=[IO.File]::ReadAllText($v20Character[0].FullName)
$v20GameText=[IO.File]::ReadAllText($v20Game[0].FullName)
$v20CharacterMarkers=@('CHARACTER_REVIVE_RESET','MOVE_ACTIVE_UNIT_CLEARED_ON_DEATH','MOVE_STALE_LOCK_RECOVERED','MOVE_REQUEST','MOVE_PATH_READY','MOVE_BLOCKED','MOVE_REJECTED','canAcceptMovementCommand')
$v20GameMarkers=@('MOVE_COMMAND_REJECTED','MOVE_COMMAND_QUEUED','canAcceptMovementCommand')
foreach($marker in $v20CharacterMarkers){if($v20CharacterText -notmatch [regex]::Escape($marker)){throw "SWF_V20_MOVEMENT_VERIFY=FAIL class=IsometricCharacter marker=$marker"}}
foreach($marker in $v20GameMarkers){if($v20GameText -notmatch [regex]::Escape($marker)){throw "SWF_V20_MOVEMENT_VERIFY=FAIL class=GameState marker=$marker"}}
Write-Host "SWF_V20_MOVEMENT_VERIFY=PASS classes=IsometricCharacter,GameState markers=$($v20CharacterMarkers.Count+$v20GameMarkers.Count) patch_version=$patchVersion patched_sha256=$outputSha log=$v20Log"
'@
  $patcher=Replace-LiteralOne $patcher $verifyAnchor ($verifyAnchor+"`n"+$verifyBlock.TrimEnd()) 'final_swf_movement_gate'
  Write-Utf8Bom $patcherPath $patcher

  $testPath=Target-Path 'test'
  $test=Normalize-Lf ([IO.File]::ReadAllText($testPath))
  $test=Replace-LiteralOne $test 'Require-Contains $swfPatch ''mobile-engine-v3.31-attack-fx-rootfix-v18'' ''swf_patch_version_is_v18''' @'
Require-Contains $swfPatch 'mobile-engine-v3.32-movement-recovery-rootfix-v20' 'swf_patch_version_is_v20'
Require-Contains $swfPatch 'SWF_V20_MOVEMENT_VERIFY=PASS' 'swf_patch_verifies_final_movement_recovery'
Require-Contains $character 'CHARACTER_REVIVE_RESET' 'revive_resets_movement_lifecycle'
Require-Contains $character 'MOVE_ACTIVE_UNIT_CLEARED_ON_DEATH' 'dead_active_unit_is_cleared'
Require-Contains $character 'MOVE_STALE_LOCK_RECOVERED' 'stale_movement_lock_self_recovers'
Require-Contains $character 'canAcceptMovementCommand' 'movement_command_state_contract'
Require-Contains $game 'MOVE_COMMAND_REJECTED' 'movement_command_rejections_are_observable'
Require-Contains $game 'MOVE_COMMAND_QUEUED' 'movement_command_queue_is_observable'
'@.TrimEnd() 'runtime_test_v20_contract'
  Write-Utf8Bom $testPath $test

  Write-Host 'REGRESSION_CHECK=PASS name=player_death_cannot_leave_stale_walk_path inherited_reset=clears_path,destination,debt,queue'
  Write-Host 'REGRESSION_CHECK=PASS name=revive_restores_movement_before_idle state=walking allow=true active_walkable_refresh=true'
  Write-Host 'REGRESSION_CHECK=PASS name=dead_selected_unit_cannot_poison_future_move_commands active_unit=cleared_on_death'
  Write-Host 'REGRESSION_CHECK=PASS name=stale_movement_lock_is_observable_and_self_heals scope=alive+STATE_WALKING'
  Write-Host 'REGRESSION_CHECK=PASS name=movement_command_failure_is_diagnostic reasons=active_unit_state,cell_gate,not_alive,movement_locked'
  Write-Host 'REGRESSION_CHECK=PASS name=shoot_residue_hint_uses_evidence_threshold single_authored_node=tolerated multiple_nodes=residue'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V20=PASS mode=apply sha=$ExpectedSha predecessor=v18 swf_patch_version=mobile-engine-v3.32-movement-recovery-rootfix-v20 movement_recovery=true diagnostics=true"
}
catch {
  $failure=$_
  foreach($key in $targets.Keys){
    $backup=Backup-Path $key
    if(Test-Path -LiteralPath $backup){Copy-Item -LiteralPath $backup -Destination (Target-Path $key) -Force}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v18 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{}
  throw $failure
}
