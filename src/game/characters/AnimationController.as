package game.characters
{
   import com.dchoc.graphics.DCResourceManager;
   import flash.display.DisplayObject;
   import flash.display.MovieClip;
   import flash.events.Event;
   import flash.utils.getTimer;
   import game.isometric.elements.Renderable;
   import game.isometric.characters.IsometricCharacter;

   public class AnimationController
   {
      public static const DIR_RIGHT:int = 0;
      public static const DIR_LEFT:int = 1;
      public static const DIR_UP:int = 3;

      public static const CHARACTER_ANIMATION_IDLE:int = 0;
      public static const CHARACTER_ANIMATION_MOVE:int = 1;
      public static const CHARACTER_ANIMATION_AIM:int = 2;
      public static const CHARACTER_ANIMATION_SHOOT:int = 3;
      public static const CHARACTER_ANIMATION_HIT:int = 4;
      public static const CHARACTER_ANIMATION_DYING:int = 5;
      public static const CHARACTER_ANIMATION_AIM_UP:int = 6;
      public static const CHARACTER_ANIMATION_SHOOT_UP:int = 7;
      public static const CHARACTER_ANIMATION_MOVE_UP:int = 8;
      public static const CHARACTER_ANIMATION_AIRDROP:int = 9;
      public static const CHARACTER_ANIMATION_EXPLOSION:int = 10;

      public static const INSTALLATION_ANIMATION_IDLE:int = 0;
      public static const INSTALLATION_ANIMATION_SHOOT:int = 1;
      public static const INSTALLATION_ANIMATION_HIT:int = 2;
      public static const INSTALLATION_ANIMATION_WRECKING:int = 3;
      public static const INSTALLATION_ANIMATION_READY_FOR_ACTION:int = 4;
      public static const INSTALLATION_ANIMATION_ACTION:int = 5;
      public static const INSTALLATION_ANIMATION_NOACTION:int = 6;

      protected var mOwner:Renderable;
      public var mAnimations:Array;
      private var mCurrentAnimation:int = 0;
      protected var mCurrentDirection:int = 0;
      private var mLoadingCallbackEventTypes:Object;
      private var mFiles:Array;
      private var mIsPlaying:Boolean = false;
      private var mDirectionTargets:Array;
      private var mPlaybackTargets:Array;

      private static var smActiveControllers:int = 0;
      private static var smCreatedControllers:int = 0;
      private static var smMaterializedClips:int = 0;
      private static var smAnimationChanges:int = 0;
      private static var smPlayCalls:int = 0;
      private static var smDirectionChanges:int = 0;
      private static var smAnimationTreeCacheBuilds:int = 0;
      private static var smAnimationTreeCacheHits:int = 0;
      private static var smDeferredSpecials:int = 0;
      private static var smMaterializationMisses:int = 0;
      private static var smLastStatsAt:int = 0;

      private var mDiagnosticsDestroyed:Boolean = false;

      public function AnimationController(param1:Renderable)
      {
         super();
         this.mOwner = param1;
         smActiveControllers++;
         smCreatedControllers++;
         this.emitAnimationStats(false);
      }

      private function emitAnimationStats(param1:Boolean = false) : void
      {
         var now:int = getTimer();
         if(!param1 && now - smLastStatsAt < 5000)
         {
            return;
         }
         smLastStatsAt = now;
         Utils.DiagEvent("ANIMATION_STATS","active_controllers=" + smActiveControllers + ";created_total=" + smCreatedControllers + ";materialized_total=" + smMaterializedClips + ";changes_total=" + smAnimationChanges + ";plays_total=" + smPlayCalls + ";direction_changes_total=" + smDirectionChanges + ";tree_cache_builds=" + smAnimationTreeCacheBuilds + ";tree_cache_hits=" + smAnimationTreeCacheHits + ";deferred_specials=" + smDeferredSpecials + ";materialization_misses=" + smMaterializationMisses);
      }

      private function compactStack(param1:Error) : String
      {
         var stack:String = param1 ? param1.getStackTrace() : null;
         if(!stack)
         {
            return "none";
         }
         stack = stack.split("\r").join("").split("\n").join(" > ");
         return stack.length > 1000 ? stack.substr(0,1000) : stack;
      }

      private function shouldDeferSpecialAnimation(param1:int) : Boolean
      {
         return param1 == CHARACTER_ANIMATION_AIRDROP || param1 == CHARACTER_ANIMATION_EXPLOSION;
      }

      private function materializeAnimation(param1:int, param2:DCResourceManager = null) : Boolean
      {
         if(!this.mAnimations || !this.mFiles || param1 < 0 || param1 >= this.mFiles.length)
         {
            return false;
         }
         var wrapper:MovieClip = this.mAnimations[param1] as MovieClip;
         if(!wrapper)
         {
            return false;
         }
         if(wrapper.numChildren > 0)
         {
            return true;
         }
         var source:String = this.mFiles[param1] as String;
         if(!source)
         {
            return false;
         }
         var slash:int = source.lastIndexOf("/");
         var symbol:String = source.slice(slash + 1);
         var resource:String = source.slice(0,slash);
         var manager:DCResourceManager = param2 ? param2 : DCResourceManager.getInstance();
         if(!manager.isLoaded(resource))
         {
            return false;
         }
         try
         {
            var cls:Class = manager.getSWFClass(resource,symbol);
            if(cls != null)
            {
               wrapper.addChild(new cls());
               wrapper.visible = true;
               smMaterializedClips++;
               this.invalidateAnimationTreeCache(param1);
               this.emitAnimationStats(false);
               Utils.DiagEvent("ANIMATION_MATERIALIZED","index=" + param1 + ";resource=" + resource + ";symbol=" + symbol + ";special=" + this.shouldDeferSpecialAnimation(param1));
               return true;
            }
         }
         catch(error:Error)
         {
            smMaterializationMisses++;
            Utils.DiagEvent("ANIMATION_CLASS_MISS","index=" + param1 + ";resource=" + resource + ";symbol=" + symbol + ";special=" + this.shouldDeferSpecialAnimation(param1) + ";errorID=" + error.errorID + ";message=" + error.message + ";stack=" + this.compactStack(error));
            this.emitAnimationStats(false);
            return false;
         }
         smMaterializationMisses++;
         Utils.DiagEvent("ANIMATION_CLASS_MISS","index=" + param1 + ";resource=" + resource + ";symbol=" + symbol + ";special=" + this.shouldDeferSpecialAnimation(param1) + ";errorID=0;message=null_class;stack=none");
         this.emitAnimationStats(false);
         return false;
      }

      public function loadAnimations(param1:Array) : void
      {
         var resource:String = null;
         var slash:int = 0;
         var source:String = null;
         var wrapper:MovieClip = null;
         var callbackType:String = null;
         var manager:DCResourceManager = DCResourceManager.getInstance();

         this.mAnimations = new Array();
         this.mDirectionTargets = new Array();
         this.mPlaybackTargets = new Array();
         this.mFiles = param1;
         this.mLoadingCallbackEventTypes = new Object();

         var count:int = int(param1.length);
         var index:int = 0;
         while(index < count)
         {
            source = param1[index] as String;
            slash = source.lastIndexOf("/");
            resource = source.slice(0,slash);
            wrapper = new MovieClip();
            this.mAnimations.push(wrapper);
            this.mPlaybackTargets[index] = null;
            this.mDirectionTargets[index] = null;

            if(manager.isLoaded(resource))
            {
               if(this.shouldDeferSpecialAnimation(index))
               {
                  smDeferredSpecials++;
                  Utils.DiagEvent("ANIMATION_DEFERRED","index=" + index + ";source=" + source + ";reason=special_on_demand");
               }
               else
               {
                  this.materializeAnimation(index,manager);
               }
            }
            else
            {
               callbackType = resource + DCResourceManager.EVENT_COMPLETE_SINGLE_FILE;
               this.mLoadingCallbackEventTypes[callbackType] = callbackType;
               wrapper.visible = false;
               wrapper.gotoAndStop(1);
               manager.addEventListener(callbackType,this.LoadingFinished);
               if(!manager.isAddedToLoadingList(resource))
               {
                  manager.load(Config.DIR_DATA + resource + ".swf",resource,null,false,false);
               }
            }
            index++;
         }
         this.mCurrentAnimation = 0;
         this.notifyOwnerAnimationReady();
      }

      public function LoadingFinished(param1:Event) : void
      {
         var resource:String = null;
         var slash:int = 0;
         var manager:DCResourceManager = DCResourceManager.getInstance();
         manager.removeEventListener(param1.type,this.LoadingFinished);
         this.mLoadingCallbackEventTypes[param1.type] = null;

         var index:int = 0;
         while(index < this.mFiles.length)
         {
            slash = (this.mFiles[index] as String).lastIndexOf("/");
            resource = (this.mFiles[index] as String).slice(0,slash);
            if(manager.isLoaded(resource) && (this.mAnimations[index] as MovieClip).numChildren == 0)
            {
               if(this.shouldDeferSpecialAnimation(index) && index != this.mCurrentAnimation)
               {
                  smDeferredSpecials++;
               }
               else
               {
                  this.materializeAnimation(index,manager);
               }
            }
            index++;
         }

         if(this.mIsPlaying)
         {
            this.playCurrentAnimation();
         }
         else
         {
            this.stopCurrentAnimation();
         }
         this.notifyOwnerAnimationReady();
      }

      private function notifyOwnerAnimationReady() : void
      {
         if(this.mOwner is IsometricCharacter)
         {
            (this.mOwner as IsometricCharacter).refreshStatusHints();
         }
      }

      private function invalidateAnimationTreeCache(param1:int) : void
      {
         if(this.mPlaybackTargets)
         {
            this.mPlaybackTargets[param1] = null;
         }
         if(this.mDirectionTargets)
         {
            this.mDirectionTargets[param1] = null;
         }
      }

      private function getAnimationTreeTargets(param1:int) : Array
      {
         if(!this.mPlaybackTargets)
         {
            this.mPlaybackTargets = new Array();
         }
         if(this.mAnimations && param1 >= 0 && param1 < this.mAnimations.length && (this.mAnimations[param1] as MovieClip).numChildren == 0)
         {
            this.materializeAnimation(param1);
         }
         var cached:Array = this.mPlaybackTargets[param1] as Array;
         if(cached != null)
         {
            smAnimationTreeCacheHits++;
            return cached;
         }

         var result:Array = new Array();
         var root:MovieClip = this.mAnimations && param1 >= 0 && param1 < this.mAnimations.length ? this.mAnimations[param1] as MovieClip : null;
         if(root == null)
         {
            this.mPlaybackTargets[param1] = result;
            return result;
         }

         result.push(root);
         var child:MovieClip = null;
         var nested:MovieClip = null;
         var deep:MovieClip = null;
         var i:int = 0;
         var j:int = 0;
         var k:int = 0;
         while(i < root.numChildren)
         {
            child = root.getChildAt(i) as MovieClip;
            if(child)
            {
               result.push(child);
               j = 0;
               while(j < child.numChildren)
               {
                  nested = child.getChildAt(j) as MovieClip;
                  if(nested)
                  {
                     result.push(nested);
                     k = 0;
                     while(k < nested.numChildren)
                     {
                        deep = nested.getChildAt(k) as MovieClip;
                        if(deep)
                        {
                           result.push(deep);
                        }
                        k++;
                     }
                  }
                  j++;
               }
            }
            i++;
         }

         this.mPlaybackTargets[param1] = result;
         smAnimationTreeCacheBuilds++;
         this.emitAnimationStats(false);
         return result;
      }

      public function setAnimation(param1:int) : Boolean
      {
         if(param1 >= this.mAnimations.length)
         {
            return false;
         }
         this.materializeAnimation(param1);
         if(param1 == this.mCurrentAnimation)
         {
            return false;
         }
         if(Config.DEBUG_MODE)
         {
         }
         this.mCurrentAnimation = param1;
         smAnimationChanges++;
         this.emitAnimationStats(false);
         return true;
      }

      private function startShootAnimation(param1:Boolean) : void
      {
         var animation:MovieClip = null;
         var child:MovieClip = null;
         var index:int = param1 ? CHARACTER_ANIMATION_SHOOT : INSTALLATION_ANIMATION_SHOOT;
         this.materializeAnimation(index);
         animation = this.mAnimations[index] as MovieClip;
         if(animation && animation.numChildren > 0)
         {
            child = animation.getChildAt(animation.numChildren - 1) as MovieClip;
            if(child)
            {
               child.visible = true;
               child.gotoAndPlay(1);
               child.addEventListener(Event.ENTER_FRAME,this.enterFrame,false,0,true);
            }
         }
      }

      private function resolveDirectionTarget(param1:int) : DisplayObject
      {
         var animation:MovieClip = this.mAnimations[param1] as MovieClip;
         var child:MovieClip = null;
         var nested:MovieClip = null;
         var i:int = 0;
         var j:int = 0;
         if(!animation)
         {
            return null;
         }
         if(this.mDirectionTargets[param1])
         {
            return this.mDirectionTargets[param1] as DisplayObject;
         }
         while(i < animation.numChildren)
         {
            child = animation.getChildAt(i) as MovieClip;
            if(child)
            {
               j = 0;
               while(j < child.numChildren)
               {
                  nested = child.getChildAt(j) as MovieClip;
                  if(nested && nested.name == "Unit_Container")
                  {
                     this.mDirectionTargets[param1] = nested;
                     return nested;
                  }
                  j++;
               }
            }
            i++;
         }
         this.mDirectionTargets[param1] = animation;
         return animation;
      }

      public function setDirection(param1:int) : void
      {
         var target:DisplayObject = null;
         var i:int = 0;
         if(param1 == this.mCurrentDirection)
         {
            return;
         }
         smDirectionChanges++;
         this.emitAnimationStats(false);
         if(param1 == DIR_RIGHT || param1 == DIR_LEFT)
         {
            while(i < this.mAnimations.length)
            {
               if(i != CHARACTER_ANIMATION_DYING)
               {
                  target = this.resolveDirectionTarget(i);
                  if(target)
                  {
                     target.scaleX = -target.scaleX;
                  }
               }
               i++;
            }
         }
         this.mCurrentDirection = param1;
      }

      public function setSize(param1:int, param2:int) : void
      {
         this.materializeAnimation(this.mCurrentAnimation);
         (this.mAnimations[this.mCurrentAnimation] as MovieClip).width = param1;
         (this.mAnimations[this.mCurrentAnimation] as MovieClip).height = param2;
      }

      public function getAnimation() : MovieClip
      {
         return this.mAnimations[this.mCurrentAnimation];
      }

      public function getCurrentAnimationIndex() : int
      {
         return this.mCurrentAnimation;
      }

      public function getCurrentAnimation() : MovieClip
      {
         return this.mAnimations[this.mCurrentAnimation];
      }

      public function getCurrentAnimationFrameLabel() : String
      {
         var targets:Array = this.getAnimationTreeTargets(this.mCurrentAnimation);
         var clip:MovieClip = null;
         var label:String = null;
         var i:int = 0;
         while(i < targets.length)
         {
            clip = targets[i] as MovieClip;
            if(clip)
            {
               label = clip.currentFrameLabel;
               if(label)
               {
                  return label;
               }
            }
            i++;
         }
         return "";
      }

      protected function hasIdleAnimation() : Boolean
      {
         return false;
      }

      public function applyOnAllAnimations(param1:Function) : void
      {
         var i:int = 0;
         var animation:MovieClip = null;
         if(this.mAnimations[this.mCurrentAnimation])
         {
            while(i < this.mAnimations.length)
            {
               animation = this.mAnimations[i];
               if(animation)
               {
                  param1(animation);
               }
               i++;
            }
         }
      }

      public function playCurrentAnimation() : void
      {
         this.mIsPlaying = true;
         smPlayCalls++;
         this.emitAnimationStats(false);
         var targets:Array = this.getAnimationTreeTargets(this.mCurrentAnimation);
         var clip:MovieClip = null;
         var i:int = 0;
         while(i < targets.length)
         {
            clip = targets[i] as MovieClip;
            if(clip)
            {
               clip.gotoAndPlay(1);
            }
            i++;
         }
      }

      public function stopCurrentAnimation() : void
      {
         this.mIsPlaying = false;
         var targets:Array = this.getAnimationTreeTargets(this.mCurrentAnimation);
         var clip:MovieClip = null;
         var i:int = 0;
         while(i < targets.length)
         {
            clip = targets[i] as MovieClip;
            if(clip)
            {
               clip.gotoAndStop(1);
            }
            i++;
         }
      }

      public function enterFrame(param1:Event) : void
      {
         var clip:MovieClip = param1.target as MovieClip;
         if(clip.currentFrame == clip.totalFrames)
         {
            clip.stop();
            clip.removeEventListener(Event.ENTER_FRAME,this.enterFrame);
         }
      }

      private function stopAnim(param1:DisplayObject, param2:Array) : void
      {
         if(param1 is MovieClip)
         {
            (param1 as MovieClip).gotoAndStop(1);
         }
      }

      public function destroy() : void
      {
         if(!this.mDiagnosticsDestroyed)
         {
            this.mDiagnosticsDestroyed = true;
            if(smActiveControllers > 0)
            {
               smActiveControllers--;
            }
            this.emitAnimationStats(false);
         }
         var callback:String = null;
         var key:String = null;
         var animation:MovieClip = null;
         for each(callback in this.mLoadingCallbackEventTypes)
         {
            if(callback != null)
            {
               DCResourceManager.getInstance().removeEventListener(callback,this.LoadingFinished);
            }
         }
         for(key in this.mAnimations)
         {
            animation = this.mAnimations[key];
            if(animation)
            {
               Utils.CallForAllChildren(animation,this.stopAnim,null);
               if(animation.parent)
               {
                  animation.parent.removeChild(animation);
               }
            }
            this.mAnimations[key] = null;
         }
         this.mAnimations = null;
         this.mDirectionTargets = null;
         this.mPlaybackTargets = null;
         animation = null;
      }
   }
}