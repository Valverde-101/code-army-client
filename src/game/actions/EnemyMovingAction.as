package game.actions
{
   import flash.geom.Point;
   import game.battlefield.MapData;
   import game.characters.AnimationController;
   import game.characters.EnemyUnit;
   import game.characters.PlayerUnit;
   import game.gameElements.ConstructionObject;
   import game.gameElements.DebrisObject;
   import game.gameElements.EnemyInstallationObject;
   import game.gameElements.PlayerInstallationObject;
   import game.isometric.GridCell;
   import game.isometric.characters.IsometricCharacter;
   import game.isometric.elements.Element;
   import game.isometric.elements.Renderable;
   import game.isometric.elements.WorldObject;
   import game.isometric.pathfinding.AStarPathfinder;
   import game.net.ServiceIDs;
   import game.states.GameState;
   
   public class EnemyMovingAction extends Action
   {
       
      
      protected var mTargetX:int;
      
      protected var mTargetY:int;
      
      protected var mOriginCell:GridCell;
      
      protected var mDestinationCell:GridCell;
      
      public function EnemyMovingAction(param1:IsometricCharacter, param2:GridCell = null, param3:String = "EnemyMove")
      {
         super(param3);
         mActor = param1;
         this.mDestinationCell = param2;
      }
      
      private function findClosestPlayerCell() : GridCell
      {
         var _loc9_:int = 0;
         var _loc10_:GridCell = null;
         var _loc11_:Array = null;
         var _loc12_:GridCell = null;
         var _loc13_:int = 0;
         var _loc14_:GridCell = null;
         var _loc15_:int = 0;
         var _loc16_:Renderable = null;
         var _loc17_:int = 0;
         var _loc18_:int = 0;
         var _loc19_:int = 0;
         var _loc20_:GridCell = null;
         var _loc21_:int = 0;
         var _loc1_:Array = new Array();
         var _loc2_:int = 1;
         var _loc3_:GridCell = mActor.getCell();
         var _loc4_:int = _loc3_.mPosI;
         var _loc5_:int = _loc3_.mPosJ;
         var _loc6_:Boolean = false;
         var _loc7_:Boolean = false;
         var _loc8_:int = _loc4_ - _loc2_;
         while(_loc8_ <= _loc4_ + _loc2_)
         {
            _loc9_ = _loc5_ - _loc2_;
            while(_loc9_ <= _loc5_ + _loc2_)
            {
               _loc10_ = (mActor as Element).mScene.getCellAt(_loc8_,_loc9_);
               _loc7_ = true;
               if(_loc10_)
               {
                  if(_loc10_ != _loc3_)
                  {
                     if(_loc10_.mWalkable || Config.OFFLINE_MODE && _loc10_.mObject is EnemyInstallationObject && ((_loc10_.mObject as EnemyInstallationObject).mItem.mId == "Mines" || (_loc10_.mObject as EnemyInstallationObject).mItem.mId == "Barricade"))
                     {
                        if(_loc10_)
                        {
                           if(_loc10_ == (mActor as IsometricCharacter).mPreviousTile)
                           {
                              _loc7_ = false;
                           }
                           else if(_loc10_.mCharacter)
                           {
                              _loc7_ = false;
                              if(_loc10_.mCharacter is PlayerUnit)
                              {
                                 if(_loc10_.mCharacter.isAlive())
                                 {
                                    _loc1_.length = 0;
                                    _loc6_ = true;
                                    break;
                                 }
                              }
                           }
                           else if(_loc10_.mCharacterComingToThisTile)
                           {
                              _loc7_ = false;
                           }
                           else if(_loc10_.mObject)
                           {
                              _loc7_ = false;
                              if(Config.OFFLINE_MODE && _loc10_.mObject is EnemyInstallationObject && ((_loc10_.mObject as EnemyInstallationObject).mItem.mId == "Mines" || (_loc10_.mObject as EnemyInstallationObject).mItem.mId == "Barricade"))
                              {
                                 _loc7_ = true;
                              }
                              else if(_loc10_.mObject is DebrisObject)
                              {
                                 _loc7_ = true;
                              }
                              else if(_loc10_.mObject is PlayerInstallationObject && (_loc10_.mObject as PlayerInstallationObject).isAlive() || _loc10_.mObject is ConstructionObject && (_loc10_.mObject as ConstructionObject).isAlive() && (_loc10_.mObject as ConstructionObject).mHasBeenCompleted)
                              {
                                 _loc1_.length = 0;
                                 _loc6_ = true;
                                 break;
                              }
                           }
                           if(_loc10_.mOwner == MapData.TILE_OWNER_FRIENDLY)
                           {
                              if(_loc10_.mPosI != _loc4_)
                              {
                                 if(_loc10_.mPosJ != _loc5_)
                                 {
                                    _loc7_ = false;
                                 }
                              }
                           }
                           if(_loc7_)
                           {
                              _loc1_.push(_loc10_);
                           }
                        }
                     }
                  }
               }
               _loc9_++;
            }
            if(_loc6_)
            {
               break;
            }
            _loc8_++;
         }
         if(_loc1_.length > 0)
         {
            _loc11_ = (mActor as Element).mScene.getPlayerUnitsAndObjects();
            _loc13_ = int.MAX_VALUE;
            _loc15_ = int(_loc1_.length);
            _loc17_ = int(_loc11_.length);
            var currentDistance:int = int.MAX_VALUE;
            var currentTargetIndex:int = 0;
            var currentTargetCell:GridCell = null;
            var currentTargetDistance:int = 0;
            while(currentTargetIndex < _loc17_)
            {
               currentTargetCell = (_loc11_[currentTargetIndex] as Renderable).getCell();
               if(currentTargetCell)
               {
                  currentTargetDistance = (_loc3_.mPosI - currentTargetCell.mPosI) * (_loc3_.mPosI - currentTargetCell.mPosI) + (_loc3_.mPosJ - currentTargetCell.mPosJ) * (_loc3_.mPosJ - currentTargetCell.mPosJ);
                  if(currentTargetDistance < currentDistance) currentDistance = currentTargetDistance;
               }
               currentTargetIndex++;
            }
            if(currentDistance == int.MAX_VALUE) return null;
            _loc18_ = 0;
            while(_loc18_ < _loc15_)
            {
               _loc14_ = _loc1_[_loc18_] as GridCell;
               _loc19_ = 0;
               while(_loc19_ < _loc17_)
               {
                  _loc20_ = (_loc16_ = _loc11_[_loc19_] as Renderable).getCell();
                  if((_loc21_ = (_loc14_.mPosI - _loc20_.mPosI) * (_loc14_.mPosI - _loc20_.mPosI) + (_loc14_.mPosJ - _loc20_.mPosJ) * (_loc14_.mPosJ - _loc20_.mPosJ)) < _loc13_ && _loc21_ < currentDistance)
                  {
                     _loc13_ = _loc21_;
                     _loc12_ = _loc14_;
                     if(_loc13_ == 1)
                     {
                        return _loc12_;
                     }
                  }
                  _loc19_++;
               }
               _loc18_++;
            }
            return _loc12_;
         }
         return null;
      }
      
      private function headToThePlayerArea() : GridCell
      {
         var _loc11_:int = 0;
         var _loc12_:GridCell = null;
         var _loc13_:GridCell = null;
         var _loc14_:int = 0;
         var _loc15_:GridCell = null;
         var _loc16_:int = 0;
         var _loc17_:Renderable = null;
         var _loc18_:int = 0;
         var _loc19_:int = 0;
         var _loc20_:int = 0;
         var _loc21_:GridCell = null;
         var _loc22_:int = 0;
         var _loc23_:Array = null;
         var _loc1_:Array = new Array();
         var _loc2_:int = (mActor as EnemyUnit).mMovementRange;
         var _loc3_:GridCell = mActor.getCell();
         var _loc4_:int = _loc3_.mPosI;
         var _loc5_:int = _loc3_.mPosJ;
         var _loc6_:Boolean = false;
         var _loc7_:Boolean = false;
         var _loc8_:Boolean = false;
         var _loc9_:int = _loc4_ - _loc2_;
         while(_loc9_ <= _loc4_ + _loc2_)
         {
            _loc11_ = _loc5_ - _loc2_;
            while(_loc11_ <= _loc5_ + _loc2_)
            {
               _loc8_ = Math.abs(_loc4_ - _loc9_) <= 1 && Math.abs(_loc5_ - _loc11_) <= 1;
               _loc12_ = (mActor as Element).mScene.getCellAt(_loc9_,_loc11_);
               _loc7_ = true;
               if(_loc12_)
               {
                  if(_loc12_ != _loc3_)
                  {
                     if(_loc12_.mWalkable)
                     {
                        if(_loc12_)
                        {
                           if(_loc8_)
                           {
                              _loc7_ = false;
                           }
                           else
                           {
                              if(Boolean(_loc12_.mCharacter) || Boolean(_loc12_.mCharacterComingToThisTile))
                              {
                                 _loc7_ = false;
                              }
                              else if(_loc12_.mObject)
                              {
                                 _loc7_ = false;
                                 if(_loc12_.mObject is DebrisObject)
                                 {
                                    _loc7_ = true;
                                 }
                              }
                              if(_loc7_)
                              {
                                 _loc1_.push(_loc12_);
                              }
                           }
                        }
                     }
                  }
               }
               _loc11_++;
            }
            if(_loc6_)
            {
               break;
            }
            _loc9_++;
         }
         var _loc10_:Array = (mActor as Element).mScene.getPlayerUnitsAndObjects();
         if(_loc1_.length > 0)
         {
            _loc14_ = int.MAX_VALUE;
            _loc16_ = int(_loc1_.length);
            _loc18_ = int(_loc10_.length);
            _loc19_ = 0;
            while(_loc19_ < _loc16_)
            {
               _loc15_ = _loc1_[_loc19_] as GridCell;
               _loc20_ = 0;
               while(_loc20_ < _loc18_)
               {
                  _loc21_ = (_loc17_ = _loc10_[_loc20_] as Renderable).getCell();
                  if((_loc22_ = (_loc15_.mPosI - _loc21_.mPosI) * (_loc15_.mPosI - _loc21_.mPosI) + (_loc15_.mPosJ - _loc21_.mPosJ) * (_loc15_.mPosJ - _loc21_.mPosJ)) < _loc14_)
                  {
                     _loc23_ = new Array();
                     if(AStarPathfinder.findPathAStar(_loc23_,GameState.mInstance.mScene,new Point(_loc4_,_loc5_),new Point(_loc15_.mPosI,_loc15_.mPosJ),(mActor as EnemyUnit).mMovementFlags))
                     {
                        if(_loc15_.mG <= (mActor as EnemyUnit).mMovementRange)
                        {
                           _loc14_ = _loc22_;
                           _loc13_ = _loc15_;
                           if(_loc14_ == 1)
                           {
                              return _loc13_;
                           }
                        }
                     }
                  }
                  _loc20_++;
               }
               _loc19_++;
            }
            return _loc13_;
         }
         return null;
      }
      
      override public function isOver() : Boolean
      {
         if(mSkipped)
         {
            (mActor as EnemyUnit).changeReactionState(EnemyUnit.REACT_STATE_ACTION_COMPLETED);
            return true;
         }
         if((mActor as IsometricCharacter).isStill())
         {
            if((mActor as IsometricCharacter).mDestinationCell)
            {
               if(this.mOriginCell)
               {
                  this.execute();
               }
            }
            (mActor as EnemyUnit).changeReactionState(EnemyUnit.REACT_STATE_ACTION_COMPLETED);
            return true;
         }
         return false;
      }
      
      override public function start() : void
      {
         if(mSkipped)
         {
            return;
         }
         if(mActor == null || !mActor.isAlive())
         {
            skip();
            return;
         }
         if(this.mDestinationCell == null)
         {
            if((mActor as IsometricCharacter).isStealth())
            {
               (mActor as IsometricCharacter).mDestinationCell = this.headToThePlayerArea();
               if((mActor as IsometricCharacter).mDestinationCell)
               {
                  (mActor as EnemyUnit).nullMovementCounter();
               }
               else
               {
                  (mActor as IsometricCharacter).mDestinationCell = this.findClosestPlayerCell();
               }
            }
            else
            {
               (mActor as IsometricCharacter).mDestinationCell = this.findClosestPlayerCell();
               if(!(mActor as IsometricCharacter).mDestinationCell)
               {
                  (mActor as IsometricCharacter).mDestinationCell = this.headToThePlayerArea();
               }
            }
         }
         else
         {
            (mActor as IsometricCharacter).mDestinationCell = this.mDestinationCell;
         }
         if((mActor as IsometricCharacter).mDestinationCell)
         {
            // A campaign move may not jump past the unit's authored movement range,
            // even when an explicit destination comes from a scripted action.
            var moveOrigin:GridCell = mActor.getCell();
            var moveDest:GridCell = (mActor as IsometricCharacter).mDestinationCell;
            var moveRange:int = Math.max(1,(mActor as EnemyUnit).mMovementRange);
            var moveDx:int = moveOrigin ? Math.abs(moveDest.mPosI - moveOrigin.mPosI) : -1;
            var moveDy:int = moveOrigin ? Math.abs(moveDest.mPosJ - moveOrigin.mPosJ) : -1;
            if(Config.OFFLINE_MODE && GameState.mInstance.mState == GameState.STATE_PLAY)
            {
               Utils.DiagEvent("CAMPAIGN_ENEMY_MOVE_RANGE","map=" + GameState.mInstance.mCurrentMapId + ";enemy=" + ((mActor as EnemyUnit).mUnitId) + ";from=" + (moveOrigin ? moveOrigin.mPosI + "," + moveOrigin.mPosJ : "null") + ";to=" + moveDest.mPosI + "," + moveDest.mPosJ + ";dx=" + moveDx + ";dy=" + moveDy + ";range=" + moveRange);
               if(!moveOrigin || Math.max(moveDx,moveDy) > moveRange)
               {
                  Utils.DiagEvent("CAMPAIGN_ENEMY_MOVE_RANGE_REJECTED","map=" + GameState.mInstance.mCurrentMapId + ";enemy=" + ((mActor as EnemyUnit).mUnitId) + ";dx=" + moveDx + ";dy=" + moveDy + ";range=" + moveRange);
                  (mActor as IsometricCharacter).mDestinationCell = null;
                  skip();
                  return;
               }
            }
            (mActor as IsometricCharacter).mDestinationCell.mCharacterComingToThisTile = mActor as IsometricCharacter;
            this.mTargetX = (mActor as WorldObject).mScene.getCenterPointXOfCell((mActor as IsometricCharacter).mDestinationCell);
            this.mTargetY = (mActor as WorldObject).mScene.getCenterPointYOfCell((mActor as IsometricCharacter).mDestinationCell);
            this.mOriginCell = mActor.getCell();
            (mActor as IsometricCharacter).moveTo(this.mTargetX,this.mTargetY);
            (mActor as IsometricCharacter).playCollectionSound((mActor as IsometricCharacter).mMoveSounds);
         }
         else
         {
            skip();
         }
      }
      
      protected function execute() : void
      {
         var arrivalCell:GridCell = (mActor as IsometricCharacter).mDestinationCell ? (mActor as IsometricCharacter).mDestinationCell : mActor.getCell();
         if(!arrivalCell) arrivalCell = mActor.getCell();
         var territoryOwnerBefore:int = arrivalCell ? arrivalCell.mOwner : MapData.TILE_OWNER_NEUTRAL;
         var campaignCapture:Boolean = Config.OFFLINE_MODE && GameState.mInstance.mState == GameState.STATE_PLAY && String(GameState.mInstance.mCurrentMapId).indexOf("pvp_") != 0;
         if(arrivalCell)
         {
            mActor.mScene.characterArrivedInCell(mActor as IsometricCharacter,arrivalCell);
            arrivalCell.mCharacterComingToThisTile = null;
         }
         mActor.setAnimationAction(AnimationController.CHARACTER_ANIMATION_IDLE,false,true);
         var territoryOwnerAfter:int = arrivalCell ? arrivalCell.mOwner : territoryOwnerBefore;
         if(campaignCapture && arrivalCell && territoryOwnerBefore != territoryOwnerAfter)
         {
            Utils.DiagEvent("CAMPAIGN_TERRITORY_CAPTURE","map=" + GameState.mInstance.mCurrentMapId + ";side=enemy;enemy=" + ((mActor as EnemyUnit).mUnitId) + ";x=" + arrivalCell.mPosI + ";y=" + arrivalCell.mPosJ + ";before=" + territoryOwnerBefore + ";after=" + territoryOwnerAfter + ";reason=arrival;visual_commit=scene");
         }
         var _loc1_:GridCell = arrivalCell ? arrivalCell : mActor.getCell();
         var _loc2_:Object = {"coord_x":this.mOriginCell.mPosI,"coord_y":this.mOriginCell.mPosJ,"new_coord_x":_loc1_.mPosI,"new_coord_y":_loc1_.mPosJ};
         GameState.mInstance.mServer.serverCallServiceWithParameters(ServiceIDs.MOVE_ENEMY,_loc2_,false);
         (mActor as IsometricCharacter).mPreviousTile = this.mOriginCell;
         (mActor as IsometricCharacter).mDestinationCell = null;
         GameState.mInstance.enemyMoveMade();

      }
   }
}
