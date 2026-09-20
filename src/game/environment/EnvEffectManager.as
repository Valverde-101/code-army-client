package game.environment
{
   import game.battlefield.MapData;
   import game.isometric.GridCell;
   import game.states.GameState;

   public class EnvEffectManager
   {
      private static const RANDOM_PRC:int = 15;
      private static const EFFECTS_MAX_SIMULT_CLOUD:int = 3;
      private static const EFFECTS_DELAY_CLOUD:int = 100000;
      private static var mCloudClock:int;
      private static const EFFECTS_MAX_SIMULT_TILE:int = 5;
      private static const EFFECTS_DELAY_TILE:int = 1700;
      private static var mTileClock:int;
      private static const EFFECTS_MAX_SIMULT_FLY:int = 1;
      private static const EFFECTS_DELAY_FLY:int = 25000;
      private static var mFlyClock:int;
      private static var mClouds:Array;
      private static var mFly:Array;
      private static var mTile:Array;
      private static var mRiverTiles:Array;
      private static var mDisabledLogged:Boolean = false;

      public function EnvEffectManager()
      {
         super();
      }

      public static function init() : void
      {
         var cell:GridCell = null;
         var count:int = 0;
         var i:int = 0;
         if(mFly)
         {
            destroy();
         }
         mFly = new Array();
         mTile = new Array();
         mClouds = new Array();
         mRiverTiles = new Array();
         mFlyClock = 0;
         mTileClock = 0;
         mCloudClock = 0;

         if(!FeatureTuner.USE_ENVIRONMENT_EFFECTS)
         {
            if(!mDisabledLogged)
            {
               mDisabledLogged = true;
               Utils.DiagEvent("ENV_EFFECT_POLICY","enabled=false;low_swf=" + FeatureTuner.USE_LOW_SWF + ";river=" + FeatureTuner.USE_RIVER_TILE_EFFECTS + ";cloud=" + FeatureTuner.USE_CLOUD_EFFECTS + ";airplane=" + FeatureTuner.USE_AIRPLANE_WEDGE_EFFECTS + ";waves=" + FeatureTuner.USE_SEA_WAVES_EFFECT);
            }
            return;
         }

         var grid:Array = GameState.mInstance.mMapData.mGrid;
         if(FeatureTuner.USE_RIVER_TILE_EFFECTS && grid)
         {
            count = int(grid.length);
            i = 0;
            while(i < count)
            {
               cell = grid[i] as GridCell;
               if(cell && cell.mType == MapData.TILE_TYPE_RIVER)
               {
                  mRiverTiles.push(cell);
               }
               i++;
            }
         }
         Utils.DiagEvent("ENV_EFFECT_POLICY","enabled=true;low_swf=" + FeatureTuner.USE_LOW_SWF + ";river_tiles=" + mRiverTiles.length);
      }

      public static function destroy() : void
      {
         var effect:RandomEffect = null;
         var i:int = 0;
         if(mClouds)
         {
            i = 0;
            while(i < mClouds.length)
            {
               effect = mClouds[i] as RandomEffect;
               if(effect) effect.destroy();
               i++;
            }
         }
         if(mFly)
         {
            i = 0;
            while(i < mFly.length)
            {
               effect = mFly[i] as RandomEffect;
               if(effect) effect.destroy();
               i++;
            }
         }
         if(mTile)
         {
            i = 0;
            while(i < mTile.length)
            {
               effect = mTile[i] as RandomEffect;
               if(effect) effect.destroy();
               i++;
            }
         }
         mFly = null;
         mTile = null;
         mClouds = null;
         mRiverTiles = null;
      }

      public static function update(param1:int) : void
      {
         if(!FeatureTuner.USE_ENVIRONMENT_EFFECTS)
         {
            return;
         }
         if(!mFly || !mTile || !mClouds)
         {
            return;
         }

         var effect:RandomEffect = null;
         var i:int = 0;
         if(FeatureTuner.USE_AIRPLANE_WEDGE_EFFECTS)
         {
            if(mFlyClock > EFFECTS_DELAY_FLY && mFly.length < EFFECTS_MAX_SIMULT_FLY)
            {
               mFly.push(new AirplaneWedge());
               mFlyClock = Math.random() * (EFFECTS_DELAY_FLY / 100 * RANDOM_PRC);
            }
            else
            {
               mFlyClock += param1;
            }
         }
         if(FeatureTuner.USE_RIVER_TILE_EFFECTS)
         {
            if(mRiverTiles && mRiverTiles.length > 0 && mTileClock > EFFECTS_DELAY_TILE && mTile.length < EFFECTS_MAX_SIMULT_TILE)
            {
               mTile.push(new RiverEffect(mRiverTiles));
               mTileClock = Math.random() * (EFFECTS_DELAY_FLY / 100 * RANDOM_PRC);
            }
            else
            {
               mTileClock += param1;
            }
         }
         if(FeatureTuner.USE_CLOUD_EFFECTS)
         {
            if(mCloudClock > EFFECTS_DELAY_CLOUD && mClouds.length < EFFECTS_MAX_SIMULT_CLOUD)
            {
               if(GameState.mInstance.mCurrentMapId == "Desert")
               {
                  mClouds.push(new DesertCloud());
               }
               else
               {
                  mClouds.push(new DriftingCloud());
               }
               mCloudClock = Math.random() * (EFFECTS_DELAY_CLOUD / 100 * RANDOM_PRC);
            }
            else
            {
               mCloudClock += param1;
            }
         }

         if(FeatureTuner.USE_AIRPLANE_WEDGE_EFFECTS)
         {
            i = 0;
            while(i < mFly.length)
            {
               effect = mFly[i] as RandomEffect;
               if(effect && (effect.update(param1) || effect.mDestroyed))
               {
                  mFly.splice(i,1);
                  i--;
               }
               i++;
            }
         }
         if(FeatureTuner.USE_RIVER_TILE_EFFECTS)
         {
            i = 0;
            while(i < mTile.length)
            {
               effect = mTile[i] as RandomEffect;
               if(effect && (effect.update(param1) || effect.mDestroyed))
               {
                  mTile.splice(i,1);
                  i--;
               }
               i++;
            }
         }
         if(FeatureTuner.USE_CLOUD_EFFECTS)
         {
            i = 0;
            while(i < mClouds.length)
            {
               effect = mClouds[i] as RandomEffect;
               if(effect && (effect.update(param1) || effect.mDestroyed))
               {
                  mClouds.splice(i,1);
                  i--;
               }
               i++;
            }
         }
      }
   }
}
