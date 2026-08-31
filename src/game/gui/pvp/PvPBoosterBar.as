package game.gui.pvp
{
   import flash.display.DisplayObject;
   import flash.display.DisplayObjectContainer;
   import flash.display.MovieClip;
   import flash.display.Sprite;
   import flash.events.MouseEvent;
   import flash.text.TextField;
   import game.gui.AutoTextField;
   import game.gui.IconLoader;
   import game.gui.button.ArmyButton;
   import game.items.BoosterItem;
   import game.items.ShopItem;
   import game.states.GameState;
   
   public class PvPBoosterBar
   {
      
      private static const PANEL_COUNT:int = 5;
       
      
      private var mBasePanel:MovieClip;
      
      private var mButtonLeft:ArmyButton;
      
      private var mButtonRight:ArmyButton;
      
      private var mButtonLeftFull:ArmyButton;
      
      private var mButtonRightFull:ArmyButton;
      
      private var mCursorPos:int = 0;
      
      private var mBoosterButtons:Array;
      
      private var mBoosterFrames:Array;
      
      private var mBoosterInventory:Array;
      
      private var mIconSize:int = 20;
      
      private var mCancelActionButton:ArmyButton;
      
      public function PvPBoosterBar(param1:MovieClip)
      {
         var _loc4_:MovieClip = null;
         var _loc5_:ArmyButton = null;
         this.mBoosterButtons = new Array();
         this.mBoosterFrames = new Array();
         super();
         this.mBasePanel = param1;
         this.mCancelActionButton = Utils.createBasicButton(this.mBasePanel,"Button_Cancel",this.cancelPressed);
         var _loc2_:AutoTextField = new AutoTextField(this.mBasePanel.getChildByName("Text_Cancel_Action") as TextField);
         _loc2_.setText(GameState.getText("PVP_CANCEL_ACTION"));
         this.initScrollButtons();
         var _loc3_:int = 0;
         while(_loc3_ < PANEL_COUNT)
         {
            _loc4_ = this.mBasePanel.getChildByName("Powerup_0" + (_loc3_ + 1)) as MovieClip;
            (_loc5_ = Utils.createBasicButton(_loc4_,"Button_Use",this.usePressed)).setText(GameState.getText("PVP_USE"),"Text_Title");
            _loc5_.setEnabled(false);
            this.mBoosterButtons.push(_loc5_);
            var iconFrame:MovieClip = _loc4_.getChildAt(1) as MovieClip;
            if(_loc3_ == 0 && iconFrame) this.mIconSize = Math.max(20,int(Math.max(iconFrame.width,iconFrame.height)));
            this.mBoosterFrames.push(iconFrame);
            Utils.removeAllChildren(iconFrame);
            _loc3_++;
         }
         Utils.DiagEvent("PVP_BOOSTER_LAYOUT","icon_size=" + this.mIconSize);
         this.addToScreen();
         this.updateArrowStates();
      }
      
      private function initScrollButtons() : void
      {
         this.mButtonLeft = Utils.createBasicButton(this.mBasePanel,"Button_Previous",this.leftPressed);
         this.mButtonLeftFull = Utils.createBasicButton(this.mBasePanel,"Button_First",this.leftPressedFull);
         this.mButtonRight = Utils.createBasicButton(this.mBasePanel,"Button_Next",this.rightPressed);
         this.mButtonRightFull = Utils.createBasicButton(this.mBasePanel,"Button_Last",this.rightPressedFull);
      }
      
      private function usePressed(param1:MouseEvent) : void
      {
         var _loc2_:int = this.mCursorPos;
         var _loc3_:int = 0;
         while(_loc3_ < PANEL_COUNT)
         {
            if(param1.target == (this.mBoosterButtons[_loc3_] as ArmyButton).getMovieClip())
            {
               if(_loc2_ >= 0 && _loc2_ < this.mBoosterInventory.length / 2)
               {
                  var booster:BoosterItem = this.mBoosterInventory[_loc2_ * 2] as BoosterItem;
                  if(booster)
                  {
                     GameState.mInstance.mPvPMatch.activateBooster(booster);
                  }
               }
            }
            _loc2_++;
            _loc3_++;
         }
         this.addToScreen();
      }
      
      private function cancelPressed(param1:MouseEvent) : void
      {
      }
      
      private function leftPressed(param1:MouseEvent) : void
      {
         this.mCursorPos = Math.max(this.mCursorPos - 1,0);
         this.addToScreen();
         this.updateArrowStates();
      }
      
      private function leftPressedFull(param1:MouseEvent) : void
      {
         this.mCursorPos = 0;
         this.addToScreen();
         this.updateArrowStates();
      }
      
      private function rightPressed(param1:MouseEvent) : void
      {
         this.mCursorPos = Math.min(this.mCursorPos + 1,Math.max(0,this.mBoosterInventory.length / 2 - PANEL_COUNT));
         this.addToScreen();
         this.updateArrowStates();
      }
      
      private function rightPressedFull(param1:MouseEvent) : void
      {
         this.mCursorPos = Math.max(0,this.mBoosterInventory.length / 2 - PANEL_COUNT);
         this.addToScreen();
         this.updateArrowStates();
      }
      
      private function updateArrowStates() : void
      {
         var _loc1_:* = this.mCursorPos > 0;
         var _loc2_:* = this.mCursorPos < Math.max(0,this.mBoosterInventory.length / 2 - PANEL_COUNT);
         this.mButtonLeft.setEnabled(_loc1_);
         this.mButtonLeftFull.setEnabled(_loc1_);
         this.mButtonRight.setEnabled(_loc2_);
         this.mButtonRightFull.setEnabled(_loc2_);
      }
      
      private function setPanelQuantity(param1:DisplayObjectContainer, param2:int) : void
      {
         var _loc2_:DisplayObject = null;
         var _loc3_:TextField = null;
         var _loc4_:String = null;
         var _loc5_:int = 0;
         if(!param1)
         {
            return;
         }
         while(_loc5_ < param1.numChildren)
         {
            _loc2_ = param1.getChildAt(_loc5_);
            if(_loc2_ is TextField)
            {
               _loc3_ = _loc2_ as TextField;
               _loc4_ = _loc3_.name ? _loc3_.name.toLowerCase() : "";
               if(_loc3_.text == "99" || _loc4_.indexOf("count") >= 0 || _loc4_.indexOf("amount") >= 0 || _loc4_.indexOf("quantity") >= 0)
               {
                  _loc3_.text = param2 > 0 ? String(param2) : "";
               }
            }
            else if(_loc2_ is DisplayObjectContainer)
            {
               this.setPanelQuantity(_loc2_ as DisplayObjectContainer,param2);
            }
            _loc5_++;
         }
      }

      public function addToScreen() : void
      {
         var _loc3_:MovieClip = null;
         var _loc4_:ArmyButton = null;
         var _loc5_:ShopItem = null;
         var _loc6_:MovieClip = null;
         var _loc7_:int = 0;
         this.mBoosterInventory = GameState.mInstance.mPlayerProfile.mInventory.getBoosters();
         var itemCount:int = int(this.mBoosterInventory.length / 2);
         this.mCursorPos = Math.min(this.mCursorPos,Math.max(0,itemCount - PANEL_COUNT));
         var _loc1_:int = this.mCursorPos;
         var _loc2_:int = 0;
         while(_loc2_ < PANEL_COUNT)
         {
            _loc3_ = this.mBoosterFrames[_loc2_];
            _loc4_ = this.mBoosterButtons[_loc2_];
            _loc6_ = this.mBasePanel.getChildByName("Powerup_0" + (_loc2_ + 1)) as MovieClip;
            Utils.removeAllChildren(_loc3_);
            if(_loc1_ < itemCount)
            {
               _loc5_ = this.mBoosterInventory[_loc1_ * 2] as ShopItem;
               _loc7_ = int(this.mBoosterInventory[_loc1_ * 2 + 1]);
               this.setPanelQuantity(_loc6_,_loc7_);
               Utils.DiagEvent("PVP_BOOSTER_SLOT","slot=" + _loc2_ + ";id=" + _loc5_.mId + ";count=" + _loc7_ + ";icon_file=" + _loc5_.getIconGraphicsFile() + ";icon=" + _loc5_.getIconGraphics());
               IconLoader.addIcon(_loc3_,_loc5_,this.iconLoaded);
               _loc4_.setEnabled(_loc7_ > 0);
            }
            else
            {
               this.setPanelQuantity(_loc6_,0);
               _loc4_.setEnabled(false);
            }
            _loc1_++;
            _loc2_++;
         }
         Utils.DiagEvent("PVP_BOOSTER_BAR","item_count=" + itemCount + ";cursor=" + this.mCursorPos);
      }

      private function iconLoaded(param1:Sprite) : void
      {
         if(!param1) { Utils.DiagEvent("PVP_BOOSTER_ICON_FAIL","reason=null_sprite"); return; }
         param1.visible = true;
         param1.alpha = 1;
         Utils.scaleIcon(param1,this.mIconSize,this.mIconSize);
         Utils.DiagEvent("PVP_BOOSTER_ICON_READY","width=" + param1.width + ";height=" + param1.height + ";target=" + this.mIconSize);
      }
   }
}
