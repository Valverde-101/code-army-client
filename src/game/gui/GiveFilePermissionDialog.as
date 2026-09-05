package game.gui {
	import com.dchoc.GUI.DCButton;
	import com.dchoc.graphics.DCResourceManager;
	import flash.display.MovieClip;
	import flash.events.*;
	import game.gui.button.ArmyButton;
	import game.gui.popups.PopUpWindow;
	import game.sound.ArmySoundManager;
	import game.states.GameState;
	import game.utils.OfflineSave;
	CONFIG::BUILD_FOR_MOBILE_AIR {
		import flash.filesystem.File;
		import flash.filesystem.FileMode;
		import flash.filesystem.FileStream;
		import flash.permissions.PermissionStatus
	}

	public class GiveFilePermissionDialog extends PopUpWindow {

		private var mButtonGivePerms:ArmyButton;
		private var mButtonDenyPerms:ArmyButton;

		public function GiveFilePermissionDialog() {
			var menuClass:Class = DCResourceManager.getInstance().getSWFClass(Config.SWF_MAIN_MENU_NAME, "GiveFilePermissionMenu");
			super(new menuClass(), false);
			this.mButtonGivePerms = this.addButton(mClip, "Button_GivePerms", this.tabPressed);
			this.mButtonDenyPerms = this.addButton(mClip, "Button_DenyPerms", this.tabPressed);
			if (this.mButtonGivePerms != null) {
				this.mButtonGivePerms.resizeNeeded = false;
				this.mButtonGivePerms.setText(GameState.getText("BUTTON_DOCUMENTS"), "Text_Title");
			}
			if (this.mButtonDenyPerms != null) {
				this.mButtonDenyPerms.resizeNeeded = false;
				this.mButtonDenyPerms.setText(GameState.getText("BUTTON_APPFILES"), "Text_Title");
			}
		}

		public function Activate(param1:Function):void {
			mDoneCallback = param1;
			this.fitToScreen();
			doOpeningTransition();
		}

		private function fitToScreen():void {
			var stageWidth:Number = GameState.mInstance.getStageWidth();
			var stageHeight:Number = GameState.mInstance.getStageHeight();
			if (stageWidth <= 0 || stageHeight <= 0 || mClip.width <= 0 || mClip.height <= 0) {
				return;
			}
			var fit:Number = Math.min(1, stageWidth * 0.92 / mClip.width, stageHeight * 0.92 / mClip.height);
			if (fit < 1) {
				mClip.scaleX *= fit;
				mClip.scaleY *= fit;
			}
		}

		private function tabPressed(param1:MouseEvent):void {
			CONFIG::BUILD_FOR_MOBILE_AIR {
				if (ArmySoundManager.getInstance().isSfxOn()) {
					ArmySoundManager.getInstance().playSound(ArmySoundManager.SFX_UI_CLICK);
				}
				var selected:String = null;
				if (this.mButtonGivePerms != null && param1.target == this.mButtonGivePerms.getMovieClip()) {
					selected = "documents";
				} else if (this.mButtonDenyPerms != null && param1.target == this.mButtonDenyPerms.getMovieClip()) {
					selected = "legacy";
				}
				if (selected == null) {
					return;
				}
				GameState.mInstance.mSaveLocation = selected;
				try {
					this.saveSettingsSave();
				} catch (settingsError:Error) {
				}
				try {
					this.buttonSavePressed();
				} catch (saveError:Error) {
				}
				var done:Function = mDoneCallback;
				if (done != null) {
					done((this as Object).constructor);
				}
				GameState.mInstance.mHUD.openPauseScreen();
			}
		}

		private function addButton(param1:MovieClip, param2:String, param3:Function):ArmyButton {
			var buttonClip:MovieClip = param1.getChildByName(param2) as MovieClip;
			if (buttonClip != null) {
				buttonClip.mouseEnabled = true;
				return new ArmyButton(param1, buttonClip, DCButton.BUTTON_TYPE_ICON, null, null, null, null, null, param3);
			}
			return null;
		}

		public function buttonSavePressed(param1:MouseEvent = null):void {
			CONFIG::BUILD_FOR_MOBILE_AIR {
				var backup:File = File.applicationStorageDirectory.resolvePath("savefile.txt");
				try {
					this.writeSaveToFile(backup);
				} catch (backupError:Error) {
				}
				if (GameState.mInstance.mSaveLocation == "documents") {
					var documentsFile:File = File.documentsDirectory.resolvePath("ArmyAttack/savefile.txt");
					try {
						documentsFile.addEventListener(PermissionEvent.PERMISSION_STATUS, this.onPermission);
						documentsFile.requestPermission();
					} catch (permissionError:Error) {
					}
				}
			}
		}

		CONFIG::BUILD_FOR_MOBILE_AIR {
			private function writeSaveToFile(file:File):void {
				if (file.parent != null && !file.parent.exists) {
					file.parent.createDirectory();
				}
				var savedata:* = OfflineSave.generateSaveJson();
				var stream:FileStream = new FileStream();
				stream.open(file, FileMode.WRITE);
				stream.writeUTFBytes(JSON.stringify(savedata));
				stream.close();
			}

			public function onPermission(e:PermissionEvent):void {
				var file:File = e.target as File;
				file.removeEventListener(PermissionEvent.PERMISSION_STATUS, this.onPermission);
				if (e.status == PermissionStatus.GRANTED) {
					try {
						this.writeSaveToFile(file);
					} catch (writeError:Error) {
					}
				}
			}

			public function saveSettingsSave(param1:MouseEvent = null):void {
				var file:File = File.applicationStorageDirectory.resolvePath("savesettings.txt");
				var data:Object = {};
				data["savelocation"] = GameState.mInstance.mSaveLocation;
				var stream:FileStream = new FileStream();
				stream.open(file, FileMode.WRITE);
				stream.writeUTFBytes(JSON.stringify(data));
				stream.close();
			}
		}
	}
}
