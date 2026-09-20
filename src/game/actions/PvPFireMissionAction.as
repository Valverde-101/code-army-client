package game.actions
{
   import flash.utils.getTimer;
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
      private static var smTraceCounter:int = 0;
      private var mTraceId:String;

      public function PvPFireMissionAction(param1:GridCell, param2:FireMissionItem, param3:String = null, param4:String = null)
      {
         super(param1,param2,param3);
         if(param4 && param4.length > 0)
         {
            this.mTraceId = param4;
         }
         else
         {
            smTraceCounter++;
            this.mTraceId = "FM-" + getTimer() + "-" + smTraceCounter;
            Utils.DiagEvent("TRACE_BEGIN","trace=" + this.mTraceId + ";domain=PVP_FIREMISSION;source=direct_action;mission=" + (param2 ? param2.mId : "null"));
         }
      }

      private function td(param1:String):String
      {
         return "trace=" + this.mTraceId + ";" + param1;
      }
      
      override protected function hasIngredients() : Boolean
      {
         return true;
      }

      override public function start() : void
      {
         Utils.DiagEvent("PVP_FIREMISSION_START",this.td("mission=" + (mItem ? mItem.mId : "null") + ";cell=" + (mGC ? mGC.mPosI + "," + mGC.mPosJ : "null") + ";graphics_override=" + (mGraphicsOverride ? mGraphicsOverride : "default")));
         try
         {
            super.start();
         }
         catch(error:Error)
         {
            Utils.DiagEvent("PVP_FIREMISSION_START_ERROR",this.td("mission=" + (mItem ? mItem.mId : "null") + ";error=" + error.errorID + ";message=" + error.message));
            Utils.DiagEvent("DIAG_FAILURE",this.td("classification=PVP_FIREMISSION_RUNTIME_ERROR;event=PVP_FIREMISSION_START_ERROR;mission=" + (mItem ? mItem.mId : "null") + ";error=" + error.errorID + ";message=" + error.message));
            this.executeFallback();
            skip();
            Utils.DiagEvent("TRACE_END",this.td("domain=PVP_FIREMISSION;result=start_error_fallback"));
         }
      }

      private function executeFallback() : void
      {
         var target:Renderable = null;
         var targetSource:String = "none";
         if(mGC)
         {
            if(mGC.mCharacter)
            {
               target = mGC.mCharacter as Renderable;
               targetSource = "character";
            }
            else if(mGC.mObject)
            {
               target = mGC.mObject as Renderable;
               targetSource = "object";
            }
         }
         Utils.DiagEvent("PVP_FIREMISSION_PHASE",this.td("phase=fallback_select;mission=" + (mItem ? mItem.mId : "null") + ";cell=" + (mGC ? mGC.mPosI + "," + mGC.mPosJ : "null") + ";target_source=" + targetSource + ";target=" + (target && target.mItem ? target.mItem.mId : "none")));
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
         Utils.DiagEvent("PVP_FIREMISSION_FALLBACK",this.td("mission=" + (mItem ? mItem.mId : "null") + ";target_source=" + targetSource + ";target=" + (target && target.mItem ? target.mItem.mId : "none") + ";result=" + (target ? "applied" : "no_target")));
         if(!target)
         {
            Utils.DiagEvent("DIAG_FAILURE",this.td("classification=PVP_FIREMISSION_TARGET_MISSING;event=PVP_FIREMISSION_FALLBACK;mission=" + (mItem ? mItem.mId : "null") + ";cell=" + (mGC ? mGC.mPosI + "," + mGC.mPosJ : "null")));
         }
      }
      
      override protected function execute() : void
      {
         var _loc2_:Renderable = null;
         var _loc1_:GameState = GameState.mInstance;
         Utils.DiagEvent("PVP_FIREMISSION_EXECUTE",this.td("mission=" + (mItem ? mItem.mId : "null") + ";targets=" + (mTargets ? mTargets.length : 0)));
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
         Utils.DiagEvent("PVP_FIREMISSION_RESULT",this.td("mission=" + (mItem ? mItem.mId : "null") + ";result=applied;targets=" + (mTargets ? mTargets.length : 0)));
         Utils.DiagEvent("TRACE_END",this.td("domain=PVP_FIREMISSION;result=applied"));
      }
      
      private function attackUnit(param1:PvPEnemyUnit) : void
      {
         var _loc10_:Item = null;
         if(!param1 || !param1.isAlive())
         {
            Utils.LogError("Firemission: Enemy not found");
            Utils.DiagEvent("DIAG_FAILURE",this.td("classification=PVP_FIREMISSION_TARGET_INVALID;event=PVP_FIREMISSION_TARGET;mission=" + (mItem ? mItem.mId : "null") + ";reason=enemy_missing_or_dead"));
            return;
         }
         var _loc2_:GameState = GameState.mInstance;
         var _loc3_:IsometricScene = _loc2_.mScene;
         var _loc4_:GamePlayerProfile = _loc2_.mPlayerProfile;
         var healthBefore:int = param1.getHealth();
         var _loc5_:* = healthBefore - this.mItem.mDamage <= 0;
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
            Utils.DiagEvent("PVP_LOOT_ROLL_FIREMISSION",this.td("unit=" + param1.mUnitId + ";item=" + (_loc10_ ? _loc10_.mId : "null") + ";firemission=" + this.mItem.mId));
            if(_loc10_)
            {
               _loc2_.mScene.addLootReward(_loc10_,1,param1.getContainer());
               _loc2_.mPvPMatch.addIngameCollectible(_loc10_);
            }
            else
            {
               Utils.DiagEvent("PVP_LOOT_ROLL_EMPTY_FIREMISSION",this.td("unit=" + param1.mUnitId + ";firemission=" + this.mItem.mId));
            }
         }
         param1.reduceHealth(this.mItem.mDamage);
         Utils.DiagEvent("PVP_FIREMISSION_DAMAGE",this.td("mission=" + this.mItem.mId + ";unit=" + param1.mUnitId + ";damage=" + this.mItem.mDamage + ";health_before=" + healthBefore + ";health_after=" + param1.getHealth() + ";killed=" + _loc5_));
      }
   }
}
