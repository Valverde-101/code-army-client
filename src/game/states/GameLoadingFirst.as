package game.states {
	import com.dchoc.graphics.DCResourceManager;
	import flash.display.DisplayObjectContainer;
	import flash.display.MovieClip;
	import flash.display.Stage;
	import flash.events.*;
	import flash.text.TextField;
	import flash.utils.getDefinitionByName;
	import game.gui.CursorManager;
	import game.net.GameFeedPublisher;
	import game.net.MyServer;
	import game.net.ServerCall;
	import game.net.ServiceIDs;
	import game.sound.ArmySoundManager;
	import com.dchoc.utils.Cookie;

	public class GameLoadingFirst extends LoadingFirst {

		private static function resolveLoadingScreen(): Class {
			try {
				var linked: Class = getDefinitionByName("background") as Class;
				if (linked != null) {
					return linked;
				}
			} catch (e: Error) {
				// Headless AIR builds do not include Animate library linkage classes.
			}
			return LoadingScreenFallback;
		}

		public static var LoadingScreen: Class = resolveLoadingScreen();

		private var mGameState: GameState;
		private var mFileCountToLoad: int;
		private var mFinishStarted: Boolean = false;
		private var mFinalizeStep: String = "idle";

		public function GameLoadingFirst(param1: StateMachine, param2: Stage, param3: FSMState, param4: GameState) {
			super(param1, param2, param3, new LoadingScreen());
			this.mGameState = param4;
		}

		private function setFinalizeStep(param1:String, param2:String):void {
			this.mFinalizeStep = param1;
			Utils.DiagEvent("BOOT_FINALIZE_STEP", "phase=first;step=" + param1 + ";state=" + param2);
		}

		private function sanitizeDiagnostic(param1:String, param2:int = 1800):String {
			if(param1 == null) {
				return "";
			}
			param1 = param1.split("\r").join(" ");
			param1 = param1.split("\n").join(" | ");
			param1 = param1.split(";").join(",");
			if(param1.length > param2) {
				return param1.substr(0,param2) + "...[truncated]";
			}
			return param1;
		}

		private function inspectConfigReference(param1:String, param2:String, param3:String, param4:*):Boolean {
			var entry:* = null;
			if(param4 is Array) {
				for each(entry in (param4 as Array)) {
					if(this.inspectConfigReference(param1,param2,param3,entry)) {
						return true;
					}
				}
				return false;
			}
			if(!(param4 is String)) {
				return false;
			}
			var reference:String = String(param4);
			if(reference.length < 2 || reference.charAt(0) != "#") {
				return false;
			}
			var parts:Array = reference.split(".");
			if(parts.length != 2) {
				Utils.DiagEvent("CONFIG_REFERENCE_FAILURE", "source_table=" + param1 + ";source_row=" + param2 + ";source_field=" + param3 + ";reference=" + this.sanitizeDiagnostic(reference,320) + ";reason=malformed_reference");
				return true;
			}
			var targetTable:String = String(parts[0]).substr(1);
			var targetRow:String = String(parts[1]);
			var config:Object = GameState.mConfig;
			if(config == null || config[targetTable] == null) {
				Utils.DiagEvent("CONFIG_REFERENCE_FAILURE", "source_table=" + param1 + ";source_row=" + param2 + ";source_field=" + param3 + ";reference=" + this.sanitizeDiagnostic(reference,320) + ";target_table=" + targetTable + ";target_row=" + targetRow + ";reason=missing_table");
				return true;
			}
			if(config[targetTable][targetRow] == null) {
				Utils.DiagEvent("CONFIG_REFERENCE_FAILURE", "source_table=" + param1 + ";source_row=" + param2 + ";source_field=" + param3 + ";reference=" + this.sanitizeDiagnostic(reference,320) + ";target_table=" + targetTable + ";target_row=" + targetRow + ";reason=missing_row");
				return true;
			}
			return false;
		}

		private function logFirstConfigReferenceFailure():void {
			var config:Object = GameState.mConfig;
			if(config == null) {
				Utils.DiagEvent("CONFIG_REFERENCE_SCAN", "phase=first;state=unavailable;reason=config_null");
				return;
			}
			var tableName:String = null;
			var rowName:String = null;
			var fieldName:String = null;
			var table:Object = null;
			var row:Object = null;
			for(tableName in config) {
				table = config[tableName];
				if(table == null || table is Array) {
					continue;
				}
				for(rowName in table) {
					row = table[rowName];
					if(row == null || row is Array || row is String) {
						continue;
					}
					for(fieldName in row) {
						if(this.inspectConfigReference(tableName,rowName,fieldName,row[fieldName])) {
							Utils.DiagEvent("CONFIG_REFERENCE_SCAN", "phase=first;state=complete;unresolved_found=true");
							return;
						}
					}
				}
			}
			Utils.DiagEvent("CONFIG_REFERENCE_SCAN", "phase=first;state=complete;unresolved_found=false");
		}

		private function logTransitionFailure(param1:Error):void {
			var stack:String = "";
			try {
				stack = param1.getStackTrace();
			} catch(stackError:Error) {
				stack = "stack_unavailable:" + stackError.message;
			}
			Utils.DiagEvent("BOOT_TRANSITION_FAILURE", "phase=first;step=" + this.mFinalizeStep + ";name=" + this.sanitizeDiagnostic(param1.name,160) + ";error=" + param1.errorID + ";message=" + this.sanitizeDiagnostic(param1.message,900) + ";stack=" + this.sanitizeDiagnostic(stack,1800));
			this.logFirstConfigReferenceFailure();
		}

		override public function enter(): void {
			var _loc2_: String = null;
			var _loc3_: String = null;
			var _loc6_: String = null;
			super.enter();
			this.mFinishStarted = false;
			this.mFinalizeStep = "idle";
			Utils.DiagEvent("BOOT_PHASE", "phase=first;state=enter");
			var _loc1_: DCResourceManager = DCResourceManager.getInstance();
			for each(_loc2_ in AssetManager.JSON_FILES_TO_LOAD) {
				_loc1_.load(Config.DIR_CONFIG + _loc2_ + ".json", _loc2_);
				mResourcesToLoad.push(_loc2_);
			}
			_loc3_ = "army_config_" + Config.smLanguageCode;
			_loc1_.load(Config.DIR_CONFIG + _loc3_ + ".json", _loc3_);
			mResourcesToLoad.push(_loc3_);

			_loc1_.load(Config.DIR_CONFIG + "army_config_pvp_opponents.json", "army_config_pvp_opponents");
			mResourcesToLoad.push("army_config_pvp_opponents");

			if (FeatureTuner.LOAD_TILE_MAP_CSV) {
				for each(_loc6_ in AssetManager.CVS_FILES_TO_LOAD) {
					_loc1_.load(Config.DIR_CONFIG + _loc6_ + ".csv", _loc6_);
					mResourcesToLoad.push(_loc6_);
				}
			}
			ArmySoundManager.getInstance();
			ArmySoundManager.load();
			this.mFileCountToLoad = _loc1_.getFileCountToLoad();
			Utils.DiagEvent("BOOT_RESOURCE_SET", "phase=first;pending=" + this.mFileCountToLoad + ";csv=" + AssetManager.CVS_FILES_TO_LOAD.join(","));
			var _loc5_: TextField;
			var _loc4_: MovieClip;
			(_loc5_ = (_loc4_ = mLoadingClip.getChildByName("Fill_Bar") as MovieClip).getChildByName("Text_Description") as TextField).text = Config.smLoadingDescription;
			LocalizationUtils.replaceFont(_loc5_);
			if (Config.DEBUG_MODE) {
				mLoadingClip.addEventListener(MouseEvent.MOUSE_MOVE, toggleDescription);
				mLoadingClip.mouseEnabled = true;
				mLoadingClip.mouseChildren = true;
			}

			// Start camera at default position until save file is loaded
			Cookie.saveCookieVariable(Config.COOKIE_SESSION_NAME,Config.COOKIE_SESSION_NAME_CAM_POS + "_Home","");
		}

		override public function logicUpdate(param1: int): void {
			var _loc5_: int = 0;
			var _loc6_: Object = null;
			var _loc7_: MyServer = null;
			if (mPercent >= 100) {
				if (!this.mFinishStarted) {
					this.mFinishStarted = true;
					try {
						Utils.DiagEvent("BOOT_PHASE", "phase=first;state=finalize_begin");
						this.loadingFinished();
					} catch (error: Error) {
						this.logTransitionFailure(error);
					}
				}
				return;
			}
			var _loc2_: DCResourceManager = DCResourceManager.getInstance();
			var _loc3_: int = _loc2_.getFileCountToLoad();
			var _loc4_: int = 100;
			if (this.mFileCountToLoad > 0) {
				_loc4_ = 100 - _loc3_ * 100 / this.mFileCountToLoad;
			}
			if (this.mGameState.mServer == null) {
				_loc5_ = 0;
				if (Config.isLoadingcomplete()) {
					this.mGameState.initServer();
					if (Config.CREATE_NEW_SESSION_IN_CLIENT) {
						this.mGameState.mServer.serverCallServiceWithParameters(ServiceIDs.CREATE_NEW_SESSION, {
							"ver": "0.0.1"
						}, true);
					}
					_loc6_ = {
						"map_id": "Home"
					};
					this.mGameState.mServer.serverCallServiceWithParameters(ServiceIDs.GET_USER_DATA, _loc6_, true);
					mServerResponsesNeeded.push(ServiceIDs.GET_USER_DATA);
				}
			} else if ((_loc7_ = this.mGameState.mServer).getNumberOfBlockingCalls() > 0 && !_loc7_.isConnectionError() && !_loc7_.isServerCommError()) {
				_loc5_ = 100 * (1 - _loc7_.getNumberOfBlockingCalls());
			} else {
				_loc5_ = 100;
			}
			setPercent((_loc4_ + _loc5_) / 2);
		}

		private function loadingFinished(): void {
			var _loc2_: Array = null;
			this.setFinalizeStep("fetch_user_data","begin");
			var _loc1_: ServerCall = this.mGameState.mServer.fetchResponseFromBuffer(ServiceIDs.GET_USER_DATA);
			this.setFinalizeStep("fetch_user_data","complete");

			this.setFinalizeStep("reset_loading_gates","begin");
			mServerResponsesNeeded.length = 0;
			mResourcesToLoad.length = 0;
			this.setFinalizeStep("reset_loading_gates","complete");

			this.setFinalizeStep("select_home_map","begin");
			this.mGameState.mCurrentMapId = "Home";
			this.mGameState.mCurrentMapGraphicsId = Math.max(GameState.GRAPHICS_MAP_ID_LIST.indexOf(this.mGameState.mCurrentMapId), 0);
			this.setFinalizeStep("select_home_map","complete");

			this.setFinalizeStep("initialize_config_graph","begin");
			this.mGameState.loadingFirstFinished();
			this.setFinalizeStep("initialize_config_graph","complete");

			this.setFinalizeStep("feed_publisher","begin");
			GameFeedPublisher.init(_loc1_);
			this.setFinalizeStep("feed_publisher","complete");

			this.setFinalizeStep("player_profile","begin");
			this.mGameState.initPlayerProfile(_loc1_);
			this.setFinalizeStep("player_profile","complete");

			this.setFinalizeStep("timers","begin");
			this.mGameState.initTimers(_loc1_);
			this.setFinalizeStep("timers","complete");

			this.setFinalizeStep("free_units","begin");
			if (_loc1_ != null) {
				_loc2_ = _loc1_.mData.gained_free_units as Array;
				this.mGameState.mShowFreeUnitsReceived = _loc2_ != null && _loc2_.length > 0;
			}
			this.setFinalizeStep("free_units","complete");

			this.setFinalizeStep("next_state","begin");
			goToNextState();
			this.setFinalizeStep("next_state","complete");
			Utils.DiagEvent("BOOT_PHASE", "phase=first;state=complete;next=second");
		}

		override protected function setLoadingBarPercent(param1: int): void {
			param1 = Math.max(0, param1);
			mLoadingFillBar.setValueWithoutBarAnimation(param1 * 90 / 100);
			var _loc2_: TextField = DisplayObjectContainer(mLoadingClip.getChildByName("Fill_Bar")).getChildByName("Progress") as TextField;
			_loc2_.text = int(param1 * 90 / 100) + "%";
		}

		override protected function initCursorManager(): void {
			var _loc1_: CursorManager = CursorManager.getInstance();
			_loc1_.init();
		}

		public function getLoadingPercent(): int {
			return mPercent;
		}
	}
}
