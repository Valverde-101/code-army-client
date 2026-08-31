package game.items
{
   public class PowerUpItem extends MapItem
   {
       
      
      public var mPowerUpUnit:PlayerUnitItem;
      public var mPowerUpEnemyUnit:EnemyUnitItem;
      
      public var mPowerUpItem:Item;
      
      public var mPowerUpFireMissionItem:FireMissionItem;
      
      public var mIncreasedHealth:int = 0;
      
      public var mIncreasedActions:int = 0;
	   
	  public var mEffectGraphics:String;
      public var mFreezeTurns:int = 0;
      public var mRandomPowerUps:Array;
      public var mRandomPowerUpPercentages:Array;
      
      public function PowerUpItem(param1:Object)
      {
         super(param1);
         this.mPowerUpUnit = null;
         this.mPowerUpEnemyUnit = null;
         if(param1.Unit) this.mPowerUpUnit = ItemManager.getItem(param1.Unit.ID,param1.Unit.Type) as PlayerUnitItem;
         if(param1.PvPEnemyUnit) this.mPowerUpEnemyUnit = ItemManager.getItem(param1.PvPEnemyUnit.ID,param1.PvPEnemyUnit.Type) as EnemyUnitItem;
         if(param1.Item)
         {
            this.mPowerUpItem = ItemManager.getItem(param1.Item.ID,param1.Item.Type);
         }
         if(param1.FireMission)
         {
            this.mPowerUpFireMissionItem = ItemManager.getItem(param1.FireMission.ID,param1.FireMission.Type) as FireMissionItem;
         }
         if(!this.mPowerUpFireMissionItem)
         {
            var fallbackFireMissionId:String = null;
            if(mId == "AirSupport_1") fallbackFireMissionId = "pvp_airSupport_1";
            else if(mId == "AirSupport_2") fallbackFireMissionId = "pvp_airSupport_2";
            else if(mId == "AirSupport_3") fallbackFireMissionId = "pvp_airSupport_3";
            else if(mId == "OrbitalLaser") fallbackFireMissionId = "pvp_orbitalLaser";
            else if(mId == "Doomsday") fallbackFireMissionId = "pvp_doomsday";
            if(fallbackFireMissionId) this.mPowerUpFireMissionItem = ItemManager.getItem(fallbackFireMissionId,"PvPFireMission") as FireMissionItem;
         }
         this.mFreezeTurns = int(param1.FreezeTurns);
         this.mRandomPowerUps = param1.RandomPowerUps is Array ? param1.RandomPowerUps as Array : null;
         this.mRandomPowerUpPercentages = param1.RandomPowerUpPercentages is Array ? param1.RandomPowerUpPercentages as Array : null;
         this.mIncreasedHealth = param1.IncreasedHealth;
         this.mIncreasedActions = param1.IncreasedActions;
		 this.mEffectGraphics = param1.EffectGraphics;
         mWalkable = true;
      }

      public function getRandomPowerUp() : PowerUpItem
      {
         if(!this.mRandomPowerUps || this.mRandomPowerUps.length == 0) return null;
         var roll:Number = Math.random() * 100;
         var cursor:Number = 0;
         var index:int = 0;
         var row:Object = null;
         while(index < this.mRandomPowerUps.length)
         {
            cursor += this.mRandomPowerUpPercentages && index < this.mRandomPowerUpPercentages.length ? Number(this.mRandomPowerUpPercentages[index]) : 0;
            if(roll <= cursor || index == this.mRandomPowerUps.length - 1)
            {
               row = this.mRandomPowerUps[index];
               return row ? ItemManager.getItem(row.ID,row.Type) as PowerUpItem : null;
            }
            index++;
         }
         return null;
      }
   }
}
