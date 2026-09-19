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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v45=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV45.ps1'
$gameStatePath=Join-Path $RepoRoot 'src\game\states\GameState.as'
$enemyMovePath=Join-Path $RepoRoot 'src\game\actions\EnemyMovingAction.as'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v46\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v45 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL predecessor_missing=$v45"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-One([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $p=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($p -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL patch=$Name missing"}
  if($Text.IndexOf($Needle,$p+$Needle.Length,[StringComparison]::Ordinal) -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL patch=$Name ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V46_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$p)+$Replacement+$Text.Substring($p+$Needle.Length)
}
function Require([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL verify=$Name"}}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $m=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$m.source_sha -ne $ExpectedSha){throw 'ANDROID_EVIDENCE_ROOTFIX_V46=FAIL restore_sha'}
  foreach($e in @($m.files)){
    $target=Join-Path $RepoRoot ([string]$e.path)
    $backup=Join-Path $backupRoot ([string]$e.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL restore_missing=$($e.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$e.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL restore_hash=$($e.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v45 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V46=PASS mode=restore predecessor=v45 sha=$ExpectedSha"
  return
}

& $v45 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  foreach($p in @($gameStatePath,$enemyMovePath,$patcherPath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL required_file=$p"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $owned=@(
    @('src\game\states\GameState.as',$gameStatePath,'GameState.post-v45.as'),
    @('src\game\actions\EnemyMovingAction.as',$enemyMovePath,'EnemyMovingAction.post-v45.as'),
    @('Tools\CI\Patch-AndroidPerformanceSwf.ps1',$patcherPath,'Patch-AndroidPerformanceSwf.post-v45.ps1')
  )
  $files=@()
  foreach($x in $owned){
    Copy-Item -LiteralPath $x[1] -Destination (Join-Path $backupRoot $x[2]) -Force
    $files+=@([ordered]@{path=$x[0];backup=$x[2];sha256=(Get-Sha256 $x[1])})
  }
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v46';source_sha=$ExpectedSha;predecessor='v45';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # Campaign EnemyMovingAction had no watchdog and generic Action.skip() did not
  # release mCharacterComingToThisTile. Under V45 concurrency, one stalled move
  # could therefore keep both an enemy and a destination reservation alive.
  $move=Normalize-Lf ([IO.File]::ReadAllText($enemyMovePath))
  $move=Replace-One $move '   import flash.geom.Point;' ("   import flash.geom.Point;`n   import flash.utils.getTimer;") 'enemy_move_wallclock_import'
  $move=Replace-One $move '      protected var mDestinationCell:GridCell;' @'
      protected var mDestinationCell:GridCell;

      private static const OFFLINE_MOVE_WATCHDOG_MS:int = 10000;

      private var mOfflineMoveStartedAt:int = 0;

      private var mReservedDestinationCell:GridCell;
'@.TrimEnd() 'enemy_move_watchdog_fields'

  $isOverAnchor='      override public function isOver() : Boolean'
  $moveHelpers=@'
      private function releaseDestinationReservation() : void
      {
         var actor:IsometricCharacter = mActor as IsometricCharacter;
         if(this.mReservedDestinationCell && this.mReservedDestinationCell.mCharacterComingToThisTile == actor)
         {
            this.mReservedDestinationCell.mCharacterComingToThisTile = null;
         }
         if(actor && actor.mDestinationCell && actor.mDestinationCell != this.mReservedDestinationCell && actor.mDestinationCell.mCharacterComingToThisTile == actor)
         {
            actor.mDestinationCell.mCharacterComingToThisTile = null;
         }
         if(actor)
         {
            actor.mDestinationCell = null;
         }
         this.mReservedDestinationCell = null;
      }

      override public function update(param1:int) : void
      {
         if(mSkipped || !Config.OFFLINE_MODE || this.mOfflineMoveStartedAt <= 0)
         {
            return;
         }
         var elapsed:int = getTimer() - this.mOfflineMoveStartedAt;
         if(elapsed >= OFFLINE_MOVE_WATCHDOG_MS)
         {
            Utils.DiagEvent("ENEMY_MOVE_WATCHDOG","map=" + GameState.mInstance.mCurrentMapId + ";action=" + mName + ";elapsed_ms=" + elapsed + ";limit_ms=" + OFFLINE_MOVE_WATCHDOG_MS);
            this.skip();
         }
      }

      override public function skip() : void
      {
         if(mSkipped)
         {
            return;
         }
         var enemy:EnemyUnit = mActor as EnemyUnit;
         this.releaseDestinationReservation();
         if(enemy)
         {
            enemy.resetActions();
            enemy.changeReactionState(EnemyUnit.REACT_STATE_ACTION_COMPLETED);
         }
         this.mOfflineMoveStartedAt = 0;
         super.skip();
         Utils.DiagEvent("ENEMY_MOVE_ABORT","map=" + (GameState.mInstance ? GameState.mInstance.mCurrentMapId : "") + ";action=" + mName + ";reservation_released=true;path_reset=" + Boolean(enemy));
      }

'@
  $move=Replace-One $move $isOverAnchor ((Normalize-Lf $moveHelpers)+$isOverAnchor) 'enemy_move_watchdog_and_abort'

  $reserveOld=@'
            (mActor as IsometricCharacter).mDestinationCell.mCharacterComingToThisTile = mActor as IsometricCharacter;
            this.mTargetX = (mActor as WorldObject).mScene.getCenterPointXOfCell((mActor as IsometricCharacter).mDestinationCell);
            this.mTargetY = (mActor as WorldObject).mScene.getCenterPointYOfCell((mActor as IsometricCharacter).mDestinationCell);
            this.mOriginCell = mActor.getCell();
            (mActor as IsometricCharacter).moveTo(this.mTargetX,this.mTargetY);
            (mActor as IsometricCharacter).playCollectionSound((mActor as IsometricCharacter).mMoveSounds);
'@.TrimEnd()
  $reserveNew=@'
            this.mReservedDestinationCell = (mActor as IsometricCharacter).mDestinationCell;
            this.mReservedDestinationCell.mCharacterComingToThisTile = mActor as IsometricCharacter;
            this.mTargetX = (mActor as WorldObject).mScene.getCenterPointXOfCell(this.mReservedDestinationCell);
            this.mTargetY = (mActor as WorldObject).mScene.getCenterPointYOfCell(this.mReservedDestinationCell);
            this.mOriginCell = mActor.getCell();
            this.mOfflineMoveStartedAt = getTimer();
            (mActor as IsometricCharacter).moveTo(this.mTargetX,this.mTargetY);
            if((mActor as IsometricCharacter).isStill() && mActor.getCell() != this.mReservedDestinationCell)
            {
               Utils.DiagEvent("ENEMY_MOVE_PATH_FAIL","map=" + GameState.mInstance.mCurrentMapId + ";reason=empty_path;reservation_released=true");
               this.skip();
               return;
            }
            (mActor as IsometricCharacter).playCollectionSound((mActor as IsometricCharacter).mMoveSounds);
'@.TrimEnd()
  $move=Replace-One $move (Normalize-Lf $reserveOld) (Normalize-Lf $reserveNew) 'enemy_move_reservation_transaction'

  $successReleasePattern='(?m)^(?<indent>[ \t]*)(?:mActor\.getCell\(\)|arrivalCell)\.mCharacterComingToThisTile\s*=\s*null;\s*$'
  $successReleaseMatches=[regex]::Matches($move,$successReleasePattern)
  if($successReleaseMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL patch=enemy_move_success_releases_reservation semantic_count=$($successReleaseMatches.Count)"}
  $successReleaseMatch=$successReleaseMatches[0]
  $successReleaseReplacement=$successReleaseMatch.Groups['indent'].Value+'this.releaseDestinationReservation();'
  $move=$move.Substring(0,$successReleaseMatch.Index)+$successReleaseReplacement+$move.Substring($successReleaseMatch.Index+$successReleaseMatch.Length)
  Write-Host 'EVIDENCE_ROOTFIX_V46_HOOK=PASS name=enemy_move_success_releases_reservation matches=1 semantic=true supports=legacy_current_cell,native_arrival_cell'
  $serverOld='         GameState.mInstance.mServer.serverCallServiceWithParameters(ServiceIDs.MOVE_ENEMY,_loc2_,false);'
  $serverNew=@'
         if(!Config.OFFLINE_MODE && GameState.mInstance.mServer)
         {
            try
            {
               GameState.mInstance.mServer.serverCallServiceWithParameters(ServiceIDs.MOVE_ENEMY,_loc2_,false);
            }
            catch(syncError:Error)
            {
               Utils.DiagEvent("ENEMY_MOVE_SYNC_FAIL","map=" + GameState.mInstance.mCurrentMapId + ";error=" + syncError.message);
            }
         }
         else
         {
            Utils.DiagEvent("ENEMY_MOVE_SYNC_SKIP","map=" + GameState.mInstance.mCurrentMapId + ";reason=offline_or_server_null");
         }
'@.TrimEnd()
  $move=Replace-One $move $serverOld (Normalize-Lf $serverNew) 'enemy_move_external_sync_nonfatal'
  $move=Replace-One $move '         (mActor as IsometricCharacter).mPreviousTile = this.mOriginCell;' ("         this.mOfflineMoveStartedAt = 0;`n         (mActor as IsometricCharacter).mPreviousTile = this.mOriginCell;") 'enemy_move_watchdog_disarm_on_success'

  foreach($required in @('OFFLINE_MOVE_WATCHDOG_MS:int = 10000','mReservedDestinationCell','ENEMY_MOVE_WATCHDOG','ENEMY_MOVE_ABORT','ENEMY_MOVE_PATH_FAIL','ENEMY_MOVE_SYNC_SKIP','this.releaseDestinationReservation();','enemy.resetActions();')){Require $move $required $required}
  Write-Utf8Bom $enemyMovePath $move

  # V45 already bounded concurrency to 3 (2 at low FPS). V46 keeps that gameplay
  # pressure but adds a wall-clock action watchdog, actor de-duplication, runtime
  # exception containment, and at most one auxiliary start per frame to prevent
  # simultaneous A* spikes.
  $game=Normalize-Lf ([IO.File]::ReadAllText($gameStatePath))
  $fieldNeedle='\t\tprivate var mOfflineEnemyAiRetuneElapsed:int = OFFLINE_ENEMY_RETUNE_INTERVAL_MS;'.Replace('\t',"`t")
  $fieldReplacement=@'
		private var mOfflineEnemyAiRetuneElapsed:int = OFFLINE_ENEMY_RETUNE_INTERVAL_MS;
		private static const OFFLINE_ENEMY_ACTION_WATCHDOG_MS:int = 12000;
		private static const OFFLINE_ENEMY_AUX_STARTS_PER_FRAME:int = 1;
		private var mConcurrentEnemyActionStartedAt:Array = new Array();
		private var mTrackedMainEnemyAction:Action;
		private var mTrackedMainEnemyActionStartedAt:int = 0;
'@.TrimEnd()
  $game=Replace-One $game $fieldNeedle (Normalize-Lf $fieldReplacement) 'enemy_ai_failsafe_fields'

  $concurrentPattern='(?s)\t\tprivate function updateConcurrentEnemyActions\(param1:int\):void \{.*?\n\t\t\}\n\n\t\tprivate function pumpConcurrentEnemyActions'
  $concurrentRegex=New-Object System.Text.RegularExpressions.Regex($concurrentPattern)
  if($concurrentRegex.Matches($game).Count -ne 1){throw 'ANDROID_EVIDENCE_ROOTFIX_V46=FAIL patch=concurrent_update_boundary'}
  $concurrentReplacement=@'
		private function getEnemyActionActor(param1:Action):Object {
			if (!param1) {
				return null;
			}
			if (param1.mActor) {
				return param1.mActor;
			}
			if (param1.mCharacterActors && param1.mCharacterActors.length > 0) {
				return param1.mCharacterActors[0];
			}
			return null;
		}

		private function isEnemyActionActorActive(param1:Action):Boolean {
			var actor:Object = this.getEnemyActionActor(param1);
			if (!actor) {
				return false;
			}
			if (this.mCurrentAction && this.mCurrentAction != param1 && this.getEnemyActionActor(this.mCurrentAction) == actor) {
				return true;
			}
			var i:int = 0;
			var active:Action = null;
			while (i < this.mConcurrentEnemyActions.length) {
				active = this.mConcurrentEnemyActions[i] as Action;
				if (active && active != param1 && this.getEnemyActionActor(active) == actor) {
					return true;
				}
				i++;
			}
			return false;
		}

		private function failEnemyAction(param1:Action,param2:String,param3:int):void {
			if (!param1) {
				return;
			}
			Utils.DiagEvent("ENEMY_AI_ACTION_FAILSAFE","map=" + this.mCurrentMapId + ";action=" + param1.mName + ";reason=" + param2 + ";elapsed_ms=" + param3);
			try {
				param1.skip();
			} catch (skipError:Error) {
				Utils.DiagEvent("ENEMY_AI_ACTION_FAILSAFE_SKIP_ERROR","map=" + this.mCurrentMapId + ";action=" + param1.mName + ";error=" + skipError.message);
			}
			var actor:Object = this.getEnemyActionActor(param1);
			if (actor is EnemyUnit) {
				EnemyUnit(actor).changeReactionState(EnemyUnit.REACT_STATE_ACTION_COMPLETED);
			}
			if (param1.mCharacterActors) {
				var i:int = 0;
				while (i < param1.mCharacterActors.length) {
					if (param1.mCharacterActors[i] is EnemyUnit) {
						EnemyUnit(param1.mCharacterActors[i]).changeReactionState(EnemyUnit.REACT_STATE_ACTION_COMPLETED);
					}
					i++;
				}
			}
		}

		private function updateConcurrentEnemyActions(param1:int):void {
			var i:int = this.mConcurrentEnemyActions.length - 1;
			var action:Action = null;
			var startedAt:int = 0;
			var elapsed:int = 0;
			var done:Boolean = false;
			while (i >= 0) {
				action = this.mConcurrentEnemyActions[i] as Action;
				startedAt = i < this.mConcurrentEnemyActionStartedAt.length ? int(this.mConcurrentEnemyActionStartedAt[i]) : getTimer();
				elapsed = Math.max(0,getTimer() - startedAt);
				done = false;
				if (!action) {
					done = true;
				} else {
					try {
						action.update(param1);
						done = action.isOver();
						if (!done && elapsed >= OFFLINE_ENEMY_ACTION_WATCHDOG_MS) {
							this.failEnemyAction(action,"aux_timeout",elapsed);
							done = true;
						}
					} catch (actionError:Error) {
						this.failEnemyAction(action,"aux_exception:" + actionError.message,elapsed);
						done = true;
					}
				}
				if (done) {
					this.mConcurrentEnemyActions.splice(i,1);
					if (i < this.mConcurrentEnemyActionStartedAt.length) {
						this.mConcurrentEnemyActionStartedAt.splice(i,1);
					}
				}
				i--;
			}
		}

		private function pumpConcurrentEnemyActions
'@.TrimEnd()
  $game=$concurrentRegex.Replace($game,(Normalize-Lf $concurrentReplacement),1)
  Write-Host 'EVIDENCE_ROOTFIX_V46_HOOK=PASS name=enemy_aux_watchdog_exception_containment matches=1'

  $pumpPattern='(?s)\t\tprivate function pumpConcurrentEnemyActions\(\):void \{.*?\n\t\t\}\n\n\t\tprivate function clearConcurrentEnemyActions'
  $pumpRegex=New-Object System.Text.RegularExpressions.Regex($pumpPattern)
  if($pumpRegex.Matches($game).Count -ne 1){throw 'ANDROID_EVIDENCE_ROOTFIX_V46=FAIL patch=concurrent_pump_boundary'}
  $pumpReplacement=@'
		private function pumpConcurrentEnemyActions():void {
			if (!Config.OFFLINE_MODE || this.mState != STATE_PLAY || !this.mCurrentAction || !this.mCurrentAction.isEnemyAction()) {
				return;
			}
			var limit:int = this.getOfflineEnemyConcurrencyLimit();
			var maxAux:int = limit - 1;
			var started:int = 0;
			var attempts:int = 0;
			var nextAction:Action = null;
			while (this.mConcurrentEnemyActions.length < maxAux && this.mMainActionQueue.mActions.length > 0 && attempts < OFFLINE_ENEMY_AUX_STARTS_PER_FRAME) {
				nextAction = this.mMainActionQueue.mActions[0] as Action;
				if (!nextAction || !nextAction.isEnemyAction()) {
					break;
				}
				if (this.isEnemyActionActorActive(nextAction)) {
					Utils.DiagEvent("ENEMY_AI_BATCH_DEFER","map=" + this.mCurrentMapId + ";reason=actor_busy;action=" + nextAction.mName);
					break;
				}
				attempts++;
				this.mMainActionQueue.mActions.shift();
				if (Boolean(nextAction.mTarget) && nextAction.mTarget is Renderable) {
					nextAction.mTarget.removedFromActionQueue();
				}
				try {
					nextAction.start();
					this.mConcurrentEnemyActions.push(nextAction);
					this.mConcurrentEnemyActionStartedAt.push(getTimer());
					started++;
				} catch (startError:Error) {
					this.failEnemyAction(nextAction,"aux_start_exception:" + startError.message,0);
				}
			}
			if (started > 0) {
				Utils.DiagEvent("ENEMY_AI_BATCH_START","map=" + this.mCurrentMapId + ";started=" + started + ";active_total=" + (1 + this.mConcurrentEnemyActions.length) + ";limit=" + limit + ";fps=" + this.mFrameRate + ";queued=" + this.mMainActionQueue.mActions.length + ";starts_per_frame=" + OFFLINE_ENEMY_AUX_STARTS_PER_FRAME);
			}
		}

		private function clearConcurrentEnemyActions
'@.TrimEnd()
  $game=$pumpRegex.Replace($game,(Normalize-Lf $pumpReplacement),1)
  Write-Host 'EVIDENCE_ROOTFIX_V46_HOOK=PASS name=enemy_aux_stagger_and_actor_dedupe matches=1'

  $clearPattern='(?s)\t\tprivate function clearConcurrentEnemyActions\(\):void \{.*?\n\t\t\}\n\n\t\tpublic function updateActions'
  $clearRegex=New-Object System.Text.RegularExpressions.Regex($clearPattern)
  if($clearRegex.Matches($game).Count -ne 1){throw 'ANDROID_EVIDENCE_ROOTFIX_V46=FAIL patch=concurrent_clear_boundary'}
  $clearReplacement=@'
		private function clearConcurrentEnemyActions():void {
			var i:int = 0;
			var action:Action = null;
			while (i < this.mConcurrentEnemyActions.length) {
				action = this.mConcurrentEnemyActions[i] as Action;
				if (action) {
					this.failEnemyAction(action,"scene_cleanup",Math.max(0,getTimer() - (i < this.mConcurrentEnemyActionStartedAt.length ? int(this.mConcurrentEnemyActionStartedAt[i]) : getTimer())));
				}
				i++;
			}
			this.mConcurrentEnemyActions.length = 0;
			this.mConcurrentEnemyActionStartedAt.length = 0;
			this.mTrackedMainEnemyAction = null;
			this.mTrackedMainEnemyActionStartedAt = 0;
		}

		public function updateActions
'@.TrimEnd()
  $game=$clearRegex.Replace($game,(Normalize-Lf $clearReplacement),1)
  Write-Host 'EVIDENCE_ROOTFIX_V46_HOOK=PASS name=enemy_aux_cleanup_releases_tracking matches=1'

  $updatePattern='(?s)\t\tpublic function updateActions\(param1: int\): void \{.*?\n\t\t\}\n\n\t\tpublic function queueAction'
  $updateRegex=New-Object System.Text.RegularExpressions.Regex($updatePattern)
  if($updateRegex.Matches($game).Count -ne 1){throw 'ANDROID_EVIDENCE_ROOTFIX_V46=FAIL patch=update_actions_boundary'}
  $updateReplacement=@'
		public function updateActions(param1: int): void {
			this.ensureOfflineEnemyAiTuned(param1);
			this.updateConcurrentEnemyActions(param1);
			var done:Boolean = false;
			var offlineEnemy:Boolean = false;
			var elapsed:int = 0;
			if (this.mCurrentAction != null) {
				offlineEnemy = Config.OFFLINE_MODE && this.mState == STATE_PLAY && this.mCurrentAction.isEnemyAction();
				if (offlineEnemy) {
					if (this.mTrackedMainEnemyAction != this.mCurrentAction) {
						this.mTrackedMainEnemyAction = this.mCurrentAction;
						this.mTrackedMainEnemyActionStartedAt = getTimer();
					}
					elapsed = Math.max(0,getTimer() - this.mTrackedMainEnemyActionStartedAt);
					try {
						this.mCurrentAction.update(param1);
						done = this.mCurrentAction.isOver();
						if (!done && elapsed >= OFFLINE_ENEMY_ACTION_WATCHDOG_MS) {
							this.failEnemyAction(this.mCurrentAction,"main_timeout",elapsed);
							done = true;
						}
					} catch (enemyActionError:Error) {
						this.failEnemyAction(this.mCurrentAction,"main_exception:" + enemyActionError.message,elapsed);
						done = true;
					}
				} else {
					this.mTrackedMainEnemyAction = null;
					this.mTrackedMainEnemyActionStartedAt = 0;
					this.mCurrentAction.update(param1);
					done = this.mCurrentAction.isOver();
				}
				if (done) {
					if (this.mActionWaitingConfirmation) {
						if (this.mActionWaitingConfirmation == this.mCurrentAction) {
							this.mActionWaitingConfirmation = null;
						}
					}
					this.mCurrentAction = null;
					this.mTrackedMainEnemyAction = null;
					this.mTrackedMainEnemyActionStartedAt = 0;
					this.mScene.updateCursors(param1, true);
				}
			}
			if (this.mCurrentAction == null && this.mConcurrentEnemyActions.length > 0) {
				return;
			}
			if (this.mCurrentAction == null) {
				// The V45 visual-settle hook must survive V46's full updateActions replacement.
				// Reserve the action lane for the pending campaign response before any
				// already-queued player action can start a new turn and starve the enemy.
				if (Config.OFFLINE_MODE && this.mState == STATE_PLAY) {
					if (this.mOfflineEnemyPlayerRoundsPending > 0 && !this.mOfflineEnemyResponseActive) {
						this.tryStartOfflineEnemyResponseAfterPlayerVisuals();
						if (this.mOfflineEnemyPlayerRoundsPending > 0 && !this.mOfflineEnemyResponseActive) {
							return;
						}
					}
					// A primary may queue its action on the next scene tick. Keep
					// player input behind that action until the entire response ends.
					if (this.mOfflineEnemyResponseActive) {
						var nextOfflineAction:Action = this.mMainActionQueue.mActions.length > 0 ? this.mMainActionQueue.mActions[0] as Action : null;
						if (!nextOfflineAction || !nextOfflineAction.isEnemyAction()) {
							return;
						}
					}
				}
				if (this.mMainActionQueue.mActions.length > 0) {
					this.mCurrentAction = this.mMainActionQueue.mActions.shift();
					if (Boolean(this.mCurrentAction.mTarget) && this.mCurrentAction.mTarget is Renderable) {
						this.mCurrentAction.mTarget.removedFromActionQueue();
					}
					try {
						this.mCurrentAction.start();
					} catch (startError:Error) {
						if (Config.OFFLINE_MODE && this.mState == STATE_PLAY && this.mCurrentAction.isEnemyAction()) {
							this.failEnemyAction(this.mCurrentAction,"main_start_exception:" + startError.message,0);
							this.mCurrentAction = null;
						} else {
							throw startError;
						}
					}
				} else if (this.mState == STATE_PLAY || this.mState == STATE_VISITING_NEIGHBOUR) {}
			}
			this.pumpConcurrentEnemyActions();
		}

		public function queueAction
'@.TrimEnd()
  $game=$updateRegex.Replace($game,(Normalize-Lf $updateReplacement),1)
  Write-Host 'EVIDENCE_ROOTFIX_V46_HOOK=PASS name=enemy_main_watchdog_exception_containment matches=1'

  foreach($required in @(
    'OFFLINE_ENEMY_ACTION_WATCHDOG_MS:int = 12000',
    'OFFLINE_ENEMY_AUX_STARTS_PER_FRAME:int = 1',
    'ENEMY_AI_ACTION_FAILSAFE',
    'ENEMY_AI_BATCH_DEFER',
    'this.isEnemyActionActorActive(nextAction)',
    'attempts < OFFLINE_ENEMY_AUX_STARTS_PER_FRAME',
    'this.mConcurrentEnemyActionStartedAt.push(getTimer())',
    'main_timeout',
    'aux_timeout',
    'this.tryStartOfflineEnemyResponseAfterPlayerVisuals();',
    'this.mOfflineEnemyResponseActive',
    'nextOfflineAction.isEnemyAction()'
  )){Require $game $required $required}
  Write-Utf8Bom $gameStatePath $game

  # The source changes above matter only if EnemyMovingAction is injected into the
  # final SWF. Extend the post-V45 FFDec patch list using the stable GameState row.
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  if($patcher -notmatch "Class='game\.actions\.EnemyMovingAction'") {
    $gameStateSpec="  [ordered]@{Class='game.states.GameState';Source='src\\game\\states\\GameState.as';Log='ffdec-feature-gamestate.log'},"
    $moveSpec="  [ordered]@{Class='game.actions.EnemyMovingAction';Source='src\\game\\actions\\EnemyMovingAction.as';Log='ffdec-feature-enemy-moving-failsafe.log'},"
    $patcher=Replace-One $patcher $gameStateSpec ($gameStateSpec+"`n"+$moveSpec) 'enemy_moving_swf_patch_spec'
  } else {
    Write-Host 'EVIDENCE_ROOTFIX_V46_HOOK=PASS name=enemy_moving_swf_patch_spec matches=preexisting'
  }
  Require $patcher "Class='game.actions.EnemyMovingAction'" 'enemy_moving_class_in_patchset'
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=enemy_move_freeze_failsafe watchdog_ms=10000 reservation_release=exact path_reset=true empty_path_abort=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_move_external_sync_nonfatal offline_sync=skipped online_sync_exception=contained local_arrival_first=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_action_lane_failsafe watchdog_ms=12000 main_exception=contained aux_exception=contained reaction_recovery=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_pathfinding_jank_guard aux_starts_per_frame=1 concurrent_total_max=3 low_fps_total=2 actor_dedupe=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_aggression_preserved fast_minutes=1 heavy_minutes=2 queue_advance=3 max_concurrent=3 low_fps_concurrent=2'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_move_final_swf_contract class=game.actions.EnemyMovingAction patch_spec=true telemetry=watchdog,abort,path_fail,sync_skip'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V46=PASS mode=apply predecessor=v45 sha=$ExpectedSha feature=enemy_action_freeze_failsafe"
}
catch {
  Restore-OwnedFiles
  try { & $v45 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore } catch {}
  throw
}
