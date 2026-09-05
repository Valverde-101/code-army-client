package game.net
{
   import com.dchoc.graphics.DCResourceManager;
   import flash.geom.Point;
   import game.ai.PvPAI;
   import game.characters.PlayerUnit;
   import game.isometric.GridCell;
   import game.isometric.IsometricScene;
   import game.isometric.elements.Renderable;
   import game.items.BoosterItem;
   import game.items.CollectibleItem;
   import game.items.EnemyUnitItem;
   import game.items.Item;
   import game.items.ItemManager;
   import game.items.MapItem;
   import game.items.PlayerUnitItem;
   import game.states.GameState;

   public class PvPMatch
   {
      public static const ACTIONS_PER_TURN:int = 3;

      private var mGame:GameState;
      public var mOpponent:PvPOpponent;
      public var mSupplyCost:int;
      public var mEnergyCost:int;
      public var mPlayerUnits:Array;
      public var mOpponentUnits:Array;
      public var mTimestamp:Number;
      public var mWin:Boolean;
      public var mWinRewardMoney:int;
      public var mWinRewardBadassXp:int;
      public var mIngameBadassXp:int;
      public var mIngameCollectibles:Array;
      public var mActionsLeft:int;
      public var mPlayerTurn:Boolean = true;
      public var mTurnCounter:int;
      public var mAI:PvPAI;
      public var mActivatedBooster:BoosterItem;
      private const TURN_DELAY:int = 2000;
      private var mTurnChangeTimer:int;
      private var mDebriefingOpened:Boolean = false;
      private var mPlayerFrozenTurns:int = 0;
      private var mEnemyFrozenTurns:int = 0;

      public function PvPMatch()
      {
         super();
         this.mGame = GameState.mInstance;
      }

      public function addIngameBaddassXp(param1:int) : void
      {
         this.mIngameBadassXp += param1;
      }

      public function addIngameCollectible(param1:Item) : void
      {
         if(param1 == null) return;
         if(this.mIngameCollectibles == null) this.mIngameCollectibles = new Array();
         this.mIngameCollectibles.push(param1);
         Utils.DiagEvent("PVP_LOOT_TRACK","id=" + param1.mId + ";type=" + param1.mType + ";collectible=" + (param1 is CollectibleItem) + ";count=" + this.mIngameCollectibles.length);
      }

      public function getActiveRangeBoost() : int
      {
         return this.mActivatedBooster ? this.mActivatedBooster.mRangeBoost : 0;
      }

      public function getActivePowerBoost() : int
      {
         return this.mActivatedBooster ? this.mActivatedBooster.mPowerBoost : 0;
      }

      public function getBoostedDamage(param1:int, param2:int = 1) : int
      {
         var actorCount:int = Math.max(1,param2);
         var bonusPerActor:int = this.getActivePowerBoost();
         var result:int = param1 + bonusPerActor * actorCount;
         if(bonusPerActor > 0) trace("[PVP_BOOSTER_DAMAGE] id=" + this.mActivatedBooster.mId + " base=" + param1 + " actors=" + actorCount + " bonus=" + (bonusPerActor * actorCount) + " total=" + result);
         return result;
      }

      public function activateBooster(param1:BoosterItem) : Boolean
      {
         if(!param1 || !this.mGame || !this.mGame.mPlayerProfile || !this.mGame.mPlayerProfile.mInventory) return false;
         var count:int = this.mGame.mPlayerProfile.mInventory.getNumberOfItems(param1);
         if(count <= 0)
         {
            trace("[PVP_BOOSTER_REJECT] id=" + param1.mId + " reason=empty");
            return false;
         }
         if(param1.mHealthBoost > 0)
         {
            var units:Array = this.mGame.mScene ? this.mGame.mScene.getPlayerAliveUnits() : null;
            var unit:PlayerUnit = null;
            var healed:int = 0;
            if(!units || units.length == 0)
            {
               trace("[PVP_BOOSTER_REJECT] id=" + param1.mId + " reason=no_alive_units");
               return false;
            }
            for each(unit in units)
            {
               unit.setHealth(Math.min(unit.getMaxHealth(),unit.getHealth() + param1.mHealthBoost));
               unit.refreshStatusHints();
               healed++;
            }
            this.mGame.mPlayerProfile.mInventory.addItems(param1,-1);
            this.mActivatedBooster = null;
            trace("[PVP_BOOSTER_HEAL] id=" + param1.mId + " amount=" + param1.mHealthBoost + " units=" + healed);
            if(this.mGame.mPvPHUD) this.mGame.mPvPHUD.refreshBoosters();
            return true;
         }
         this.mActivatedBooster = param1;
         trace("[PVP_BOOSTER_ARM] id=" + param1.mId + " power=" + param1.mPowerBoost + " range=" + param1.mRangeBoost + " count=" + count);
         return true;
      }

      public function consumeActionBooster(param1:String) : void
      {
         if(!this.mActivatedBooster || !this.mGame || !this.mGame.mPlayerProfile) return;
         var booster:BoosterItem = this.mActivatedBooster;
         var before:int = this.mGame.mPlayerProfile.mInventory.getNumberOfItems(booster);
         if(before > 0) this.mGame.mPlayerProfile.mInventory.addItems(booster,-1);
         this.mActivatedBooster = null;
         trace("[PVP_BOOSTER_CONSUME] id=" + booster.mId + " reason=" + param1 + " before=" + before + " after=" + this.mGame.mPlayerProfile.mInventory.getNumberOfItems(booster));
         if(this.mGame.mPvPHUD) this.mGame.mPvPHUD.refreshBoosters();
      }

      public function freezeOpponentTurns(param1:Boolean, param2:int) : void
      {
         if(param2 <= 0) return;
         if(param1) this.mEnemyFrozenTurns += param2; else this.mPlayerFrozenTurns += param2;
         Utils.DiagEvent("PVP_FREEZE","source=" + (param1 ? "player" : "enemy") + ";turns=" + param2 + ";player_frozen=" + this.mPlayerFrozenTurns + ";enemy_frozen=" + this.mEnemyFrozenTurns);
      }
      public function setResult(param1:Boolean) : void
      {
         this.mWin = param1;
         if(!param1)
         {
            this.mWinRewardBadassXp = 0;
            this.mWinRewardMoney = 0;
         }
      }

      public function randomizeOpponentUnits() : void
      {
         var _loc3_:int = 0;
         var _loc4_:int = 0;
         var _loc5_:Object = null;
         var _loc6_:int = 0;
         var _loc7_:EnemyUnitItem = null;
         this.mOpponentUnits = new Array();
         if(!this.mOpponent)
         {
            return;
         }
         var _loc1_:int = int(Math.max(0,Math.min(50,this.mOpponent.mBadassLevel)) / 5) * 5;
         var _loc2_:int = 0;
         while(_loc2_ < 24 && this.mOpponentUnits.length < 4)
         {
            _loc3_ = Math.random() * 100;
            _loc4_ = 1;
            while(_loc4_ <= 11)
            {
               _loc5_ = GameState.mConfig.PvPEnemyList[_loc4_];
               if(Boolean(_loc5_) && _loc5_["Level" + _loc1_] != null)
               {
                  _loc6_ = int(_loc5_["Level" + _loc1_]);
                  if(_loc3_ < _loc6_)
                  {
                     _loc7_ = ItemManager.getItem(_loc5_.Unit.ID,_loc5_.Unit.Type) as EnemyUnitItem;
                     if(_loc7_)
                     {
                        this.mOpponentUnits.push(_loc7_);
                     }
                     break;
                  }
                  _loc3_ -= _loc6_;
               }
               _loc4_++;
            }
            _loc2_++;
         }
         var fallbackIds:Array = ["PvPInfantry","PvPAPC","PvPArtillery","PvPRocketBattery"];
         var fallbackIndex:int = 0;
         while(this.mOpponentUnits.length < 2 && fallbackIndex < fallbackIds.length)
         {
            _loc7_ = ItemManager.getItem(fallbackIds[fallbackIndex],"PvPEnemyUnit") as EnemyUnitItem;
            if(_loc7_)
            {
               this.mOpponentUnits.push(_loc7_);
            }
            fallbackIndex++;
         }
      }

      public function initMatch(param1:Object) : void
      {
         this.mDebriefingOpened = false;
         this.mTimestamp = param1.timestamp;
         this.mWin = false;
         this.mIngameBadassXp = 0;
         this.mIngameCollectibles = new Array();
         this.mActivatedBooster = null;
         this.initObjects();
         this.mPlayerTurn = true;
         this.mActionsLeft = ACTIONS_PER_TURN;
         this.mTurnCounter = 0;
         this.mTurnChangeTimer = 0;
         this.mPlayerFrozenTurns = 0;
         this.mEnemyFrozenTurns = 0;
         var _loc2_:int = this.mOpponent.mBadassLevel;
         this.mAI = new PvPAI(this.mGame,this.mGame.mScene,GameState.mConfig.PvPAIWeakenings["" + Math.round(Math.min(50,Math.max(0,_loc2_)))]);
         if(this.mGame.mPvPHUD)
         {
            this.mGame.mPvPHUD.turnChanged(true);
         }
      }

      public function randomizeMap() : String
      {
         var _loc1_:String = null;
         var _loc3_:Object = null;
         var _loc4_:String = null;
         var _loc5_:DCResourceManager = null;
         var _loc2_:Array = new Array();
         for each(_loc3_ in GameState.mConfig.MapSetup)
         {
            _loc1_ = _loc3_.ID as String;
            if(_loc1_ && _loc1_.indexOf("pvp") >= 0)
            {
               _loc2_.push(_loc1_);
            }
         }
         if(_loc2_.length == 0)
         {
            return null;
         }
         _loc1_ = String(_loc2_[int(Math.random() * _loc2_.length)]);
         if(!GameState.mConfig.MapSetup[_loc1_])
         {
            return null;
         }
         _loc4_ = GameState.mConfig.MapSetup[_loc1_].TilemapFileName as String;
         if(!_loc4_ || _loc4_.length == 0)
         {
            return null;
         }
         _loc4_ = _loc4_.substring(0,_loc4_.lastIndexOf("."));
         if(!(_loc5_ = DCResourceManager.getInstance()).isAddedToLoadingList(_loc4_))
         {
            _loc5_.load(Config.DIR_CONFIG + _loc4_ + ".csv",_loc4_,null,true);
         }
         return _loc1_;
      }

      public function getAttackUnitsString() : String
      {
         if(this.mPlayerUnits)
         {
            var _loc3_:PlayerUnitItem = null;
            var _loc1_:* = "";
            var _loc2_:int = 0;
            while(_loc2_ < this.mPlayerUnits.length)
            {
               _loc3_ = this.mPlayerUnits[_loc2_];
               _loc1_ += _loc3_.mId;
               if(_loc2_ < this.mPlayerUnits.length - 1)
               {
                  _loc1_ += ",";
               }
               _loc2_++;
            }
            return _loc1_;
         }
         return null;
      }

      public function getDefensiveUnitsString() : String
      {
         if(this.mOpponentUnits)
         {
            var _loc3_:EnemyUnitItem = null;
            var _loc1_:* = "";
            var _loc2_:int = 0;
            while(_loc2_ < this.mOpponentUnits.length)
            {
               _loc3_ = this.mOpponentUnits[_loc2_];
               _loc1_ += _loc3_.mId;
               if(_loc2_ < this.mOpponentUnits.length - 1)
               {
                  _loc1_ += ",";
               }
               _loc2_++;
            }
            return _loc1_;
         }
         return null;
      }

      public function getIngameCollectiblesString() : String
      {
         var _loc3_:Item = null;
         var _loc1_:Array = new Array();
         var _loc2_:int = 0;
         while(_loc2_ < this.mIngameCollectibles.length)
         {
            _loc3_ = this.mIngameCollectibles[_loc2_] as Item;
            if(_loc3_ is CollectibleItem)
            {
               _loc1_.push(_loc3_.mId);
            }
            _loc2_++;
         }
         return _loc1_.join(",");
      }

      private function requestDebriefing(param1:Boolean) : void
      {
         if(this.mDebriefingOpened)
         {
            return;
         }
         this.mDebriefingOpened = true;
         this.mActionsLeft = 0;
         this.mTurnChangeTimer = 0;
         Utils.DiagEvent("PVP_DEBRIEF_LOOT_SNAPSHOT","win=" + param1 + ";count=" + (this.mIngameCollectibles ? this.mIngameCollectibles.length : 0) + ";collectible_ids=" + this.getIngameCollectiblesString());
         trace("[PVP_DEBRIEF_REQUEST] win=" + param1 + " turn=" + this.mTurnCounter);
         try
         {
            this.mGame.openPvPDebriefing(param1);
         }
         catch(error:Error)
         {
            trace("[PVP_DEBRIEF_FAIL] error=" + error.message);
            this.mDebriefingOpened = false;
            if(this.mGame)
            {
               this.mGame.endPvP();
            }
         }
      }

      public function checkTerminalState() : Boolean
      {
         if(this.mDebriefingOpened)
         {
            return true;
         }
         if(!this.mGame || !this.mGame.mScene)
         {
            return false;
         }
         var enemyCount:int = this.mGame.mScene.getPvPEnemyAliveUnits().length;
         var playerCount:int = this.mGame.mScene.getPlayerAliveUnits().length;
         if(enemyCount == 0 || playerCount == 0)
         {
            trace("[PVP_TERMINAL] enemies_alive=" + enemyCount + " players_alive=" + playerCount + " turn=" + this.mTurnCounter + " actions=" + this.mActionsLeft);
            this.requestDebriefing(enemyCount == 0);
            return true;
         }
         return false;
      }

      public function passPlayerTurn() : Boolean
      {
         if(this.mDebriefingOpened || !this.mPlayerTurn)
         {
            Utils.DiagEvent("PVP_PASS_TURN_REJECT","debrief=" + this.mDebriefingOpened + ";player_turn=" + this.mPlayerTurn + ";actions=" + this.mActionsLeft);
            return false;
         }
         if(this.checkTerminalState())
         {
            return false;
         }
         if(this.mGame)
         {
            this.mGame.cancelAllPlayerActions();
            this.mGame.resetActions();
            this.mGame.mActionWaitingConfirmation = null;
            this.mGame.mActivatedPlayerUnit = null;
         }
         Utils.DiagEvent("PVP_PASS_TURN","turn=" + this.mTurnCounter + ";actions_before=" + this.mActionsLeft);
         this.mActionsLeft = 0;
         this.mTurnChangeTimer = this.TURN_DELAY;
         this.changeTurn();
         Utils.DiagEvent("PVP_PASS_TURN_RESULT","player_turn=" + this.mPlayerTurn + ";actions=" + this.mActionsLeft + ";delay_ms=" + this.mTurnChangeTimer);
         return true;
      }

      public function updateTurn(param1:int) : void
      {
         if(this.checkTerminalState())
         {
            return;
         }
         var _loc2_:IsometricScene = this.mGame.mScene;
         var enemyCount:int = _loc2_.getPvPEnemyAliveUnits().length;
         var playerCount:int = _loc2_.getPlayerAliveUnits().length;
         if(this.mPlayerTurn)
         {
            if(this.mActionsLeft <= 0)
            {
               this.mTurnChangeTimer = this.TURN_DELAY;
               this.changeTurn();
            }
         }
         else
         {
            this.mTurnChangeTimer -= param1;
            if(this.mActionsLeft > 0)
            {
               if(this.mTurnChangeTimer <= 0)
               {
                  this.doEnemyAction();
                  this.mTurnChangeTimer = 0;
               }
            }
            else
            {
               ++this.mTurnCounter;
               this.changeTurn();
            }
         }
      }

      private function doEnemyAction() : void
      {
         if(this.mDebriefingOpened || !this.mGame || !this.mGame.mScene)
         {
            return;
         }
         if(!this.mAI)
         {
            this.mAI = new PvPAI(this.mGame,this.mGame.mScene,GameState.mConfig.PvPAIWeakenings["0"]);
         }
         var queuedBefore:int = this.mGame.mMainActionQueue ? this.mGame.mMainActionQueue.mActions.length : 0;
         try
         {
            this.mAI.makeMove();
         }
         catch(error:Error)
         {
            trace("[PVP_AI_EXCEPTION] turn=" + this.mTurnCounter + " actions=" + this.mActionsLeft + " error=" + error.message);
            this.consumeFailedEnemyAction();
            return;
         }
         var queuedAfter:int = this.mGame.mMainActionQueue ? this.mGame.mMainActionQueue.mActions.length : 0;
         if(!this.mGame.mCurrentAction && queuedAfter <= queuedBefore)
         {
            trace("[PVP_AI_NO_ACTION] turn=" + this.mTurnCounter + " actions=" + this.mActionsLeft);
            this.consumeFailedEnemyAction();
         }
      }

      private function consumeFailedEnemyAction() : void
      {
         if(this.mActionsLeft > 0)
         {
            --this.mActionsLeft;
         }
         this.mTurnChangeTimer = this.TURN_DELAY;
         if(this.mGame && this.mGame.mPvPHUD)
         {
            this.mGame.mPvPHUD.mTextUpdateRequired = true;
         }
      }

      private function changeTurn() : void
      {
         if(this.mDebriefingOpened) return;
         var nextPlayerTurn:Boolean = !this.mPlayerTurn;
         if(nextPlayerTurn && this.mPlayerFrozenTurns > 0) { --this.mPlayerFrozenTurns; nextPlayerTurn = false; Utils.DiagEvent("PVP_FREEZE_SKIP","side=player;remaining=" + this.mPlayerFrozenTurns); }
         else if(!nextPlayerTurn && this.mEnemyFrozenTurns > 0) { --this.mEnemyFrozenTurns; nextPlayerTurn = true; Utils.DiagEvent("PVP_FREEZE_SKIP","side=enemy;remaining=" + this.mEnemyFrozenTurns); }
         this.mActionsLeft = ACTIONS_PER_TURN;
         this.mPlayerTurn = nextPlayerTurn;
         if(this.mGame.mPvPHUD) { this.mGame.mPvPHUD.mTextUpdateRequired = true; this.mGame.mPvPHUD.turnChanged(this.mPlayerTurn); }
      }

      public function initObjects() : void
      {
         var _loc2_:Renderable = null;
         var _loc3_:Object = null;
         var _loc4_:MapItem = null;
         var _loc5_:GridCell = null;
         var _loc6_:int = 0;
         var _loc7_:Array = null;
         var _loc8_:Array = null;
         var _loc9_:Array = null;
         var _loc10_:Array = null;
         var _loc11_:int = 0;
         var _loc12_:int = 0;
         var _loc13_:int = 0;
         var _loc14_:int = 0;
         var _loc15_:Object = null;
         var _loc16_:EnemyUnitItem = null;
         var _loc17_:Array = null;
         var _loc18_:int = 0;
         var _loc19_:int = 0;
         var _loc20_:PlayerUnitItem = null;
         var _loc21_:Array = null;
         var _loc22_:int = 0;
         var _loc23_:Boolean = false;
         var _loc24_:Number = 0;
         var _loc25_:int = 0;
         var _loc26_:Number = 0;
         var _loc27_:int = -1;
         var _loc28_:Number = 0;
         var _loc1_:IsometricScene = this.mGame.mScene;
         if(this.mGame.mMapData.mMapSetupData.SetupSet)
         {
            for each(_loc3_ in GameState.mConfig.PVPAreaSetup)
            {
               if(_loc3_.SetupSet == this.mGame.mMapData.mMapSetupData.SetupSet)
               {
                  _loc7_ = _loc1_.getFreeCellsInTheArea(_loc3_.X,_loc3_.Y,_loc3_.Width,_loc3_.Height);
                  if(_loc3_.SpawnObjects)
                  {
                     _loc8_ = _loc3_.SpawnObjects is Array ? _loc3_.SpawnObjects : new Array(_loc3_.SpawnObjects);
                     _loc9_ = _loc3_.SpawnObjectsPercentage is Array ? _loc3_.SpawnObjectsPercentage : new Array(_loc3_.SpawnObjectsPercentage);
                     _loc10_ = _loc3_.SpawnObjectsAmount is Array ? _loc3_.SpawnObjectsAmount : new Array(_loc3_.SpawnObjectsAmount);
                     _loc24_ = 0;
                     _loc11_ = 0;
                     while(_loc11_ < _loc9_.length)
                     {
                        _loc24_ += Number(_loc9_[_loc11_]);
                        _loc11_++;
                     }
                     _loc23_ = _loc8_.length > 1 && _loc9_.length == _loc8_.length && _loc10_.length == 1 && _loc24_ > 0 && _loc24_ <= 100.0001;
                     if(_loc23_)
                     {
                        _loc13_ = int(_loc10_[0]);
                        if(_loc13_ < 0)
                        {
                           _loc13_ = 0;
                        }
                        Utils.DiagEvent("PVP_AREA_WEIGHTED_MODE","area=" + _loc3_.ID + ";type=" + _loc3_.SpawningAreaType + ";choices=" + _loc8_.length + ";amount=" + _loc13_ + ";chance_total=" + _loc24_);
                        _loc14_ = 0;
                        while(_loc14_ < _loc13_)
                        {
                           if(_loc7_.length == 0)
                           {
                              break;
                           }
                           _loc26_ = 100 * Math.random();
                           _loc28_ = 0;
                           _loc27_ = -1;
                           _loc11_ = 0;
                           while(_loc11_ < _loc9_.length)
                           {
                              _loc28_ += Number(_loc9_[_loc11_]);
                              if(_loc26_ < _loc28_)
                              {
                                 _loc27_ = _loc11_;
                                 break;
                              }
                              _loc11_++;
                           }
                           if(_loc27_ >= 0)
                           {
                              _loc12_ = int(_loc9_[_loc27_]);
                              _loc15_ = _loc8_[_loc27_] as Object;
                              _loc6_ = int(_loc7_.length * Math.random());
                              _loc5_ = _loc7_[_loc6_];
                              _loc7_.splice(_loc6_,1);
                              Utils.DiagEvent("PVP_AREA_WEIGHTED_SPAWN","area=" + _loc3_.ID + ";type=" + _loc3_.SpawningAreaType + ";choice=" + _loc27_ + ";id=" + _loc15_.ID + ";chance=" + _loc12_ + ";roll=" + int(_loc26_) + ";attempt=" + _loc14_ + ";amount=" + _loc13_);
                              if(_loc3_.SpawningAreaType == "ObstacleSpawning")
                              {
                                 _loc4_ = ItemManager.getItem(_loc15_.ID,_loc15_.Type) as MapItem;
                                 if(_loc4_)
                                 {
                                    _loc2_ = _loc1_.createObject(_loc4_,new Point(0,0));
                                    _loc2_.setPos(_loc1_.getCenterPointXOfCell(_loc5_),_loc1_.getCenterPointYOfCell(_loc5_),0);
                                 }
                                 else
                                 {
                                    Utils.DiagEvent("PVP_AREA_WEIGHTED_CONFIG_MISS","area=" + _loc3_.ID + ";id=" + _loc15_.ID + ";type=" + _loc15_.Type);
                                 }
                              }
                              else if(_loc3_.SpawningAreaType == "PowerUpSpawning")
                              {
                                 Utils.DiagEvent("PVP_POWERUP_SPAWN_CONFIG","id=" + _loc15_.ID + ";chance=" + _loc12_ + ";amount=" + _loc13_ + ";weighted=true;i=" + _loc5_.mPosI + ";j=" + _loc5_.mPosJ);
                                 _loc1_.addPowerUpToMap(_loc15_.ID,_loc5_);
                              }
                           }
                           else
                           {
                              Utils.DiagEvent("PVP_AREA_WEIGHTED_MISS","area=" + _loc3_.ID + ";type=" + _loc3_.SpawningAreaType + ";roll=" + int(_loc26_) + ";chance_total=" + _loc24_ + ";attempt=" + _loc14_);
                           }
                           _loc14_++;
                        }
                     }
                     else
                     {
                        _loc11_ = 0;
                        while(_loc11_ < _loc8_.length)
                        {
                           _loc12_ = _loc11_ < _loc9_.length ? int(_loc9_[_loc11_]) : 0;
                           _loc13_ = _loc11_ < _loc10_.length ? int(_loc10_[_loc11_]) : 0;
                           _loc14_ = 0;
                           while(_loc14_ < _loc13_)
                           {
                              if(_loc7_.length == 0)
                              {
                                 break;
                              }
                              if(100 * Math.random() < _loc12_)
                              {
                                 _loc6_ = int(_loc7_.length * Math.random());
                                 _loc5_ = _loc7_[_loc6_];
                                 _loc7_.splice(_loc6_,1);
                                 _loc15_ = _loc8_[_loc11_] as Object;
                                 if(_loc3_.SpawningAreaType == "ObstacleSpawning")
                                 {
                                    _loc4_ = ItemManager.getItem(_loc15_.ID,_loc15_.Type) as MapItem;
                                    if(!_loc4_)
                                    {
                                       break;
                                    }
                                    _loc2_ = _loc1_.createObject(_loc4_,new Point(0,0));
                                    _loc2_.setPos(_loc1_.getCenterPointXOfCell(_loc5_),_loc1_.getCenterPointYOfCell(_loc5_),0);
                                 }
                                 else if(_loc3_.SpawningAreaType == "PowerUpSpawning")
                                 {
                                    Utils.DiagEvent("PVP_POWERUP_SPAWN_CONFIG","id=" + _loc15_.ID + ";chance=" + _loc12_ + ";amount=" + _loc13_ + ";weighted=false;i=" + _loc5_.mPosI + ";j=" + _loc5_.mPosJ);
                                    _loc1_.addPowerUpToMap(_loc15_.ID,_loc5_);
                                 }
                              }
                              _loc14_++;
                           }
                           _loc11_++;
                        }
                     }
                  }
                  else if(_loc3_.SpawningAreaType == "EnemySpawning")
                  {
                     if(this.mOpponentUnits != null)
                     {
                        for each(_loc16_ in this.mOpponentUnits)
                        {
                           if(_loc7_.length == 0)
                           {
                              break;
                           }
                           _loc6_ = _loc7_.length * Math.random();
                           _loc5_ = _loc7_[_loc6_];
                           _loc7_.splice(_loc6_,1);
                           _loc2_ = _loc1_.createObject(_loc16_,new Point(0,0));
                           _loc2_.setPos(_loc1_.getCenterPointXOfCell(_loc5_),_loc1_.getCenterPointYOfCell(_loc5_),0);
                        }
                     }
                     else
                     {
                        (_loc17_ = new Array())[0] = "PvPInfantry";
                        _loc17_[1] = "PvPAPC";
                        _loc17_[2] = "PvPArtillery";
                        _loc17_[3] = "PvPRocketBattery";
                        _loc18_ = 0;
                        while(_loc18_ < 4)
                        {
                           if(_loc7_.length == 0)
                           {
                              break;
                           }
                           _loc6_ = _loc7_.length * Math.random();
                           _loc5_ = _loc7_[_loc6_];
                           _loc7_.splice(_loc6_,1);
                           _loc19_ = _loc17_.length * Math.random();
                           _loc4_ = ItemManager.getItem(_loc17_[_loc19_],"PvPEnemyUnit") as MapItem;
                           if(_loc4_)
                           {
                              _loc2_ = _loc1_.createObject(_loc4_,new Point(0,0));
                              _loc2_.setPos(_loc1_.getCenterPointXOfCell(_loc5_),_loc1_.getCenterPointYOfCell(_loc5_),0);
                           }
                           _loc18_++;
                        }
                     }
                  }
                  else if(_loc3_.SpawningAreaType == "PlayerSpawning")
                  {
                     if(this.mPlayerUnits != null)
                     {
                        for each(_loc20_ in this.mPlayerUnits)
                        {
                           if(_loc7_.length == 0)
                           {
                              break;
                           }
                           _loc6_ = _loc7_.length * Math.random();
                           _loc5_ = _loc7_[_loc6_];
                           _loc7_.splice(_loc6_,1);
                           _loc2_ = _loc1_.createObject(_loc20_,new Point(0,0));
                           _loc2_.setPos(_loc1_.getCenterPointXOfCell(_loc5_),_loc1_.getCenterPointYOfCell(_loc5_),0);
                        }
                     }
                     else
                     {
                        (_loc21_ = new Array())[0] = "Infantry";
                        _loc21_[1] = "Infantry";
                        _loc21_[2] = "ArmoredCar";
                        _loc21_[3] = "Armor";
                        _loc21_[4] = "GunBattery";
                        _loc21_[5] = "Artillery";
                        _loc21_[6] = "MobileRocketBattery";
                        _loc21_[7] = "Artillery";
                        _loc22_ = 0;
                        while(_loc22_ < 4)
                        {
                           if(_loc7_.length == 0)
                           {
                              break;
                           }
                           _loc6_ = _loc7_.length * Math.random();
                           _loc5_ = _loc7_[_loc6_];
                           _loc7_.splice(_loc6_,1);
                           _loc19_ = int(4 * Math.random()) * 2;
                           _loc4_ = ItemManager.getItem(_loc21_[_loc19_],_loc21_[_loc19_ + 1]) as MapItem;
                           if(_loc4_)
                           {
                              _loc2_ = _loc1_.createObject(_loc4_,new Point(0,0));
                              _loc2_.setPos(_loc1_.getCenterPointXOfCell(_loc5_),_loc1_.getCenterPointYOfCell(_loc5_),0);
                           }
                           _loc22_++;
                        }
                     }
                  }
               }
            }
         }
      }
   }
}