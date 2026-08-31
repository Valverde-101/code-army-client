package game.gameElements {
	import flash.display.DisplayObject;
	import flash.geom.Point;
	import game.actions.PvPFireMissionAction;
	import game.characters.PlayerUnit;
	import game.characters.PvPEnemyUnit;
	import game.gui.TooltipHealth;
	import game.isometric.GridCell;
	import game.isometric.ImportedObject;
	import game.isometric.IsometricScene;
	import game.isometric.elements.Renderable;
	import game.isometric.characters.IsometricCharacter;
	import game.items.EnemyUnitItem;
	import game.items.MapItem;
	import game.items.PlayerUnitItem;
	import game.items.PowerUpItem;
	import game.states.GameState;
	import game.utils.EffectController;
	import com.dchoc.graphics.DCResourceManager;

	public class PowerUpObject extends ImportedObject {


		public function PowerUpObject(param1: int, param2: IsometricScene, param3: MapItem, param4: Point, param5: DisplayObject = null, param6: String = null) {
			super(param1, param2, param3, param4, param5, param6);
			var _loc7_: int = (param4.x + 0.5) * param2.mGridDimX;
			var _loc8_: int = (param4.y + 0.5) * param2.mGridDimY;
			setPos(_loc7_, _loc8_, 0);
			mMovable = false;
			var _loc9_: GridCell;
			if (_loc9_ = getCell()) {
				_loc9_.mPowerUp = this;
			}
		}

		public function execute(param1: IsometricCharacter): void {
			this.applyPowerUp(mItem as PowerUpItem, param1, 0);
		}

		private function applyPowerUp(param1: PowerUpItem, param2: IsometricCharacter, param3: int): void {
			if(!param1 || !param2 || param3 > 3) return;
			var targetCell: GridCell = null;
			var targets: Array = null;
			var freeCell: GridCell = null;
			var spawned: Renderable = null;
			var nested: PowerUpItem = null;
			Utils.DiagEvent("PVP_POWERUP_PICKUP","id=" + param1.mId + ";actor=" + (param2 is PlayerUnit ? "player" : "enemy") + ";health=" + param1.mIncreasedHealth + ";actions=" + param1.mIncreasedActions + ";freeze=" + param1.mFreezeTurns);
			if(param1.mIncreasedHealth > 0) { param2.setHealth(Math.min(param2.getMaxHealth(), param2.getHealth() + param1.mIncreasedHealth)); param2.refreshStatusHints(); }
			if(param1.mIncreasedActions > 0 && GameState.mInstance.mPvPMatch) { GameState.mInstance.mPvPMatch.mActionsLeft += param1.mIncreasedActions; if(GameState.mInstance.mPvPHUD) GameState.mInstance.mPvPHUD.mTextUpdateRequired = true; }
			if(param1.mPowerUpItem && param2 is PlayerUnit) GameState.mInstance.mPlayerProfile.addItem(param1.mPowerUpItem, 1);
			if(param1.mPowerUpUnit && param2 is PlayerUnit) {
				freeCell = mScene.getSurroundingFreeCell(param2.getCell().mPosI,param2.getCell().mPosJ);
				if(freeCell) { mScene.addRewardedPlayerUnit(param1.mPowerUpUnit,freeCell); Utils.DiagEvent("PVP_POWERUP_UNIT","id=" + param1.mId + ";unit=" + param1.mPowerUpUnit.mId + ";result=spawned"); }
				else Utils.DiagEvent("PVP_POWERUP_UNIT","id=" + param1.mId + ";result=no_free_cell");
			}
			if(param1.mPowerUpEnemyUnit && param2 is PvPEnemyUnit) {
				freeCell = mScene.getSurroundingFreeCell(param2.getCell().mPosI,param2.getCell().mPosJ);
				if(freeCell) {
					spawned = mScene.createObject(param1.mPowerUpEnemyUnit,new Point(0,0));
					if(spawned) { spawned.setPos(mScene.getCenterPointXOfCell(freeCell),mScene.getCenterPointYOfCell(freeCell),0); spawned.getContainer().visible = true; spawned.mVisible = true; Utils.DiagEvent("PVP_POWERUP_UNIT","id=" + param1.mId + ";unit=" + param1.mPowerUpEnemyUnit.mId + ";result=enemy_spawned"); }
				}
			}
			if(param1.mPowerUpFireMissionItem && GameState.mInstance.mPvPMatch) {
				if(param2 is PlayerUnit) targets = mScene.getPvPEnemyAliveUnits(); else targets = mScene.getPlayerAliveUnits();
				if(targets && targets.length > 0) targetCell = (targets[Math.floor(Math.random() * targets.length)] as IsometricCharacter).getCell();
				if(targetCell) { GameState.mInstance.queueAction(new PvPFireMissionAction(targetCell,param1.mPowerUpFireMissionItem),true); Utils.DiagEvent("PVP_POWERUP_FIREMISSION","id=" + param1.mId + ";mission=" + param1.mPowerUpFireMissionItem.mId + ";result=queued"); }
				else Utils.DiagEvent("PVP_POWERUP_FIREMISSION","id=" + param1.mId + ";result=no_target");
			}
			if(param1.mFreezeTurns > 0 && GameState.mInstance.mPvPMatch) GameState.mInstance.mPvPMatch.freezeOpponentTurns(param2 is PlayerUnit,param1.mFreezeTurns);
			nested = param1.getRandomPowerUp();
			if(nested) { Utils.DiagEvent("PVP_POWERUP_RANDOM","id=" + param1.mId + ";selected=" + nested.mId); this.applyPowerUp(nested,param2,param3 + 1); }
			if(param1.mEffectGraphics) GameState.mInstance.mScene.addEffect(null,EffectController.EFFECT_TYPE_POWER_UP,param2.mX,param2.mY,param1.mEffectGraphics);
		}
		override public function destroy(): void {
			var _loc1_: GridCell = getCell();
			if (_loc1_) {
				_loc1_.mPowerUp = null;
			}
			super.destroy();
		}

		override public function updateTooltip(param1: int, param2: TooltipHealth): void {
			param2.setTitleText(mItem.mName);
			param2.setDetailsText(mItem.mName);
		}
	}
}