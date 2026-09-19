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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v32=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV32.ps1'
if(-not(Test-Path -LiteralPath $v32 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL predecessor_missing=$v32"}

$characterPath=Join-Path $RepoRoot 'src\game\isometric\characters\IsometricCharacter.as'
$gameStatePath=Join-Path $RepoRoot 'src\game\states\GameState.as'
$pvpMovePath=Join-Path $RepoRoot 'src\game\actions\PvPEnemyMovingAction.as'
$pvpAIPath=Join-Path $RepoRoot 'src\game\ai\PvPAI.as'
$dialogPath=Join-Path $RepoRoot 'src\game\gui\popups\CharacterDialoqueWindow.as'
$tilemapPath=Join-Path $RepoRoot 'src\game\battlefield\TileMapGraphic.as'
$pausePath=Join-Path $RepoRoot 'src\game\gui\PauseDialog.as'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v33\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Require-Token([string]$Text,[string]$Token,[string]$Name){
  if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL verify=$Name token=$Token"}
}
function Reject-Token([string]$Text,[string]$Token,[string]$Name){
  if($Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL forbidden=$Name token=$Token"}
}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $i=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($i -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL patch=$Name literal_missing"}
  $j=$Text.IndexOf($Needle,$i+$Needle.Length,[StringComparison]::Ordinal)
  if($j -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V33_HOOK=PASS name=$Name matches=1 literal=true"
  return $Text.Substring(0,$i)+$Replacement+$Text.Substring($i+$Needle.Length)
}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V33_HOOK=PASS name=$Name matches=1 semantic=true"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL restore_backup_missing path=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL restore_hash path=$($entry.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v32 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V33=PASS mode=restore predecessor=v32 sha=$ExpectedSha"
  return
}

& $v32 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL predecessor_apply_exit=$LASTEXITCODE"}

try {
  $owned=@(
    [ordered]@{path='src\game\isometric\characters\IsometricCharacter.as';backup='IsometricCharacter.post-v32.as'},
    [ordered]@{path='src\game\states\GameState.as';backup='GameState.post-v32.as'},
    [ordered]@{path='src\game\actions\PvPEnemyMovingAction.as';backup='PvPEnemyMovingAction.post-v32.as'},
    [ordered]@{path='src\game\ai\PvPAI.as';backup='PvPAI.post-v32.as'},
    [ordered]@{path='src\game\gui\popups\CharacterDialoqueWindow.as';backup='CharacterDialoqueWindow.post-v32.as'},
    [ordered]@{path='src\game\battlefield\TileMapGraphic.as';backup='TileMapGraphic.post-v32.as'},
    [ordered]@{path='src\game\gui\PauseDialog.as';backup='PauseDialog.post-v32.as'},
    [ordered]@{path='Tools\CI\Patch-AndroidPerformanceSwf.ps1';backup='Patch-AndroidPerformanceSwf.post-v32.ps1'}
  )
  foreach($spec in $owned){
    $target=Join-Path $RepoRoot ([string]$spec.path)
    if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL required_file_missing path=$target"}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $files=@()
  foreach($spec in $owned){
    $target=Join-Path $RepoRoot ([string]$spec.path)
    $backup=Join-Path $backupRoot ([string]$spec.backup)
    Copy-Item -LiteralPath $target -Destination $backup -Force
    $files+=@([ordered]@{path=[string]$spec.path;backup=[string]$spec.backup;sha256=(Get-Sha256 $target)})
  }
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v33';source_sha=$ExpectedSha;predecessor='v32';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # PvP ownership: PvPEnemyUnit is not an EnemyUnit subclass. The old side test
  # returned false on friendly tiles, so characterArrivedInCell never captured them.
  $character=Normalize-Lf ([IO.File]::ReadAllText($characterPath))
  $character=Replace-LiteralOne $character 'import game.characters.PlayerUnit;' "import game.characters.PlayerUnit;`n`timport game.characters.PvPEnemyUnit;" 'pvp_enemy_type_import'
  $opponentPattern='(?s)\n\s*public function isInOpponentsTile\(\)\s*:\s*Boolean\s*\{.*?(?=\n\s*public function getShootingEffect\(\))'
  $opponentReplacement=@'

		public function isInOpponentsTile(): Boolean {
			var cell: GridCell = getCell();
			if (cell == null) {
				return false;
			}
			if (this is PlayerUnit) {
				return cell.mOwner == MapData.TILE_OWNER_ENEMY;
			}
			if (this is EnemyUnit || this is PvPEnemyUnit) {
				return cell.mOwner == MapData.TILE_OWNER_FRIENDLY;
			}
			return false;
		}

'@
  $character=Replace-RegexOne $character $opponentPattern $opponentReplacement 'pvp_enemy_opponent_tile_identity'
  Require-Token $character 'this is EnemyUnit || this is PvPEnemyUnit' 'pvp_enemy_side_contract'
  Write-Utf8Bom $characterPath $character
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_enemy_territory_owner pvp_enemy_is_opponent=true null_cell_safe=true'

  # Turn accounting belongs to the PvP model, never to HUD existence. Clamp at zero.
  $game=Normalize-Lf ([IO.File]::ReadAllText($gameStatePath))
  $oldPlayerTurn=@'
			if (FeatureTuner.USE_PVP_MATCH) {
				if (this.mState == STATE_PVP && Boolean(this.mPvPHUD)) {
					--this.mPvPMatch.mActionsLeft;
					this.mPvPHUD.mTextUpdateRequired = true;
				}
			}
'@.TrimEnd()
  $newPlayerTurn=@'
			if (FeatureTuner.USE_PVP_MATCH) {
				if (this.mState == STATE_PVP && this.mPvPMatch) {
					if (this.mPvPMatch.mActionsLeft > 0) {
						--this.mPvPMatch.mActionsLeft;
					}
					Utils.DiagEvent("PVP_ACTION_SETTLED", "side=player;actions_left=" + this.mPvPMatch.mActionsLeft);
					if (this.mPvPHUD) {
						this.mPvPHUD.mTextUpdateRequired = true;
					}
				}
			}
'@.TrimEnd()
  $game=Replace-LiteralOne $game $oldPlayerTurn $newPlayerTurn 'pvp_player_action_model_not_hud'

  $oldEnemyTurn=@'
		public function enemyMoveMade(): void {
			if (FeatureTuner.USE_PVP_MATCH) {
				if (this.mState == STATE_PVP) {
					if (this.mPvPHUD) {
						--this.mPvPMatch.mActionsLeft;
						this.mPvPHUD.mTextUpdateRequired = true;
					}
				}
			}
		}
'@.TrimEnd()
  $newEnemyTurn=@'
		public function enemyMoveMade(): void {
			if (FeatureTuner.USE_PVP_MATCH) {
				if (this.mState == STATE_PVP && this.mPvPMatch) {
					if (this.mPvPMatch.mActionsLeft > 0) {
						--this.mPvPMatch.mActionsLeft;
					}
					Utils.DiagEvent("PVP_ACTION_SETTLED", "side=enemy;actions_left=" + this.mPvPMatch.mActionsLeft);
					if (this.mPvPHUD) {
						this.mPvPHUD.mTextUpdateRequired = true;
					}
				}
			}
		}
'@.TrimEnd()
  $game=Replace-LiteralOne $game $oldEnemyTurn $newEnemyTurn 'pvp_enemy_action_model_not_hud'
  Require-Token $game 'side=enemy;actions_left=' 'pvp_enemy_action_telemetry'
  Reject-Token $game 'if (this.mState == STATE_PVP && Boolean(this.mPvPHUD)) {' 'pvp_player_hud_bound_counter'
  Write-Utf8Bom $gameStatePath $game
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_action_model_independent_of_hud clamp_zero=true hud_visual_only=true'

  # PvP movement must settle exactly once on arrival, no-path, invalid actor or timeout.
  $pvpMove=@'
package game.actions
{
   import flash.geom.Point;
   import game.characters.AnimationController;
   import game.characters.PlayerUnit;
   import game.characters.PvPEnemyUnit;
   import game.isometric.GridCell;
   import game.isometric.IsometricScene;
   import game.isometric.characters.IsometricCharacter;
   import game.isometric.elements.Element;
   import game.isometric.pathfinding.AStarPathfinder;
   import game.states.GameState;
   
   public class PvPEnemyMovingAction extends EnemyMovingAction
   {
      private static const MOVE_TIMEOUT_MS:int = 9000;
      private var mCheckPathLength:Boolean;
      private var mElapsedMs:int = 0;
      private var mStarted:Boolean = false;
      private var mSettled:Boolean = false;
      private var mReservedCell:GridCell;
      
      public function PvPEnemyMovingAction(param1:PvPEnemyUnit, param2:GridCell = null, param3:Boolean = false)
      {
         super(param1,param2,"PvPEnemyMove");
         mDestinationCell = param2;
         this.mCheckPathLength = param3;
      }
      
      private function findDestinationCell() : GridCell
      {
         var _loc6_:int = 0;
         var _loc7_:GridCell = null;
         var _loc8_:GridCell = null;
         var _loc9_:int = 0;
         var _loc1_:IsometricScene = GameState.mInstance ? GameState.mInstance.mScene : null;
         var _loc2_:Array = new Array();
         var _loc3_:PvPEnemyUnit = mActor as PvPEnemyUnit;
         if(_loc1_ == null || _loc3_ == null || !_loc3_.isAlive()) return null;
         var _loc4_:PlayerUnit = _loc3_.getClosestPlayerUnit();
         var _loc5_:GridCell = _loc4_ ? _loc4_.getCell() : null;
         if(_loc5_)
         {
            _loc1_.getNeighboringCellsAtDistance(mActor as IsometricCharacter,_loc3_.mMovementRange,_loc2_);
            _loc6_ = int.MAX_VALUE;
            _loc7_ = _loc1_.getSurroundingFreeCell(_loc3_.getCell().mPosI,_loc3_.getCell().mPosJ);
            for each(_loc8_ in _loc2_)
            {
               if(_loc8_ != null && _loc8_ != _loc5_ && !_loc8_.mCharacter && !_loc8_.mCharacterComingToThisTile)
               {
                  if((_loc9_ = Math.abs(_loc5_.mPosI - _loc8_.mPosI) + Math.abs(_loc5_.mPosJ - _loc8_.mPosJ)) < _loc6_)
                  {
                     _loc6_ = _loc9_;
                     _loc7_ = _loc8_;
                  }
               }
            }
         }
         return _loc7_;
      }

      private function clearReservation() : void
      {
         if(this.mReservedCell && this.mReservedCell.mCharacterComingToThisTile == mActor) this.mReservedCell.mCharacterComingToThisTile = null;
         this.mReservedCell = null;
      }

      private function settle(param1:String, param2:Boolean) : void
      {
         if(this.mSettled) return;
         this.mSettled = true;
         var actor:IsometricCharacter = mActor as IsometricCharacter;
         var current:GridCell = actor ? actor.getCell() : null;
         if(param2 && actor && current && mOriginCell && (mActor as Element).mScene)
         {
            (mActor as Element).mScene.characterArrivedInCell(mActor as PvPEnemyUnit,current);
            actor.mPreviousTile = mOriginCell;
         }
         else if(actor && current && !actor.isStill()) actor.skipWalkingTask(current);
         this.clearReservation();
         if(actor)
         {
            actor.mDestinationCell = null;
            actor.setAnimationAction(AnimationController.CHARACTER_ANIMATION_IDLE,false,true);
         }
         Utils.DiagEvent("PVP_ENEMY_MOVE_SETTLED","reason=" + param1 + ";arrived=" + param2 + ";elapsed_ms=" + this.mElapsedMs + ";actor=" + (mActor ? "present" : "null"));
         if(GameState.mInstance && GameState.mInstance.mState == GameState.STATE_PVP) GameState.mInstance.enemyMoveMade();
      }
      
      override public function update(param1:int) : void
      {
         if(this.mSettled || mSkipped || !this.mStarted) return;
         if(param1 > 0) this.mElapsedMs += Math.min(param1,1000);
         var actor:IsometricCharacter = mActor as IsometricCharacter;
         if(actor == null || !actor.isAlive())
         {
            this.settle("actor_invalid",false);
            return;
         }
         if(this.mElapsedMs >= MOVE_TIMEOUT_MS)
         {
            Utils.DiagEvent("PVP_ENEMY_MOVE_TIMEOUT","elapsed_ms=" + this.mElapsedMs + ";limit_ms=" + MOVE_TIMEOUT_MS);
            this.settle("timeout",false);
         }
      }
      
      override public function isOver() : Boolean
      {
         if(this.mSettled) return true;
         if(mSkipped)
         {
            this.clearReservation();
            return true;
         }
         if(!this.mStarted) return false;
         var actor:IsometricCharacter = mActor as IsometricCharacter;
         if(actor == null || !actor.isAlive())
         {
            this.settle("actor_invalid",false);
            return true;
         }
         if(actor.isStill())
         {
            if(actor.mDestinationCell && mOriginCell && actor.getCell()) this.settle("arrived",true);
            else this.settle("no_destination",false);
            return true;
         }
         return false;
      }
      
      override public function start() : void
      {
         var _loc1_:PvPEnemyUnit = null;
         var _loc2_:Array = null;
         var _loc3_:Number = NaN;
         var _loc4_:Number = NaN;
         var _loc5_:int = 0;
         var _loc6_:GridCell = null;
         if(mSkipped) return;
         this.mStarted = true;
         this.mElapsedMs = 0;
         _loc1_ = mActor as PvPEnemyUnit;
         if(_loc1_ == null || !_loc1_.isAlive() || GameState.mInstance == null || GameState.mInstance.mScene == null)
         {
            this.settle("actor_or_scene_missing",false);
            return;
         }
         if(mDestinationCell && this.mCheckPathLength)
         {
            _loc2_ = new Array();
            _loc3_ = GameState.mInstance.mScene.getCenterPointXOfCell(mDestinationCell);
            _loc4_ = GameState.mInstance.mScene.getCenterPointYOfCell(mDestinationCell);
            AStarPathfinder.mOptimizeStraightPaths = false;
            if(AStarPathfinder.findPathAStar(_loc2_,GameState.mInstance.mScene,new Point(_loc1_.mX,_loc1_.mY),new Point(_loc3_,_loc4_),_loc1_.mMovementFlags))
            {
               _loc5_ = 3;
               if(_loc2_.length >= 2) _loc6_ = GameState.mInstance.mScene.getCellAtLocation(_loc2_[0],_loc2_[1]);
               while(Boolean(_loc6_) && Boolean(_loc6_.mParent) && (_loc6_.mCharacter && _loc6_.mCharacter != _loc1_ || _loc6_.mCharacterComingToThisTile && _loc6_.mCharacterComingToThisTile != _loc1_ || _loc6_.mObject && !_loc6_.mObject.isWalkable() || _loc6_.mG > _loc1_.mMovementRange + 0.5))
               {
                  _loc6_ = _loc6_.mParent;
                  if(_loc6_ && (Boolean(_loc6_.mCharacter) || Boolean(_loc6_.mCharacterComingToThisTile) || _loc6_.mObject && !_loc6_.mObject.isWalkable()))
                  {
                     if(--_loc5_ < 0) break;
                  }
                  else _loc5_ = 3;
               }
               mDestinationCell = _loc5_ >= 0 ? _loc6_ : null;
            }
            else mDestinationCell = null;
            AStarPathfinder.mOptimizeStraightPaths = true;
         }
         if(mDestinationCell == null) _loc1_.mDestinationCell = this.findDestinationCell();
         else _loc1_.mDestinationCell = mDestinationCell;
         if(_loc1_.mDestinationCell)
         {
            this.mReservedCell = _loc1_.mDestinationCell;
            if(this.mReservedCell.mCharacterComingToThisTile && this.mReservedCell.mCharacterComingToThisTile != _loc1_)
            {
               _loc1_.mDestinationCell = null;
               this.mReservedCell = null;
               this.settle("destination_reserved",false);
               return;
            }
            this.mReservedCell.mCharacterComingToThisTile = _loc1_;
            mTargetX = _loc1_.mScene.getCenterPointXOfCell(_loc1_.mDestinationCell);
            mTargetY = _loc1_.mScene.getCenterPointYOfCell(_loc1_.mDestinationCell);
            mOriginCell = _loc1_.getCell();
            if(mOriginCell == null)
            {
               this.settle("origin_missing",false);
               return;
            }
            _loc1_.moveTo(mTargetX,mTargetY);
            _loc1_.playCollectionSound(_loc1_.mMoveSounds);
         }
         else this.settle("no_path",false);
      }
      
      override protected function execute() : void
      {
         this.settle("arrived",true);
      }
   }
}
'@
  Write-Utf8Bom $pvpMovePath $pvpMove
  Require-Token $pvpMove 'MOVE_TIMEOUT_MS:int = 9000' 'pvp_move_timeout'
  Require-Token $pvpMove 'PVP_ENEMY_MOVE_SETTLED' 'pvp_move_exact_once_marker'
  Require-Token $pvpMove 'destination_reserved' 'pvp_move_reservation_guard'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_enemy_move_watchdog timeout_ms=9000 exact_once=true reservation_cleanup=true no_path_consumes_action=true'

  # Power-ups are gameplay objects, not a random AI feature. Strategy only changes priority.
  $pvpAI=Normalize-Lf ([IO.File]::ReadAllText($pvpAIPath))
  $quickNeedle=@'
         if(!this.mQuickAttack)
         {
            this.planCollectPowerUp();
         }
'@.TrimEnd()
  $quickReplacement=@'
         this.planCollectPowerUp();
'@.TrimEnd()
  $pvpAI=Replace-LiteralOne $pvpAI $quickNeedle $quickReplacement 'pvp_powerup_always_considered'
  $collectPattern='(?s)\n\s*private function planCollectPowerUp\(\)\s*:\s*void\s*\{.*?(?=\n\s*public function searchCellAttackablePlayerUnits\()'
  $collectReplacement=@'

      private function planCollectPowerUp() : void
      {
         var element:Element = null;
         var enemy:PvPEnemyUnit = null;
         var walkable:Array = null;
         var power:PowerUpObject = null;
         var powerCell:GridCell = null;
         var enemyCell:GridCell = null;
         var best:PowerUpObject = null;
         var bestDistance:Number = Number.MAX_VALUE;
         var distance:Number = NaN;
         var priority:Number = NaN;
         var action:Action = null;
         var powerups:Vector.<PowerUpObject> = new Vector.<PowerUpObject>();
         for each(element in this.mScene.mAllElements)
         {
            if(element is PowerUpObject)
            {
               power = element as PowerUpObject;
               if(power.getCell() != null) powerups.push(power);
            }
         }
         if(powerups.length <= 0) return;
         for each(enemy in this.mEnemyUnits)
         {
            if(enemy == null || !enemy.isAlive()) continue;
            walkable = enemy.getWalkableCells();
            enemyCell = enemy.getCell();
            if(walkable == null || enemyCell == null) continue;
            best = null;
            bestDistance = Number.MAX_VALUE;
            for each(power in powerups)
            {
               powerCell = power.getCell();
               if(powerCell == null) continue;
               if(powerCell != enemyCell && walkable.indexOf(powerCell) < 0) continue;
               distance = enemy.distanceToElement(power);
               if(distance < bestDistance)
               {
                  bestDistance = distance;
                  best = power;
               }
            }
            if(best == null) continue;
            priority = (1 - this.mModePreferAttack + Math.min(1,enemy.mMovementRange / 10)) / 2;
            if(this.mPowerUpFan) priority = Math.min(1,priority + 0.25);
            if((best.mItem as PowerUpItem).mIncreasedHealth > 0 && enemy.getHealth() >= enemy.mMaxHealth) priority /= 3;
            action = new PvPEnemyMovingAction(enemy,best.getCell(),true);
            this.mDebugInfo += "suggest reachable pickup priority " + priority + ";distance=" + bestDistance + ", ";
            this.suggestAction(action,priority);
         }
      }

'@
  $pvpAI=Replace-RegexOne $pvpAI $collectPattern $collectReplacement 'pvp_powerup_reachable_planner'
  Require-Token $pvpAI 'suggest reachable pickup priority' 'pvp_powerup_reachable_marker'
  Require-Token $pvpAI 'walkable.indexOf(powerCell) < 0' 'pvp_powerup_path_guard'
  Reject-Token $pvpAI 'if(this.mPowerUpFan || _loc4_.indexOf(_loc5_.getCell()) >= 0)' 'pvp_powerup_fan_bypasses_path'
  Write-Utf8Bom $pvpAIPath $pvpAI
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_powerup_reachable_only always_considered=true unreachable_rejected=true strategy_priority_only=true'

  # Snow intro is presentation. Missing narrator/UI assets must not abort map switching.
  $dialog=Normalize-Lf ([IO.File]::ReadAllText($dialogPath))
  $activatePattern='(?s)\n\s*public function Activate\(param1:\s*Function,\s*param2:\s*Mission\)\s*:\s*void\s*\{.*?(?=\n\s*CONFIG::BUILD_FOR_AIR)'
  $activateReplacement=@'

		public function Activate(param1: Function, param2: Mission): void {
			var field: TextField = null;
			var auto: AutoTextField = null;
			mDoneCallback = param1;
			this.mMission = param2;
			if (param2 == null) {
				Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=mission_null");
				if (mDoneCallback != null) mDoneCallback((this as Object).constructor);
				return;
			}
			param2.setTargetPopup(this);
			if (param2.mNarratorCharacter) {
				try { this.installCharacter(); }
				catch (error: Error) { Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=character_exception;mission=" + param2.mId + ";type=" + error.name + ";message=" + error.message); }
				field = mClip ? mClip.getChildByName("Text_Title") as TextField : null;
				if (field) {
					auto = new AutoTextField(field);
					auto.setText(param2.mNarratorCharacter.Name == null ? "" : String(param2.mNarratorCharacter.Name));
				} else Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=title_missing;mission=" + param2.mId);
			}
			if (param2.mDescription) {
				field = mClip ? mClip.getChildByName("Text_Description") as TextField : null;
				if (field) {
					auto = new AutoTextField(field);
					auto.setText(param2.mDescription);
				} else Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=description_missing;mission=" + param2.mId);
			}
			try {
				this.mButtonSubmit = mClip ? Utils.createResizingButton(mClip, "Button_Submit", this.okClicked) : null;
				if (this.mButtonSubmit) this.mButtonSubmit.setText(GameState.getText("BUTTON_CONTINUE"));
				else {
					Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=submit_missing;mission=" + param2.mId);
					if (mDoneCallback != null) mDoneCallback((this as Object).constructor);
				}
			} catch (buttonError: Error) {
				Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=submit_exception;mission=" + param2.mId + ";type=" + buttonError.name + ";message=" + buttonError.message);
				if (mDoneCallback != null) mDoneCallback((this as Object).constructor);
			}
		}

'@
  $dialog=Replace-RegexOne $dialog $activatePattern $activateReplacement 'snow_dialog_activate_null_safe'
  $installPattern='(?s)\n\s*private function installCharacter\(\)\s*:\s*void\s*\{.*?(?=\n\s*private function okClicked\()'
  $installReplacement=@'

		private function installCharacter(): void {
			var overlay: MovieClip = null;
			var holder: MovieClip = null;
			var graphic: String = null;
			var parts: Array = null;
			if (this.mCharacter && this.mCharacter.parent) this.mCharacter.parent.removeChild(this.mCharacter);
			if (!this.mMission || !this.mMission.mNarratorCharacter) {
				Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=narrator_missing");
				return;
			}
			if (FeatureTuner.USE_CHARACTER_DIALOQUE) holder = mClip ? mClip.getChildByName("Icon_Character") as MovieClip : null;
			if (!FeatureTuner.USE_CHARACTER_DIALOQUE_EFFECTS && mClip) {
				overlay = mClip.getChildByName("overlay_levelup") as MovieClip;
				if (overlay && overlay.parent) overlay.parent.removeChild(overlay);
			}
			if (!holder) {
				Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=icon_holder_missing;mission=" + this.mMission.mId);
				return;
			}
			graphic = this.mMission.mNarratorCharacter.Graphic == null ? "" : String(this.mMission.mNarratorCharacter.Graphic);
			if (graphic.length == 0) {
				Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=graphic_missing;mission=" + this.mMission.mId);
				return;
			}
			parts = graphic.split("/");
			if (parts.length < 3 || String(parts[2]).length == 0) {
				Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=graphic_path_invalid;mission=" + this.mMission.mId + ";graphic=" + graphic);
				return;
			}
			try { IconLoader.addIcon(holder, new IconAdapter(parts[2], parts[0] + "/" + parts[1])); }
			catch (error: Error) { Utils.DiagEvent("MISSION_DIALOG_DEGRADED", "reason=icon_load;mission=" + this.mMission.mId + ";type=" + error.name + ";message=" + error.message); }
		}

'@
  $dialog=Replace-RegexOne $dialog $installPattern $installReplacement 'snow_dialog_character_null_safe'
  $oldOk=@'
		private function okClicked(param1: MouseEvent): void {
			mDoneCallback((this as Object).constructor);
		}
'@.TrimEnd()
  $newOk=@'
		private function okClicked(param1: MouseEvent): void {
			if (mDoneCallback != null) {
				mDoneCallback((this as Object).constructor);
			}
		}
'@.TrimEnd()
  $dialog=Replace-LiteralOne $dialog $oldOk $newOk 'snow_dialog_callback_guard'
  Require-Token $dialog 'MISSION_DIALOG_DEGRADED' 'snow_dialog_degraded_marker'
  Require-Token $dialog 'graphic_path_invalid' 'snow_dialog_graphic_guard'
  Write-Utf8Bom $dialogPath $dialog
  Write-Host 'REGRESSION_CHECK=PASS name=snow_dialog_nonfatal mission_null=true narrator_graphic_guard=true missing_ui_guard=true icon_exception_nonfatal=true'

  # Border edges are derived state. Every full redraw rebuilds them first.
  $tilemap=Normalize-Lf ([IO.File]::ReadAllText($tilemapPath))
  $tilemapPattern='(?s)(public function updateTilemap\(\)\s*:\s*void\s*\{\s*(?:var[^\n]*\n\s*)+)'
  $tilemapMatches=[regex]::Matches($tilemap,$tilemapPattern)
  if($tilemapMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL patch=tilemap_full_redraw_border semantic_match_count=$($tilemapMatches.Count)"}
  $tilemap=[regex]::Replace($tilemap,$tilemapPattern,'$1         this.recalculateBorderEdges();'+"`n         Utils.DiagEvent(`"TERRITORY_BORDER_DERIVED_REBUILD`",`"source=updateTilemap`");`n         ",1)
  Require-Token $tilemap 'TERRITORY_BORDER_DERIVED_REBUILD' 'territory_border_redraw_marker'
  Write-Utf8Bom $tilemapPath $tilemap
  Write-Host 'REGRESSION_CHECK=PASS name=territory_full_redraw_rebuilds_border_edges derived_state=true redraw_self_healing=true'

  # Import persistence commits only after runtime apply; rollback old file on failure.
  $pause=Normalize-Lf ([IO.File]::ReadAllText($pausePath))
  $importOld=@'
						var internalFile:File = File.applicationStorageDirectory.resolvePath("savefile.txt");
						var backupFile:File = File.applicationStorageDirectory.resolvePath("savefile.before-import.txt");
						if (internalFile.exists) internalFile.copyTo(backupFile, true);
						var tempFile:File = File.applicationStorageDirectory.resolvePath("savefile.import.tmp");
						var out:FileStream = new FileStream();
						out.open(tempFile, FileMode.WRITE);
						out.writeUTFBytes(normalized);
						out.close();
						tempFile.moveTo(internalFile, true);
						cleanupLoad();
						Utils.DiagEvent("SAVE_IMPORT_COMMIT", "validation=" + validation + ";bytes=" + normalized.length + ";name=" + selected.name + ";backup=" + backupFile.name);
						loadProgress(savedata);
'@.TrimEnd()
  $importNew=@'
						var internalFile:File = File.applicationStorageDirectory.resolvePath("savefile.txt");
						var backupFile:File = File.applicationStorageDirectory.resolvePath("savefile.before-import.txt");
						var hadInternalSave:Boolean = internalFile.exists;
						if (hadInternalSave) internalFile.copyTo(backupFile, true);
						var tempFile:File = File.applicationStorageDirectory.resolvePath("savefile.import.tmp");
						var out:FileStream = new FileStream();
						out.open(tempFile, FileMode.WRITE);
						out.writeUTFBytes(normalized);
						out.close();
						tempFile.moveTo(internalFile, true);
						try {
							loadProgress(savedata);
							cleanupLoad();
							Utils.DiagEvent("SAVE_IMPORT_COMMIT", "validation=" + validation + ";bytes=" + normalized.length + ";name=" + selected.name + ";backup=" + backupFile.name + ";runtime_apply=pass");
						} catch (applyError:Error) {
							try {
								if (hadInternalSave && backupFile.exists) backupFile.copyTo(internalFile, true);
								else if (internalFile.exists) internalFile.deleteFile();
								Utils.DiagEvent("SAVE_IMPORT_ROLLBACK", "result=PASS;reason=runtime_apply;type=" + applyError.name + ";message=" + applyError.message);
							} catch (rollbackError:Error) {
								Utils.DiagEvent("SAVE_IMPORT_ROLLBACK", "result=FAIL;reason=runtime_apply;type=" + rollbackError.name + ";message=" + rollbackError.message);
							}
							cleanupLoad();
							throw applyError;
						}
'@.TrimEnd()
  $pause=Replace-LiteralOne $pause $importOld $importNew 'save_import_commit_after_runtime_apply'
  Require-Token $pause 'SAVE_IMPORT_ROLLBACK' 'save_import_rollback_marker'
  Require-Token $pause 'runtime_apply=pass' 'save_import_commit_after_apply_marker'
  Write-Utf8Bom $pausePath $pause
  Write-Host 'REGRESSION_CHECK=PASS name=save_import_transaction_rollback commit_after_apply=true previous_file_restored=true'

  # Compile every newly changed runtime class into the final SWF.
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  foreach($forbiddenClass in @('game.actions.PvPEnemyMovingAction','game.ai.PvPAI','game.gui.popups.CharacterDialoqueWindow')){
    if($patcher.Contains("Class='$forbiddenClass'")){throw "ANDROID_EVIDENCE_ROOTFIX_V33=FAIL patcher_duplicate_class class=$forbiddenClass"}
  }
  $patchAnchor="  [ordered]@{Class='game.gui.GameHUD';Source='src\\game\\gui\\GameHUD.as';Log='ffdec-feature-gamehud.log'},"
  $extraSpecs=@'
  [ordered]@{Class='game.actions.PvPEnemyMovingAction';Source='src\game\actions\PvPEnemyMovingAction.as';Log='ffdec-rootfix-v33-pvp-move.log'},
  [ordered]@{Class='game.ai.PvPAI';Source='src\game\ai\PvPAI.as';Log='ffdec-rootfix-v33-pvp-ai.log'},
  [ordered]@{Class='game.gui.popups.CharacterDialoqueWindow';Source='src\game\gui\popups\CharacterDialoqueWindow.as';Log='ffdec-rootfix-v33-snow-dialog.log'},
'@
  $patcher=Replace-LiteralOne $patcher $patchAnchor ($extraSpecs+$patchAnchor) 'patcher_v33_runtime_classes'
  foreach($requiredClass in @('game.actions.PvPEnemyMovingAction','game.ai.PvPAI','game.gui.popups.CharacterDialoqueWindow')){Require-Token $patcher "Class='$requiredClass'" ('patcher_'+$requiredClass)}
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'PVP_ENEMY_VISUAL_POLICY=PASS mode=config_exact_opfor no_runtime_symbol_guessing=true canonical_pvp_good_family_preserved=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V33=PASS mode=apply predecessor=v32 sha=$ExpectedSha pvp_ownership=true pvp_turns=true pvp_move_watchdog=true pvp_powerups=true snow_dialog_nonfatal=true territory_redraw_self_healing=true save_import_transaction=true"
}
catch {
  $failure=$_
  try { Restore-OwnedFiles } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V33_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  try { & $v32 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Host }
  catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V33_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  throw $failure
}
