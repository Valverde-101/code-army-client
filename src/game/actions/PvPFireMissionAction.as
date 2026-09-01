package game.actions
{
   import game.actions.FireMissionAction;
   import game.characters.PlayerUnit;
   import game.characters.PvPEnemyUnit;
   import game.gameElements.PlayerBuildingObject;
   import game.gameElements.PlayerInstallationObject;
   import game.gameElements.ResourceBuildingObject;
   import game.gameElements.SignalObject;
   import game.isometric.GridCell;
   import game.isometric.IsometricScene;
   import game.isometric.elements.Renderable;
   import game.items.FireMissionItem;
   import game.items.Item;
   import game.items.ItemManager;
   import game.items.TargetItem;
   import game.player.GamePlayerProfile;
   import game.states.GameState;
   
   public class PvPFireMissionAction extends FireMissionAction
   {
       
      
      public function PvPFireMissionAction(param1:GridCell, param2:FireMissionItem)
      {
         super(param1,param2);
      }
      
      override protected function hasIngredients() : Boolean
      {
         return true;
      }

      override public function start() : void
      {
         Utils.DiagEvent("PVP_FIREMISSION_START","mission=" + (mItem ? mItem.mId : "null") + ";cell=" + (mGC ? mGC.mPosI + "," + mGC.mPosJ : "null"));
         try
         {
            super.start();
         }
         catch(error:Error)
         {
            Utils.DiagEvent("PVP_FIREMISSION_START_ERROR","mission=" + (mItem ? mItem.mId : "null") + ";error=" + error.errorID + ";message=" + error.message);
            this.executeFallback();
            skip();
         }
      }

      private function executeFallback() : void
      {
         var target:Renderable = mGC ? mGC.mCharacter as Renderable : null;
         if(target is PlayerUnit)
         {
            damageOwnUnit(PlayerUnit(target));
         }
         else if(target is PlayerBuildingObject)
         {
            if(!(target is ResourceBuildingObject || target is SignalObject))
            {
               damageOwnBuilding(PlayerBuildingObject(target));
            }
         }
         else if(target is PlayerInstallationObject)
         {
            damageOwnInstallation(PlayerInstallationObject(target));
         }
         else if(target is PvPEnemyUnit)
         {
            this.attackUnit(PvPEnemyUnit(target));
         }
         GameState.mInstance.updateGrid();
         Utils.DiagEvent("PVP_FIREMISSION_FALLBACK","mission=" + (mItem ? mItem.mId : "null") + ";target=" + (target && target.mItem ? target.mItem.mId : "none"));
      }
      
      override protected function execute() : void
      {
         var _loc2_:Renderable = null;
         var _loc1_:GameState = GameState.mInstance;
         Utils.DiagEvent("PVP_FIREMISSION_EXECUTE","mission=" + (mItem ? mItem.mId : "null") + ";targets=" + (mTargets ? mTargets.length : 0));
         for each(_loc2_ in mTargets)
         {
            if(_loc2_.mScene)
            {
               if(_loc2_ is PlayerUnit)
               {
                  damageOwnUnit(PlayerUnit(_loc2_));
               }
               else if(_loc2_ is PlayerBuildingObject)
               {
                  if(!(_loc2_ is ResourceBuildingObject || _loc2_ is SignalObject))
                  {
                     damageOwnBuilding(PlayerBuildingObject(_loc2_));
                  }
               }
               else if(_loc2_ is PlayerInstallationObject)
               {
                  damageOwnInstallation(_loc2_ as PlayerInstallationObject);
               }
               else if(_loc2_ is PvPEnemyUnit)
               {
                  this.attackUnit(_loc2_ as PvPEnemyUnit);
               }
            }
         }
         _loc1_.updateGrid();
         Utils.DiagEvent("PVP_FIREMISSION_RESULT","mission=" + (mItem ? mItem.mId : "null") + ";result=applied");
      }
      
      private function attackUnit(param1:PvPEnemyUnit) : void
      {
         var _loc10_:Item = null;
         if(!param1 || !param1.isAlive())
         {
            Utils.LogError("Firemission: Enemy not found");
            return;
         }
         var _loc2_:GameState = GameState.mInstance;
         var _loc3_:IsometricScene = _loc2_.mScene;
         var _loc4_:GamePlayerProfile = _loc2_.mPlayerProfile;
         var _loc5_:* = param1.getHealth() - this.mItem.mDamage <= 0;
         var _loc6_:int = param1.mHitRewardXP;
         var _loc7_:int = param1.mHitRewardMoney;
         var _loc8_:int = param1.mHitRewardMaterial;
         var _loc9_:int = param1.mHitRewardSupplies;
         if(_loc5_)
         {
            _loc6_ += param1.mKillRewardXP;
            _loc7_ += param1.mKillRewardMoney;
            _loc9_ += param1.mKillRewardSupplies;
         }
         _loc2_.mScene.addLootReward(ItemManager.getItem("XP","Resource"),_loc6_,param1.getContainer());
         _loc2_.mScene.addLootReward(ItemManager.getItem("Money","Resource"),_loc7_,param1.getContainer());
         _loc2_.mScene.addLootReward(ItemManager.getItem("Supplies","Resource"),_loc9_,param1.getContainer());
         if(_loc5_)
         {
            ++mKilledEnemyCount;
            _loc10_ = (param1.mItem as TargetItem).getRandomItemDrop();
            Utils.DiagEvent("PVP_LOOT_ROLL_FIREMISSION","unit=" + param1.mUnitId + ";item=" + (_loc10_ ? _loc10_.mId : "null") + ";firemission=" + this.mItem.mId);
            if(_loc10_)
            {
               _loc2_.mScene.addLootReward(_loc10_,1,param1.getContainer());
               _loc2_.mPvPMatch.addIngameCollectible(_loc10_);
            }
            else
            {
               Utils.DiagEvent("PVP_LOOT_ROLL_EMPTY_FIREMISSION","unit=" + param1.mUnitId + ";firemission=" + this.mItem.mId);
            }
         }
         param1.reduceHealth(this.mItem.mDamage);
      }
   }
}
