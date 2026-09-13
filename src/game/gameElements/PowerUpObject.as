package game.gameElements {
	import flash.display.DisplayObject;
	import flash.geom.Point;
	import flash.utils.getTimer;
	import game.actions.PvPFireMissionAction;
	import game.characters.PlayerUnit;
	import game.characters.PvPEnemyUnit;
	import game.gui.TooltipHealth;
	import game.isometric.GridCell;
	import game.isometric.ImportedObject;
	import game.isometric.IsometricScene;
	import game.isometric.elements.Renderable;
	import game.isometric.characters.IsometricCharacter;
	import game.items.MapItem;
	import game.items.PowerUpItem;
	import game.states.GameState;
	import game.utils.EffectController;

	public class PowerUpObject extends ImportedObject {
		private static var smTraceCounter:int = 0;

		public function PowerUpObject(param1: int, param2: IsometricScene, param3: MapItem, param4: Point, param5: DisplayObject = null, param6: String = null) {
			super(param1, param2, param3, param4, param5, param6);
			var _loc7_: int = (param4.x + 0.5) * param2.mGridDimX;
			var _loc8_: int = (param4.y + 0.5) * param2.mGridDimY;
			setPos(_loc7_, _loc8_, 0);
			mMovable = false;
			var _loc9_: GridCell;
			if (_loc9_ = getCell()) _loc9_.mPowerUp = this;
		}

		private static function nextTraceId(param1:String):String {
			smTraceCounter++;
			return param1 + "-" + getTimer() + "-" + smTraceCounter;
		}

		private function compactStack(param1:Error):String {
			var stack:String = param1 ? param1.getStackTrace() : null;
			if(!stack) return "none";
			stack = stack.split("\r").join("").split("\n").join(" > ");
			return stack.length > 1200 ? stack.substr(0,1200) : stack;
		}

		private function resolvePlayerAirdropGraphics(param1:String):String {
			var id:String = param1 ? param1.toLowerCase() : "";
			var symbol:String = "enemy_airdrop_01";
			if(id.indexOf("infantry") >= 0) symbol = "enemy_infantry_airdrop";
			else if(id.indexOf("commando") >= 0 || id.indexOf("special") >= 0) symbol = "enemy_commando_airdrop";
			return Config.SWF_EFFECTS_NAME + "/" + symbol;
		}

		public function execute(param1: IsometricCharacter): void {
			var powerUp:PowerUpItem = mItem as PowerUpItem;
			var actor:String = param1 is PlayerUnit ? "player" : "enemy";
			var traceId:String = nextTraceId("PWR");
			Utils.DiagEvent("TRACE_BEGIN","trace=" + traceId + ";domain=PVP_POWERUP;id=" + (powerUp ? powerUp.mId : "null") + ";actor=" + actor);
			try {
				this.applyPowerUp(powerUp, param1, 0, traceId);
				Utils.DiagEvent("PVP_POWERUP_EXECUTE_RESULT","trace=" + traceId + ";id=" + (powerUp ? powerUp.mId : "null") + ";actor=" + actor + ";result=success");
				Utils.DiagEvent("TRACE_END","trace=" + traceId + ";domain=PVP_POWERUP;result=success");
			} catch(error:Error) {
				Utils.DiagEvent("PVP_POWERUP_EXECUTE_ERROR","trace=" + traceId + ";id=" + (powerUp ? powerUp.mId : "null") + ";actor=" + actor + ";error=" + error.errorID + ";message=" + error.message + ";stack=" + this.compactStack(error));
				Utils.DiagEvent("DIAG_FAILURE","trace=" + traceId + ";classification=PVP_POWERUP_RUNTIME_ERROR;event=PVP_POWERUP_EXECUTE_ERROR;id=" + (powerUp ? powerUp.mId : "null") + ";error=" + error.errorID + ";message=" + error.message);
				Utils.DiagEvent("TRACE_END","trace=" + traceId + ";domain=PVP_POWERUP;result=error");
			}
		}

		private function applyPowerUp(param1: PowerUpItem, param2: IsometricCharacter, param3: int, param4:String): void {
			if(!param1 || !param2 || param3 > 3) return;
			var targetCell: GridCell = null;
			var targets: Array = null;
			var freeCell: GridCell = null;
			var spawned: Renderable = null;
			var nested: PowerUpItem = null;
			var selectedTarget:IsometricCharacter = null;
			var selectionStart:int = 0;
			var selectionAttempt:int = 0;
			var selectionIndex:int = -1;
			var actor:String = param2 is PlayerUnit ? "player" : "enemy";
			Utils.DiagEvent("PVP_POWERUP_PICKUP","trace=" + param4 + ";id=" + param1.mId + ";actor=" + actor + ";depth=" + param3 + ";health=" + param1.mIncreasedHealth + ";actions=" + param1.mIncreasedActions + ";freeze=" + param1.mFreezeTurns);
			if(param1.mIncreasedHealth > 0) { param2.setHealth(Math.min(param2.getMaxHealth(), param2.getHealth() + param1.mIncreasedHealth)); param2.refreshStatusHints(); }
			if(param1.mIncreasedActions > 0 && GameState.mInstance.mPvPMatch) { GameState.mInstance.mPvPMatch.mActionsLeft += param1.mIncreasedActions; if(GameState.mInstance.mPvPHUD) GameState.mInstance.mPvPHUD.mTextUpdateRequired = true; }
			if(param1.mPowerUpItem && param2 is PlayerUnit) GameState.mInstance.mPlayerProfile.addItem(param1.mPowerUpItem, 1);

			var enemyAirdropGraphics:String = null;
			if(param1.mPowerUpEnemyUnit && param1.mPowerUpEnemyUnit.mGraphicsArray && param1.mPowerUpEnemyUnit.mGraphicsArray.length > 9) enemyAirdropGraphics = param1.mPowerUpEnemyUnit.mGraphicsArray[9] as String;
			if(param1.mPowerUpUnit && param2 is PlayerUnit) {
				freeCell = mScene.getPowerUpSpawnCell(param2.getCell().mPosI,param2.getCell().mPosJ);
				if(freeCell) {
					spawned = mScene.addRewardedPlayerUnit(param1.mPowerUpUnit,freeCell);
					var playerAirdropGraphics:String = this.resolvePlayerAirdropGraphics(param1.mPowerUpUnit.mId);
					var playerDropTrace:String = nextTraceId("PARA");
					Utils.DiagEvent("TRACE_BEGIN","trace=" + playerDropTrace + ";parent_trace=" + param4 + ";domain=PVP_PARATROOPER;side=player;unit=" + param1.mPowerUpUnit.mId);
					Utils.DiagEvent("PVP_PARATROOPER_REQUEST","trace=" + playerDropTrace + ";parent_trace=" + param4 + ";side=player;crate=" + param1.mId + ";unit=" + param1.mPowerUpUnit.mId + ";graphics=" + playerAirdropGraphics + ";cell=" + freeCell.mPosI + "," + freeCell.mPosJ + ";spawned=" + Boolean(spawned));
					var playerDrop:Boolean = spawned && mScene.playPvPPowerUpAirdrop(freeCell,spawned,playerAirdropGraphics,"player",param1.mPowerUpUnit.mId);
					Utils.DiagEvent("PVP_POWERUP_UNIT","trace=" + playerDropTrace + ";parent_trace=" + param4 + ";id=" + param1.mId + ";unit=" + param1.mPowerUpUnit.mId + ";result=spawned;airdrop=" + playerDrop + ";graphics=" + playerAirdropGraphics);
					if(!playerDrop) Utils.DiagEvent("DIAG_FAILURE","trace=" + playerDropTrace + ";parent_trace=" + param4 + ";classification=PARATROOPER_ANIMATION_NOT_STARTED;event=PVP_POWERUP_UNIT;side=player;unit=" + param1.mPowerUpUnit.mId + ";graphics=" + playerAirdropGraphics);
					Utils.DiagEvent("TRACE_HANDOFF","trace=" + playerDropTrace + ";parent_trace=" + param4 + ";domain=PVP_PARATROOPER;result=" + (playerDrop ? "animation_async" : "failed_to_start"));
				} else {
					Utils.DiagEvent("PVP_POWERUP_UNIT","trace=" + param4 + ";id=" + param1.mId + ";result=no_free_cell");
					Utils.DiagEvent("DIAG_FAILURE","trace=" + param4 + ";classification=PVP_SPAWN_NO_FREE_CELL;event=PVP_POWERUP_UNIT;side=player;id=" + param1.mId);
				}
			}
			if(param1.mPowerUpEnemyUnit && param2 is PvPEnemyUnit) {
				freeCell = mScene.getPowerUpSpawnCell(param2.getCell().mPosI,param2.getCell().mPosJ);
				if(freeCell) {
					spawned = mScene.createObject(param1.mPowerUpEnemyUnit,new Point(0,0));
					if(spawned) {
						spawned.setPos(mScene.getCenterPointXOfCell(freeCell),mScene.getCenterPointYOfCell(freeCell),0);
						spawned.getContainer().visible = true;
						spawned.mVisible = true;
						var enemyDropTrace:String = nextTraceId("PARA");
						Utils.DiagEvent("TRACE_BEGIN","trace=" + enemyDropTrace + ";parent_trace=" + param4 + ";domain=PVP_PARATROOPER;side=enemy;unit=" + param1.mPowerUpEnemyUnit.mId);
						Utils.DiagEvent("PVP_PARATROOPER_REQUEST","trace=" + enemyDropTrace + ";parent_trace=" + param4 + ";side=enemy;crate=" + param1.mId + ";unit=" + param1.mPowerUpEnemyUnit.mId + ";graphics=" + enemyAirdropGraphics + ";cell=" + freeCell.mPosI + "," + freeCell.mPosJ + ";spawned=true");
						var enemyDrop:Boolean = mScene.playPvPPowerUpAirdrop(freeCell,spawned,enemyAirdropGraphics,"enemy",param1.mPowerUpEnemyUnit.mId);
						Utils.DiagEvent("PVP_POWERUP_UNIT","trace=" + enemyDropTrace + ";parent_trace=" + param4 + ";id=" + param1.mId + ";unit=" + param1.mPowerUpEnemyUnit.mId + ";result=enemy_spawned;airdrop=" + enemyDrop + ";graphics=" + enemyAirdropGraphics);
						if(!enemyDrop) Utils.DiagEvent("DIAG_FAILURE","trace=" + enemyDropTrace + ";parent_trace=" + param4 + ";classification=PARATROOPER_ANIMATION_NOT_STARTED;event=PVP_POWERUP_UNIT;side=enemy;unit=" + param1.mPowerUpEnemyUnit.mId + ";graphics=" + enemyAirdropGraphics);
						Utils.DiagEvent("TRACE_HANDOFF","trace=" + enemyDropTrace + ";parent_trace=" + param4 + ";domain=PVP_PARATROOPER;result=" + (enemyDrop ? "animation_async" : "failed_to_start"));
					}
				} else {
					Utils.DiagEvent("PVP_POWERUP_UNIT","trace=" + param4 + ";id=" + param1.mId + ";result=enemy_no_free_cell");
					Utils.DiagEvent("DIAG_FAILURE","trace=" + param4 + ";classification=PVP_SPAWN_NO_FREE_CELL;event=PVP_POWERUP_UNIT;side=enemy;id=" + param1.mId);
				}
			}

			if(param1.mPowerUpFireMissionItem && GameState.mInstance.mPvPMatch) {
				var fireTrace:String = nextTraceId("FM");
				Utils.DiagEvent("TRACE_BEGIN","trace=" + fireTrace + ";parent_trace=" + param4 + ";domain=PVP_FIREMISSION;id=" + param1.mId + ";actor=" + actor + ";mission=" + param1.mPowerUpFireMissionItem.mId);
				if(param2 is PlayerUnit) targets = mScene.getPvPEnemyAliveUnits(); else targets = mScene.getPlayerAliveUnits();
				Utils.DiagEvent("PVP_POWERUP_FIREMISSION_SELECT","trace=" + fireTrace + ";parent_trace=" + param4 + ";id=" + param1.mId + ";actor=" + actor + ";mission=" + param1.mPowerUpFireMissionItem.mId + ";candidate_targets=" + (targets ? targets.length : 0));
				Utils.DiagEvent("PVP_POWERUP_FIREMISSION_PHASE","trace=" + fireTrace + ";parent_trace=" + param4 + ";phase=select;id=" + param1.mId + ";actor=" + actor + ";mission=" + param1.mPowerUpFireMissionItem.mId + ";candidate_targets=" + (targets ? targets.length : 0));
				if(targets && targets.length > 0) {
					selectionStart = Math.floor(Math.random() * targets.length);
					selectionAttempt = 0;
					while(selectionAttempt < targets.length && !targetCell) {
						selectionIndex = (selectionStart + selectionAttempt) % targets.length;
						selectedTarget = targets[selectionIndex] as IsometricCharacter;
						if(selectedTarget) targetCell = selectedTarget.getCell();
						selectionAttempt++;
					}
				}
				Utils.DiagEvent("PVP_POWERUP_FIREMISSION_PHASE","trace=" + fireTrace + ";parent_trace=" + param4 + ";phase=selected;id=" + param1.mId + ";actor=" + actor + ";mission=" + param1.mPowerUpFireMissionItem.mId + ";target_index=" + selectionIndex + ";target=" + (selectedTarget && selectedTarget.mItem ? selectedTarget.mItem.mId : "none") + ";cell=" + (targetCell ? targetCell.mPosI + "," + targetCell.mPosJ : "none") + ";attempts=" + selectionAttempt);
				if(targetCell) {
					try {
						Utils.DiagEvent("PVP_POWERUP_FIREMISSION_PHASE","trace=" + fireTrace + ";parent_trace=" + param4 + ";phase=construct_begin;id=" + param1.mId + ";mission=" + param1.mPowerUpFireMissionItem.mId + ";graphics=" + param1.mFireMissionAnimation + ";cell=" + targetCell.mPosI + "," + targetCell.mPosJ);
						var fireAction:PvPFireMissionAction = new PvPFireMissionAction(targetCell,param1.mPowerUpFireMissionItem,param1.mFireMissionAnimation,fireTrace);
						Utils.DiagEvent("PVP_POWERUP_FIREMISSION_PHASE","trace=" + fireTrace + ";parent_trace=" + param4 + ";phase=construct_ready;id=" + param1.mId + ";mission=" + param1.mPowerUpFireMissionItem.mId);
						Utils.DiagEvent("PVP_POWERUP_FIREMISSION_PHASE","trace=" + fireTrace + ";parent_trace=" + param4 + ";phase=queue_begin;id=" + param1.mId + ";mission=" + param1.mPowerUpFireMissionItem.mId);
						GameState.mInstance.queueAction(fireAction,true);
						Utils.DiagEvent("PVP_POWERUP_FIREMISSION_PHASE","trace=" + fireTrace + ";parent_trace=" + param4 + ";phase=queue_ready;id=" + param1.mId + ";mission=" + param1.mPowerUpFireMissionItem.mId);
						Utils.DiagEvent("PVP_POWERUP_FIREMISSION","trace=" + fireTrace + ";parent_trace=" + param4 + ";id=" + param1.mId + ";mission=" + param1.mPowerUpFireMissionItem.mId + ";graphics=" + param1.mFireMissionAnimation + ";result=queued");
					} catch(fireError:Error) {
						Utils.DiagEvent("PVP_POWERUP_FIREMISSION_ERROR","trace=" + fireTrace + ";parent_trace=" + param4 + ";id=" + param1.mId + ";actor=" + actor + ";mission=" + param1.mPowerUpFireMissionItem.mId + ";error=" + fireError.errorID + ";message=" + fireError.message + ";stack=" + this.compactStack(fireError));
						Utils.DiagEvent("DIAG_FAILURE","trace=" + fireTrace + ";parent_trace=" + param4 + ";classification=PVP_FIREMISSION_QUEUE_ERROR;event=PVP_POWERUP_FIREMISSION_ERROR;mission=" + param1.mPowerUpFireMissionItem.mId + ";error=" + fireError.errorID + ";message=" + fireError.message);
						Utils.DiagEvent("TRACE_END","trace=" + fireTrace + ";domain=PVP_FIREMISSION;result=queue_error");
						throw fireError;
					}
				} else {
					Utils.DiagEvent("PVP_POWERUP_FIREMISSION","trace=" + fireTrace + ";parent_trace=" + param4 + ";id=" + param1.mId + ";result=no_target");
					Utils.DiagEvent("DIAG_FAILURE","trace=" + fireTrace + ";parent_trace=" + param4 + ";classification=PVP_FIREMISSION_NO_TARGET;event=PVP_POWERUP_FIREMISSION;mission=" + param1.mPowerUpFireMissionItem.mId + ";candidate_targets=" + (targets ? targets.length : 0));
					Utils.DiagEvent("TRACE_END","trace=" + fireTrace + ";domain=PVP_FIREMISSION;result=no_target");
				}
			} else if(GameState.mInstance.mPvPMatch && param1.mId.indexOf("AirSupport_") == 0) {
				Utils.DiagEvent("PVP_POWERUP_FIREMISSION_MISS","trace=" + param4 + ";id=" + param1.mId + ";reason=missing_mapped_firemission");
				Utils.DiagEvent("DIAG_FAILURE","trace=" + param4 + ";classification=CONFIG_REFERENCE_MISSING;event=PVP_POWERUP_FIREMISSION_MISS;id=" + param1.mId + ";field=mPowerUpFireMissionItem");
			}
			if(param1.mFreezeTurns > 0 && GameState.mInstance.mPvPMatch) GameState.mInstance.mPvPMatch.freezeOpponentTurns(param2 is PlayerUnit,param1.mFreezeTurns);
			nested = param1.getRandomPowerUp();
			if(nested) { Utils.DiagEvent("PVP_POWERUP_RANDOM","trace=" + param4 + ";id=" + param1.mId + ";selected=" + nested.mId); this.applyPowerUp(nested,param2,param3 + 1,param4); }
			if(param1.mEffectGraphics) GameState.mInstance.mScene.addEffect(null,EffectController.EFFECT_TYPE_POWER_UP,param2.mX,param2.mY,param1.mEffectGraphics);
		}

		override public function destroy(): void {
			var _loc1_: GridCell = getCell();
			if (_loc1_) _loc1_.mPowerUp = null;
			super.destroy();
		}

		override public function updateTooltip(param1: int, param2: TooltipHealth): void {
			param2.setTitleText(mItem.mName);
			param2.setDetailsText(mItem.mName);
		}
	}
}
