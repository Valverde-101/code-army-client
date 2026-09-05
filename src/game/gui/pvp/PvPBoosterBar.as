package game.gui.pvp
{
   import flash.display.DisplayObject;
   import flash.display.DisplayObjectContainer;
   import flash.display.MovieClip;
   import flash.display.Sprite;
   import flash.events.MouseEvent;
   import flash.text.TextField;
   import com.dchoc.graphics.DCResourceManager;
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
      
      private var mBoosterQuantityFields:Array;
      
      private var mRenderedCounts:Array;
      
      private var mRenderedResourceKeys:Array;
      
      private var mRenderedItemIds:Array;
      
      private var mIconSize:int = 20;
      
      private var mCancelActionButton:ArmyButton;
      
      public function PvPBoosterBar(param1:MovieClip)
      {
         var _loc4_:MovieClip = null;
         var _loc5_:ArmyButton = null;
         this.mBoosterButtons = new Array();
         this.mBoosterFrames = new Array();
         this.mBoosterQuantityFields = new Array();
         this.mRenderedCounts = new Array();
         this.mRenderedResourceKeys = new Array();
         this.mRenderedItemIds = new Array();
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
            this.registerPanelQuantityFields(_loc4_);
            this.setPanelQuantity(_loc3_,0);
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
      
      private function registerPanelQuantityFields(param1:DisplayObjectContainer) : void
      {
         var _loc1_:Array = new Array();
         this.collectPanelQuantityFields(param1,_loc1_);
         this.mBoosterQuantityFields.push(_loc1_);
      }
      
      private function collectPanelQuantityFields(param1:DisplayObjectContainer, param2:Array) : void
      {
         var _loc1_:DisplayObject = null;
         var _loc2_:TextField = null;
         var _loc3_:String = null;
         var _loc4_:int = 0;
         if(param1 == null)
         {
            return;
         }
         while(_loc4_ < param1.numChildren)
         {
            _loc1_ = param1.getChildAt(_loc4_);
            if(_loc1_ is TextField)
            {
               _loc2_ = _loc1_ as TextField;
               _loc3_ = _loc2_.name ? _loc2_.name.toLowerCase() : "";
               if(_loc2_.text == "99" || _loc3_.indexOf("count") >= 0 || _loc3_.indexOf("amount") >= 0 || _loc3_.indexOf("quantity") >= 0)
               {
                  param2.push(_loc2_);
               }
            }
            else if(_loc1_ is DisplayObjectContainer)
            {
               this.collectPanelQuantityFields(_loc1_ as DisplayObjectContainer,param2);
            }
            _loc4_++;
         }
      }
      
      private function setPanelQuantity(param1:int, param2:int) : void
      {
         var _loc1_:Array = param1 >= 0 && param1 < this.mBoosterQuantityFields.length ? this.mBoosterQuantityFields[param1] as Array : null;
         var _loc2_:TextField = null;
         var _loc3_:int = 0;
         if(_loc1_ == null)
         {
            return;
         }
         while(_loc3_ < _loc1_.length)
         {
            _loc2_ = _loc1_[_loc3_] as TextField;
            if(_loc2_ != null)
            {
               _loc2_.text = param2 > 0 ? String(param2) : "";
            }
            _loc3_++;
         }
      }

      private function getUsableBoosterInventory() : Array
      {
         var _loc1_:Array = GameState.mInstance.mPlayerProfile.mInventory.getBoosters();
         var _loc2_:Array = new Array();
         var _loc3_:BoosterItem = null;
         var _loc4_:int = 0;
         var _loc5_:int = 0;
         while(_loc4_ + 1 < _loc1_.length)
         {
            _loc3_ = _loc1_[_loc4_] as BoosterItem;
            _loc5_ = int(_loc1_[_loc4_ + 1]);
            if(_loc3_ != null && _loc5_ > 0)
            {
               _loc2_.push(_loc3_);
               _loc2_.push(_loc5_);
            }
            _loc4_ += 2;
         }
         return _loc2_;
      }
      
      private function getBoosterResourceKey(param1:ShopItem) : String
      {
         var _loc1_:String = param1 ? param1.getIconGraphics() : null;
         var _loc2_:String = param1 ? param1.getIconGraphicsFile() : null;
         if(_loc2_ == null || _loc2_.length == 0)
         {
            return null;
         }
         if(_loc1_ != null && _loc1_.indexOf(".png") >= 0)
         {
            return Config.DIR_DATA + _loc2_ + "/" + _loc1_;
         }
         return _loc2_;
      }
      
      public function addToScreen() : void
      {
         var _loc3_:MovieClip = null;
         var _loc4_:ArmyButton = null;
         var _loc5_:ShopItem = null;
         var _loc7_:int = 0;
         this.mBoosterInventory = this.getUsableBoosterInventory();
         var itemCount:int = int(this.mBoosterInventory.length / 2);
         this.mCursorPos = Math.min(this.mCursorPos,Math.max(0,itemCount - PANEL_COUNT));
         var _loc1_:int = this.mCursorPos;
         var _loc2_:int = 0;
         while(_loc2_ < PANEL_COUNT)
         {
            _loc3_ = this.mBoosterFrames[_loc2_] as MovieClip;
            _loc4_ = this.mBoosterButtons[_loc2_] as ArmyButton;
            Utils.removeAllChildren(_loc3_);
            this.setPanelQuantity(_loc2_,0);
            this.mRenderedCounts[_loc2_] = 0;
            this.mRenderedResourceKeys[_loc2_] = null;
            this.mRenderedItemIds[_loc2_] = null;
            _loc4_.setEnabled(false);
            if(_loc1_ < itemCount)
            {
               _loc5_ = this.mBoosterInventory[_loc1_ * 2] as ShopItem;
               _loc7_ = int(this.mBoosterInventory[_loc1_ * 2 + 1]);
               this.mRenderedCounts[_loc2_] = _loc7_;
               this.mRenderedResourceKeys[_loc2_] = this.getBoosterResourceKey(_loc5_);
               this.mRenderedItemIds[_loc2_] = _loc5_.mId;
               Utils.DiagEvent("PVP_BOOSTER_SLOT","slot=" + _loc2_ + ";id=" + _loc5_.mId + ";count=" + _loc7_ + ";resource=" + this.mRenderedResourceKeys[_loc2_]);
               IconLoader.addIcon(_loc3_,_loc5_,this.iconLoaded);
            }
            _loc1_++;
            _loc2_++;
         }
         this.updateArrowStates();
         Utils.DiagEvent("PVP_BOOSTER_BAR","item_count=" + itemCount + ";cursor=" + this.mCursorPos);
      }

      private function iconLoaded(param1:Sprite) : void
      {
         if(param1 == null)
         {
            Utils.DiagEvent("PVP_BOOSTER_ICON_FAIL","reason=null_sprite");
            return;
         }
         var _loc1_:DisplayObjectContainer = param1.parent as DisplayObjectContainer;
         var _loc2_:int = this.mBoosterFrames.indexOf(_loc1_);
         if(_loc2_ < 0)
         {
            Utils.DiagEvent("PVP_BOOSTER_ICON_PENDING","reason=placeholder_not_attached");
            return;
         }
         var _loc3_:String = this.mRenderedResourceKeys[_loc2_] as String;
         var _loc4_:int = int(this.mRenderedCounts[_loc2_]);
         if(_loc3_ == null || !DCResourceManager.getInstance().isLoaded(_loc3_))
         {
            Utils.DiagEvent("PVP_BOOSTER_ICON_PENDING","slot=" + _loc2_ + ";id=" + this.mRenderedItemIds[_loc2_] + ";resource=" + _loc3_);
            return;
         }
         param1.visible = true;
         param1.alpha = 1;
         Utils.scaleIcon(param1,this.mIconSize,this.mIconSize);
         this.setPanelQuantity(_loc2_,_loc4_);
         (this.mBoosterButtons[_loc2_] as ArmyButton).setEnabled(_loc4_ > 0);
         Utils.DiagEvent("PVP_BOOSTER_ICON_READY","slot=" + _loc2_ + ";id=" + this.mRenderedItemIds[_loc2_] + ";count=" + _loc4_ + ";width=" + param1.width + ";height=" + param1.height + ";target=" + this.mIconSize);
      }
   }
}
