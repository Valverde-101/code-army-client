package game.gameElements
{
   import com.dchoc.graphics.DCResourceManager;
   import flash.display.MovieClip;
   import flash.events.Event;
   import flash.utils.getTimer;
   import game.battlefield.MapData;
   import game.characters.PlayerUnit;
   import game.isometric.GridCell;
   import game.isometric.IsometricScene;
   import game.isometric.SceneLoader;
   import game.items.DecorationItem;
   import game.items.FireMissionItem;
   import game.sound.ArmySoundManager;
   import game.sound.SoundCollection;
   import game.states.GameState;
   import game.utils.ColorFadeEffect;
   import game.utils.ScreenShakeEffect;
   
   public class FireMissionObject extends MovieClip
   {
      
      private static const DOOMSDAY_NAME:String = "Doomsday";
      private static const FIREMISSION_TARGET_FPS:Number = 30;
      private static const FIREMISSION_FRAME_MS:Number = 1000 / FIREMISSION_TARGET_FPS;
      private static const FALLBACK_PROJECTILE_MS:int = 900;
      private static const FALLBACK_PROJECTILE_START_Y:Number = -420;
      private static const FALLBACK_TOTAL_TIMEOUT_MS:int = 2600;
       
      
      private var mColorEffectField:ColorFadeEffect;
      
      private var mColorEffectScene:ColorFadeEffect;
      
      private var mShakeEffect:ScreenShakeEffect;
      
      private var mItem:FireMissionItem;
      
      private var mGraphicsOverride:String;
      
      private var mAnim:MovieClip;
      
      private var mGraphicsLoaded:Boolean;
      
      private var mLoadingCallbackEventType:String;
      
      private var mStarted:Boolean;
      
      private var mCells:Array;
      
      private var mSound:SoundCollection;
      
      private var mDebrises:Array;

      private var mAnimationStartMs:int = 0;

      private var mAnimationLastAdvanceMs:int = 0;

      private var mAnimationEndLogged:Boolean = false;

      private var mFallbackProjectileMode:Boolean = false;

      private var mFallbackRocket:MovieClip;

      private var mFallbackExplosion:MovieClip;

      private var mFallbackImpacted:Boolean = false;

      private var mFallbackFinished:Boolean = false;
      
      public function FireMissionObject(param1:FireMissionItem, param2:Array, param3:String = null)
      {
         var _loc5_:Class = null;
         super();
         this.mItem = param1;
         this.mGraphicsOverride = param3;
         this.mCells = param2;
         var _loc3_:DCResourceManager = DCResourceManager.getInstance();
         var _loc4_:String = param1.getIconGraphicsFile();
         if(_loc3_.isLoaded(_loc4_))
         {
            this.mGraphicsLoaded = true;
            if(FeatureTuner.USE_FIRE_CALL_EFFECTS)
            {
               this.materializeGraphics(_loc3_,_loc4_);
            }
         }
         else
         {
            this.mGraphicsLoaded = false;
            this.mLoadingCallbackEventType = _loc4_ + DCResourceManager.EVENT_COMPLETE_SINGLE_FILE;
            _loc3_.addEventListener(this.mLoadingCallbackEventType,this.LoadingFinished,false,0,true);
            if(!_loc3_.isAddedToLoadingList(_loc4_))
            {
               _loc3_.load(Config.DIR_DATA + _loc4_ + ".swf",_loc4_,null,false);
            }
         }
         if(this.mItem.mId == DOOMSDAY_NAME || this.mItem.mId.toLowerCase().indexOf("doomsday") >= 0)
         {
            this.mShakeEffect = new ScreenShakeEffect(GameState.mInstance.mScene.mTilemapGraphic.mFieldBmp,100,12,12);
         }
         this.initSound();
         this.mStarted = false;
      }
      
      private function getGraphicsSymbol() : String
      {
         return this.mGraphicsOverride && this.mGraphicsOverride.length > 0 ? this.mGraphicsOverride : this.mItem.getIconGraphics();
      }

      private function materializeGraphics(param1:DCResourceManager, param2:String) : void
      {
         var graphicsSymbol:String = this.getGraphicsSymbol();
         var graphicsClass:Class = null;
         try
         {
            graphicsClass = param1.getSWFClass(param2,graphicsSymbol);
         }
         catch(error:Error)
         {
            Utils.DiagEvent("FIREMISSION_GRAPHICS_MISS","mission=" + this.mItem.mId + ";resource=" + param2 + ";symbol=" + graphicsSymbol + ";override=" + Boolean(this.mGraphicsOverride) + ";error=" + error.errorID);
         }
         if(graphicsClass != null)
         {
            this.mAnim = new graphicsClass();
            addChild(this.mAnim);
            Utils.DiagEvent("FIREMISSION_GRAPHICS_READY","mission=" + this.mItem.mId + ";resource=" + param2 + ";symbol=" + graphicsSymbol + ";override=" + Boolean(this.mGraphicsOverride) + ";frames=" + this.mAnim.totalFrames);
            return;
         }
         this.materializeFallbackProjectile(param1,graphicsSymbol);
      }

      private function materializeFallbackProjectile(param1:DCResourceManager, param2:String) : void
      {
         var rocketClass:Class = null;
         var impactClass:Class = null;
         try
         {
            rocketClass = param1.getSWFClass(Config.SWF_EFFECTS_NAME,"rocket");
            impactClass = param1.getSWFClass(Config.SWF_EFFECTS_NAME,"effect_explosion");
         }
         catch(error:Error)
         {
            Utils.DiagEvent("FIREMISSION_FALLBACK_MISS","mission=" + this.mItem.mId + ";requested=" + param2 + ";error=" + error.errorID);
            return;
         }
         if(!rocketClass || !impactClass)
         {
            Utils.DiagEvent("FIREMISSION_FALLBACK_MISS","mission=" + this.mItem.mId + ";requested=" + param2 + ";rocket=" + Boolean(rocketClass) + ";impact=" + Boolean(impactClass));
            return;
         }
         this.mFallbackProjectileMode = true;
         this.mFallbackRocket = new rocketClass() as MovieClip;
         this.mFallbackExplosion = new impactClass() as MovieClip;
         if(this.mFallbackRocket)
         {
            this.mFallbackRocket.x = 0;
            this.mFallbackRocket.y = FALLBACK_PROJECTILE_START_Y;
            this.mFallbackRocket.rotation = 180;
            this.mFallbackRocket.mouseEnabled = false;
            this.mFallbackRocket.mouseChildren = false;
            addChild(this.mFallbackRocket);
         }
         if(this.mFallbackExplosion)
         {
            this.mFallbackExplosion.visible = false;
            this.mFallbackExplosion.mouseEnabled = false;
            this.mFallbackExplosion.mouseChildren = false;
            addChild(this.mFallbackExplosion);
         }
         Utils.DiagEvent("FIREMISSION_GRAPHICS_FALLBACK","mission=" + this.mItem.mId + ";requested=" + param2 + ";projectile=rocket;impact=effect_explosion");
      }
      
      public function initSound() : void
      {
         var _loc1_:String = null;
         if(FeatureTuner.USE_ALL_FIRE_CALL_SOUND)
         {
            _loc1_ = this.mItem.mId;
            if(_loc1_ == "Mortar")
            {
               this.mSound = ArmySoundManager.SC_FIRE_MISSION_MORTAR;
            }
            else if(_loc1_ == "Napalm")
            {
               this.mSound = ArmySoundManager.SC_FIRE_MISSION_NAPALM;
            }
            else if(_loc1_ == "Artillery")
            {
               this.mSound = ArmySoundManager.SC_FIRE_MISSION_ARTILLERY;
            }
            else if(_loc1_ == "Doomsday")
            {
               this.mSound = ArmySoundManager.SC_FIRE_MISSION_DOOMSDAY;
            }
            else
            {
               this.mSound = ArmySoundManager.SC_FIRE_MISSION_MORTAR;
            }
         }
         else
         {
            this.mSound = ArmySoundManager.SC_FIRE_MISSION_MORTAR;
         }
         this.mSound.load();
      }
      
      public function LoadingFinished(param1:Event) : void
      {
         var _loc3_:Class = null;
         var _loc2_:DCResourceManager = DCResourceManager.getInstance();
         _loc2_.removeEventListener(param1.type,this.LoadingFinished);
         this.mLoadingCallbackEventType = null;
         this.mGraphicsLoaded = true;
         if(FeatureTuner.USE_FIRE_CALL_EFFECTS)
         {
            this.materializeGraphics(_loc2_,this.mItem.getIconGraphicsFile());
         }
         if(this.mStarted)
         {
            this.start();
         }
      }
      
      public function destroy() : void
      {
         var _loc1_:MovieLoop = null;
         var _loc2_:int = 0;
         var _loc3_:int = 0;
         if(parent)
         {
            parent.removeChild(this);
         }
         if(this.mLoadingCallbackEventType)
         {
            DCResourceManager.getInstance().removeEventListener(this.mLoadingCallbackEventType,this.LoadingFinished);
         }
         if(this.mColorEffectField)
         {
            this.mColorEffectField.destroy();
            this.mColorEffectField = null;
         }
         if(this.mColorEffectScene)
         {
            this.mColorEffectScene.destroy();
            this.mColorEffectScene = null;
         }
         if(this.mShakeEffect)
         {
            this.mShakeEffect.destroy();
            this.mShakeEffect = null;
         }
         if(this.mFallbackRocket)
         {
            this.mFallbackRocket.stop();
            if(this.mFallbackRocket.parent) this.mFallbackRocket.parent.removeChild(this.mFallbackRocket);
            this.mFallbackRocket = null;
         }
         if(this.mFallbackExplosion)
         {
            this.mFallbackExplosion.stop();
            if(this.mFallbackExplosion.parent) this.mFallbackExplosion.parent.removeChild(this.mFallbackExplosion);
            this.mFallbackExplosion = null;
         }
         if(this.mDebrises)
         {
            _loc2_ = int(this.mDebrises.length);
            _loc3_ = 0;
            while(_loc3_ < _loc2_)
            {
               _loc1_ = this.mDebrises[_loc3_] as MovieLoop;
               _loc1_.destroy();
               _loc3_++;
            }
            this.mDebrises = null;
         }
      }
      
      public function start() : void
      {
         this.mStarted = true;
         if(!this.mGraphicsLoaded)
         {
            return;
         }
         this.mAnimationStartMs = getTimer();
         this.mAnimationLastAdvanceMs = this.mAnimationStartMs;
         this.mAnimationEndLogged = false;
         if(FeatureTuner.USE_FIRE_CALL_EFFECTS && this.mAnim)
         {
            this.mAnim.gotoAndStop(1);
            Utils.DiagEvent("FIREMISSION_ANIMATION","phase=start;mission=" + this.mItem.mId + ";symbol=" + this.getGraphicsSymbol() + ";frames=" + this.mAnim.totalFrames + ";target_fps=" + FIREMISSION_TARGET_FPS + ";mode=authored");
         }
         else if(FeatureTuner.USE_FIRE_CALL_EFFECTS && this.mFallbackProjectileMode)
         {
            this.mFallbackImpacted = false;
            this.mFallbackFinished = false;
            if(this.mFallbackRocket)
            {
               this.mFallbackRocket.visible = true;
               this.mFallbackRocket.y = FALLBACK_PROJECTILE_START_Y;
            }
            if(this.mFallbackExplosion)
            {
               this.mFallbackExplosion.visible = false;
               this.mFallbackExplosion.gotoAndStop(1);
            }
            Utils.DiagEvent("FIREMISSION_ANIMATION","phase=start;mission=" + this.mItem.mId + ";symbol=" + this.getGraphicsSymbol() + ";mode=projectile_fallback;duration_ms=" + FALLBACK_PROJECTILE_MS);
         }
         ArmySoundManager.getInstance().playSound(this.mSound.getSound());
      }
      
      public function isOver() : Boolean
      {
         if(!this.mGraphicsLoaded)
         {
            return false;
         }
         if(!FeatureTuner.USE_FIRE_CALL_EFFECTS)
         {
            return true;
         }
         if(this.mFallbackProjectileMode)
         {
            return this.mFallbackFinished;
         }
         if(!this.mAnim)
         {
            return true;
         }
         return this.mAnim.currentFrame >= this.mAnim.totalFrames;
      }
      
      public function update() : void
      {
         var _loc1_:Class = null;
         var _loc2_:int = 0;
         var _loc3_:int = 0;
         var _loc4_:int = 0;
         var _loc5_:IsometricScene = null;
         var _loc6_:GridCell = null;
         var _loc7_:int = 0;
         var _loc8_:int = 0;
         var _loc9_:MovieLoop = null;
         if(!this.mGraphicsLoaded)
         {
            return;
         }
         if(!FeatureTuner.USE_FIRE_CALL_EFFECTS)
         {
            return;
         }
         var nowMs:int = getTimer();
         if(this.mFallbackProjectileMode)
         {
            var fallbackElapsed:int = Math.max(0,nowMs - this.mAnimationStartMs);
            if(!this.mFallbackImpacted)
            {
               var fallbackProgress:Number = Math.min(1,fallbackElapsed / FALLBACK_PROJECTILE_MS);
               if(this.mFallbackRocket)
               {
                  this.mFallbackRocket.y = FALLBACK_PROJECTILE_START_Y * (1 - fallbackProgress);
               }
               if(fallbackProgress >= 1)
               {
                  this.mFallbackImpacted = true;
                  if(this.mFallbackRocket) this.mFallbackRocket.visible = false;
                  if(this.mFallbackExplosion)
                  {
                     this.mFallbackExplosion.visible = true;
                     this.mFallbackExplosion.gotoAndStop(1);
                  }
                  this.mAnimationLastAdvanceMs = nowMs;
                  Utils.DiagEvent("FIREMISSION_ANIMATION","phase=impact;mission=" + this.mItem.mId + ";elapsed_ms=" + fallbackElapsed + ";mode=projectile_fallback");
               }
            }
            else if(this.mFallbackExplosion)
            {
               if(this.mFallbackExplosion.currentFrame >= this.mFallbackExplosion.totalFrames)
               {
                  this.mFallbackFinished = true;
                  this.mFallbackExplosion.visible = false;
               }
               else if(nowMs - this.mAnimationLastAdvanceMs >= FIREMISSION_FRAME_MS)
               {
                  this.mFallbackExplosion.nextFrame();
                  this.mAnimationLastAdvanceMs = nowMs;
               }
            }
            else
            {
               this.mFallbackFinished = true;
            }
            if(fallbackElapsed >= FALLBACK_TOTAL_TIMEOUT_MS)
            {
               this.mFallbackFinished = true;
            }
            if(this.mFallbackFinished && !this.mAnimationEndLogged)
            {
               this.mAnimationEndLogged = true;
               Utils.DiagEvent("FIREMISSION_ANIMATION","phase=end;mission=" + this.mItem.mId + ";elapsed_ms=" + fallbackElapsed + ";mode=projectile_fallback");
            }
            return;
         }
         if(!this.mAnim)
         {
            return;
         }
         if(this.mAnim.currentFrame >= this.mAnim.totalFrames)
         {
            if(!this.mAnimationEndLogged)
            {
               this.mAnimationEndLogged = true;
               Utils.DiagEvent("FIREMISSION_ANIMATION","phase=end;mission=" + this.mItem.mId + ";elapsed_ms=" + Math.max(0,nowMs - this.mAnimationStartMs) + ";frames=" + this.mAnim.totalFrames);
            }
            if(this.mAnim.parent)
            {
               this.mAnim.parent.removeChild(this.mAnim);
            }
         }
         else if(this.mAnimationLastAdvanceMs <= 0 || nowMs - this.mAnimationLastAdvanceMs >= FIREMISSION_FRAME_MS)
         {
            this.mAnim.nextFrame();
            this.mAnimationLastAdvanceMs = nowMs;
            if(this.mAnim.currentFrame >= this.mAnim.totalFrames && !this.mAnimationEndLogged)
            {
               this.mAnimationEndLogged = true;
               Utils.DiagEvent("FIREMISSION_ANIMATION","phase=end;mission=" + this.mItem.mId + ";elapsed_ms=" + Math.max(0,nowMs - this.mAnimationStartMs) + ";frames=" + this.mAnim.totalFrames);
            }
         }
         if(this.mColorEffectField)
         {
            if(this.mAnim.currentFrameLabel == "start_flash" && !this.mColorEffectField.mStarted)
            {
               this.mColorEffectField.mStarted = true;
            }
            else
            {
               this.mColorEffectField.update();
            }
         }
         if(this.mAnim.currentFrameLabel == "debris")
         {
            if(!this.mDebrises)
            {
               _loc1_ = DCResourceManager.getInstance().getSWFClass(Config.SWF_EFFECTS_NAME,"debris_animation");
               if(!_loc1_)
               {
                  this.mDebrises = new Array();
                  Utils.DiagEvent("FIREMISSION_DEBRIS_MISS","mission=" + this.mItem.mId + ";resource=" + Config.SWF_EFFECTS_NAME + ";symbol=debris_animation");
                  return;
               }
               _loc2_ = SceneLoader.GRID_CELL_SIZE;
               _loc3_ = -_loc2_ / 2;
               _loc4_ = -_loc2_ / 2;
               _loc5_ = GameState.mInstance.mScene;
               this.mDebrises = new Array();
               _loc7_ = int(this.mCells.length);
               _loc8_ = 0;
               while(_loc8_ < _loc7_)
               {
                  if(!((_loc6_ = this.mCells[_loc8_] as GridCell).hasFog() || !_loc5_.isInsideVisibleArea(_loc6_) || !MapData.isTilePassable(_loc6_.mType)))
                  {
                     if(!_loc6_.mObject && !_loc6_.mCharacter)
                     {
                        (_loc9_ = new MovieLoop(new _loc1_(),_loc6_.mPosI * _loc2_ - _loc3_,_loc6_.mPosJ * _loc2_ - _loc4_,GameState.mInstance.mScene.mContainer,1,0)).mRemoveInTheEnd = false;
                        this.mDebrises.push(_loc9_);
                     }
                     else if(_loc6_.mObject && (_loc6_.mObject is DecorationObject && (_loc6_.mObject as DecorationObject).getHealth() == 0 && !(_loc6_.mObject.mItem as DecorationItem).mLeaveRuins) || _loc6_.mObject is EnemyInstallationObject && (_loc6_.mObject as EnemyInstallationObject).getHealth() == 0 || _loc6_.mObject is HFEPlotObject && (_loc6_.mObject as HFEPlotObject).getHealth() == 0)
                     {
                        (_loc9_ = new MovieLoop(new _loc1_(),_loc6_.mPosI * _loc2_ - _loc3_,_loc6_.mPosJ * _loc2_ - _loc4_,GameState.mInstance.mScene.mContainer,1,0)).mRemoveInTheEnd = false;
                        this.mDebrises.push(_loc9_);
                     }
                     else if(Boolean(_loc6_.mCharacter) && (!(_loc6_.mCharacter is PlayerUnit) || _loc6_.mCharacter.getHealth() > 0))
                     {
                        (_loc9_ = new MovieLoop(new _loc1_(),_loc6_.mPosI * _loc2_ - _loc3_,_loc6_.mPosJ * _loc2_ - _loc4_,GameState.mInstance.mScene.mContainer,1,0)).mRemoveInTheEnd = false;
                        this.mDebrises.push(_loc9_);
                     }
                  }
                  _loc8_++;
               }
            }
         }
         if(this.mColorEffectScene)
         {
            if(this.mAnim.currentFrameLabel == "start_flash" && !this.mColorEffectScene.mStarted)
            {
               this.mColorEffectScene.mStarted = true;
            }
            else
            {
               this.mColorEffectScene.update();
            }
         }
         if(this.mShakeEffect)
         {
            if(this.mAnim.currentFrameLabel == "start_shake" && !this.mShakeEffect.mStarted)
            {
               this.mShakeEffect.mStarted = true;
            }
            else if(this.mAnim.currentFrameLabel == "end_shake")
            {
               this.mShakeEffect.destroy();
            }
            else
            {
               this.mShakeEffect.update();
            }
         }
      }
   }
}
