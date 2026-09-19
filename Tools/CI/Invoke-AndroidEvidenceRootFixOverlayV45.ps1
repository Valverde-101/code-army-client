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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v44=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV44.ps1'
$gameStatePath=Join-Path $RepoRoot 'src\game\states\GameState.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v45\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v44 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL predecessor_missing=$v44"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-One([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $p=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($p -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL patch=$Name missing"}
  if($Text.IndexOf($Needle,$p+$Needle.Length,[StringComparison]::Ordinal) -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL patch=$Name ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V45_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$p)+$Replacement+$Text.Substring($p+$Needle.Length)
}
function Require([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL verify=$Name"}}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $m=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$m.source_sha -ne $ExpectedSha){throw 'ANDROID_EVIDENCE_ROOTFIX_V45=FAIL restore_sha'}
  foreach($e in @($m.files)){
    $target=Join-Path $RepoRoot ([string]$e.path)
    $backup=Join-Path $backupRoot ([string]$e.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL restore_missing=$($e.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$e.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL restore_hash=$($e.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v44 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V45=PASS mode=restore predecessor=v44 sha=$ExpectedSha"
  return
}

& $v44 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  if(-not(Test-Path -LiteralPath $gameStatePath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL required_file=$gameStatePath"}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $backupName='GameState.post-v44.as'
  Copy-Item -LiteralPath $gameStatePath -Destination (Join-Path $backupRoot $backupName) -Force
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v45';source_sha=$ExpectedSha;predecessor='v44';files=@([ordered]@{path='src\game\states\GameState.as';backup=$backupName;sha256=(Get-Sha256 $gameStatePath)})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $game=Normalize-Lf ([IO.File]::ReadAllText($gameStatePath))

  # One player action used to advance only one enemy in the reaction queue. In
  # offline campaign play that makes a map with 50-70 enemies feel inert. Keep
  # the original call site but route it through a bounded three-slot advance.
  $game=Replace-One $game 'this.mScene.reduceEnemyUnitQueueNumber();' 'this.advanceEnemyOrderQueue();' 'enemy_order_batch_advance'

  $fieldAnchor='\t\tpublic var mMainActionQueue: ActionQueue;'.Replace('\t',"`t")
  $fieldBlock=@'
		public var mMainActionQueue: ActionQueue;

		private static const OFFLINE_ENEMY_FAST_REACTION_MINUTES:int = 1;
		private static const OFFLINE_ENEMY_HEAVY_REACTION_MINUTES:int = 2;
		private static const OFFLINE_ENEMY_HEAVY_BASELINE_MINUTES:int = 180;
		private static const OFFLINE_ENEMY_ORDER_ADVANCE:int = 3;
		private static const OFFLINE_ENEMY_MAX_CONCURRENT_ACTIONS:int = 3;
		private static const OFFLINE_ENEMY_LOW_FPS_CONCURRENT_ACTIONS:int = 2;
		private static const OFFLINE_ENEMY_LOW_FPS_THRESHOLD:int = 20;
		private static const OFFLINE_ENEMY_RETUNE_INTERVAL_MS:int = 5000;

		private var mConcurrentEnemyActions:Array = new Array();
		private var mOfflineEnemyAiTunedScene:IsometricScene;
		private var mOfflineEnemyAiRetuneElapsed:int = OFFLINE_ENEMY_RETUNE_INTERVAL_MS;
'@.TrimEnd()
  $game=Replace-One $game $fieldAnchor (Normalize-Lf $fieldBlock) 'enemy_ai_fields'

  $updatePattern='(?s)\t\tpublic function updateActions\(param1: int\): void \{.*?\n\t\t\}\n\n\t\tpublic function queueAction'
  $updateRegex=New-Object System.Text.RegularExpressions.Regex($updatePattern)
  $updateCount=$updateRegex.Matches($game).Count
  if($updateCount -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL patch=update_actions_boundary expected=1 actual=$updateCount"}
  $updateReplacement=@'
		private function ensureOfflineEnemyAiTuned(param1:int):void {
			if (!Config.OFFLINE_MODE || this.mState != STATE_PLAY || !this.mScene) {
				return;
			}
			var sceneChanged:Boolean = this.mOfflineEnemyAiTunedScene != this.mScene;
			this.mOfflineEnemyAiRetuneElapsed += param1;
			if (!sceneChanged && this.mOfflineEnemyAiRetuneElapsed < OFFLINE_ENEMY_RETUNE_INTERVAL_MS) {
				return;
			}
			this.mOfflineEnemyAiRetuneElapsed = 0;
			this.mOfflineEnemyAiTunedScene = this.mScene;
			var enemies:Array = this.mScene.getEnemyUnits();
			var count:int = enemies ? int(enemies.length) : 0;
			var tuned:int = 0;
			var clamped:int = 0;
			var i:int = 0;
			var enemy:EnemyUnit = null;
			var oldMinutes:int = 0;
			var tunedMinutes:int = 0;
			var cell:GridCell = null;
			var seed:int = 0;
			var firstDelay:int = 0;
			var state:int = 0;
			while (i < count) {
				enemy = enemies[i] as EnemyUnit;
				if (enemy && enemy.isAlive()) {
					oldMinutes = enemy.mReactionActivitionTimeInMinutes;
					if (oldMinutes <= 0 || oldMinutes > OFFLINE_ENEMY_HEAVY_REACTION_MINUTES) {
						tunedMinutes = oldMinutes > OFFLINE_ENEMY_HEAVY_BASELINE_MINUTES ? OFFLINE_ENEMY_HEAVY_REACTION_MINUTES : OFFLINE_ENEMY_FAST_REACTION_MINUTES;
						enemy.mReactionActivitionTimeInMinutes = tunedMinutes;
						cell = enemy.getCell();
						seed = i * 17;
						if (cell) {
							seed += cell.mPosI * 31 + cell.mPosJ * 13;
						}
						firstDelay = 4000 + int(Math.abs(seed % 9)) * 4000;
						if (enemy.mRemainingTimeToNextAction >= 0) {
							enemy.mRemainingTimeToNextAction = firstDelay;
							clamped++;
						}
						state = enemy.getReactionState();
						if (state == EnemyUnit.REACT_STATE_WAIT_FOR_TIMER) {
							enemy.mReactionStateCounter = firstDelay;
							clamped++;
						} else if (state == EnemyUnit.REACT_STATE_WAIT_FOR_ORDERS && enemy.mReactionStateCounter > 1) {
							enemy.mReactionStateCounter = int(Math.max(1,Math.ceil(enemy.mReactionStateCounter / OFFLINE_ENEMY_ORDER_ADVANCE)));
						}
						tuned++;
					}
				}
				i++;
			}
			if (sceneChanged || tuned > 0) {
				Utils.DiagEvent("ENEMY_AI_TUNING","map=" + this.mCurrentMapId + ";enemies=" + count + ";tuned=" + tuned + ";timer_clamps=" + clamped + ";fast_minutes=" + OFFLINE_ENEMY_FAST_REACTION_MINUTES + ";heavy_minutes=" + OFFLINE_ENEMY_HEAVY_REACTION_MINUTES + ";retune_ms=" + OFFLINE_ENEMY_RETUNE_INTERVAL_MS);
			}
		}

		private function advanceEnemyOrderQueue():void {
			if (!this.mScene) {
				return;
			}
			if (Config.OFFLINE_MODE && this.mState == STATE_PLAY) {
				this.beginOfflineEnemyResponseRound(OFFLINE_ENEMY_ORDER_ADVANCE);
				return;
			}
			this.mScene.reduceEnemyUnitQueueNumber();
		}

		private function getOfflineEnemyConcurrencyLimit():int {
			if (!Config.OFFLINE_MODE || this.mState != STATE_PLAY) {
				return 1;
			}
			if (this.mFrameRate <= 0 || this.mFrameRate < OFFLINE_ENEMY_LOW_FPS_THRESHOLD) {
				return OFFLINE_ENEMY_LOW_FPS_CONCURRENT_ACTIONS;
			}
			return OFFLINE_ENEMY_MAX_CONCURRENT_ACTIONS;
		}

		private function updateConcurrentEnemyActions(param1:int):void {
			var i:int = this.mConcurrentEnemyActions.length - 1;
			var action:Action = null;
			while (i >= 0) {
				action = this.mConcurrentEnemyActions[i] as Action;
				if (!action) {
					this.mConcurrentEnemyActions.splice(i,1);
				} else {
					action.update(param1);
					if (action.isOver()) {
						this.mConcurrentEnemyActions.splice(i,1);
					}
				}
				i--;
			}
		}

		private function pumpConcurrentEnemyActions():void {
			if (!Config.OFFLINE_MODE || this.mState != STATE_PLAY || !this.mCurrentAction || !this.mCurrentAction.isEnemyAction()) {
				return;
			}
			var limit:int = this.getOfflineEnemyConcurrencyLimit();
			var maxAux:int = limit - 1;
			var started:int = 0;
			var nextAction:Action = null;
			while (this.mConcurrentEnemyActions.length < maxAux && this.mMainActionQueue.mActions.length > 0) {
				nextAction = this.mMainActionQueue.mActions[0] as Action;
				if (!nextAction || !nextAction.isEnemyAction()) {
					break;
				}
				this.mMainActionQueue.mActions.shift();
				if (Boolean(nextAction.mTarget) && nextAction.mTarget is Renderable) {
					nextAction.mTarget.removedFromActionQueue();
				}
				nextAction.start();
				this.mConcurrentEnemyActions.push(nextAction);
				started++;
			}
			if (started > 0) {
				Utils.DiagEvent("ENEMY_AI_BATCH_START","map=" + this.mCurrentMapId + ";started=" + started + ";active_total=" + (1 + this.mConcurrentEnemyActions.length) + ";limit=" + limit + ";fps=" + this.mFrameRate + ";queued=" + this.mMainActionQueue.mActions.length);
			}
		}

		private function clearConcurrentEnemyActions():void {
			var i:int = 0;
			var action:Action = null;
			while (i < this.mConcurrentEnemyActions.length) {
				action = this.mConcurrentEnemyActions[i] as Action;
				if (action) {
					action.skip();
				}
				i++;
			}
			this.mConcurrentEnemyActions.length = 0;
		}

		public function updateActions(param1: int): void {
			this.ensureOfflineEnemyAiTuned(param1);
			this.updateConcurrentEnemyActions(param1);
			if (this.mCurrentAction != null) {
				this.mCurrentAction.update(param1);
				if (this.mCurrentAction.isOver()) {
					if (this.mActionWaitingConfirmation) {
						if (this.mActionWaitingConfirmation == this.mCurrentAction) {
							this.mActionWaitingConfirmation = null;
						}
					}
					this.mCurrentAction = null;
					this.mScene.updateCursors(param1, true);
				}
			}
			if (this.mCurrentAction == null && this.mConcurrentEnemyActions.length > 0) {
				return;
			}
			if (this.mCurrentAction == null) {
				if (this.mMainActionQueue.mActions.length > 0) {
					this.mCurrentAction = this.mMainActionQueue.mActions.shift();
					if (Boolean(this.mCurrentAction.mTarget) && this.mCurrentAction.mTarget is Renderable) {
						this.mCurrentAction.mTarget.removedFromActionQueue();
					}
					this.mCurrentAction.start();
				} else if (this.mState == STATE_PLAY || this.mState == STATE_VISITING_NEIGHBOUR) {}
			}
			this.pumpConcurrentEnemyActions();
		}

		public function queueAction
'@.TrimEnd()
  $game=$updateRegex.Replace($game,(Normalize-Lf $updateReplacement),1)
  Write-Host 'EVIDENCE_ROOTFIX_V45_HOOK=PASS name=bounded_concurrent_enemy_action_lane matches=1'

  $resetPattern='(?s)\t\tpublic function resetActions\(\): void \{.*?\n\t\t\}\n\n\t\tpublic function chooseCorrectGraphicFromArray'
  $resetRegex=New-Object System.Text.RegularExpressions.Regex($resetPattern)
  $resetCount=$resetRegex.Matches($game).Count
  if($resetCount -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V45=FAIL patch=reset_actions_boundary expected=1 actual=$resetCount"}
  $resetReplacement=@'
		public function resetActions(): void {
			this.mMainActionQueue.mActions.length = 0;
			this.clearConcurrentEnemyActions();
			this.mCurrentAction = null;
		}

		public function chooseCorrectGraphicFromArray
'@.TrimEnd()
  $game=$resetRegex.Replace($game,(Normalize-Lf $resetReplacement),1)
  Write-Host 'EVIDENCE_ROOTFIX_V45_HOOK=PASS name=concurrent_enemy_cleanup matches=1'

  foreach($required in @(
    'OFFLINE_ENEMY_FAST_REACTION_MINUTES:int = 1',
    'OFFLINE_ENEMY_HEAVY_REACTION_MINUTES:int = 2',
    'OFFLINE_ENEMY_ORDER_ADVANCE:int = 3',
    'OFFLINE_ENEMY_MAX_CONCURRENT_ACTIONS:int = 3',
    'OFFLINE_ENEMY_LOW_FPS_CONCURRENT_ACTIONS:int = 2',
    'ENEMY_AI_TUNING',
    'ENEMY_AI_BATCH_START',
    'this.ensureOfflineEnemyAiTuned(param1);',
    'this.pumpConcurrentEnemyActions();',
    'this.clearConcurrentEnemyActions();',
    'this.advanceEnemyOrderQueue();'
  )){Require $game $required $required}

  Write-Utf8Bom $gameStatePath $game
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_reaction_cadence baseline_hours=60,125,245,305 offline_fast_minutes=1 offline_heavy_minutes=2 old_save_timer_stagger_seconds=4..36'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_combined_pressure response_round_primary_units=3 group_assists_free=true move_then_attack_same_turn=true concurrent_total_max=3 fifo_player_barrier=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_lag_guard low_fps_threshold=20 concurrent_total_low_fps=2 retune_interval_ms=5000 no_per_frame_full_enemy_scan=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_cleanup map_switch_reset_clears_aux_actions=true pvp_unchanged=true visitor_unchanged=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V45=PASS mode=apply predecessor=v44 sha=$ExpectedSha feature=bounded_aggressive_enemy_ai"
}
catch {
  Restore-OwnedFiles
  try { & $v44 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore } catch {}
  throw
}
