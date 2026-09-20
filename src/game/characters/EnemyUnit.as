package game.characters {
	import com.dchoc.graphics.DCResourceManager;
	import flash.display.MovieClip;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.MouseEvent;
	import flash.text.TextField;
	import flash.text.TextFieldAutoSize;
	import flash.text.TextFormat;
	import flash.text.TextFormatAlign;
	import game.actions.AcceptHelpSuppressEnemyUnitAction;
	import game.actions.Action;
	import game.actions.ActionQueue;
	import game.actions.EnemyAttackingAction;
	import game.actions.EnemyAttackingPlayerInstallationAction;
	import game.actions.EnemyMovingAction;
	import game.actions.RecapturePlayerBuildingAction;
	import game.actions.VisitNeighborSuppressEnemyUnitAction;
	import game.actions.WalkingAction;
	import game.battlefield.MapArea;
	import game.battlefield.MapData;
	import game.gameElements.ConstructionObject;
	import game.gameElements.PlayerBuildingObject;
	import game.gameElements.PlayerInstallationObject;
	import game.gameElements.ResourceBuildingObject;
	import game.gameElements.SignalObject;
	import game.gui.TooltipHealth;
	import game.isometric.GridCell;
	import game.isometric.IsometricScene;
	import game.isometric.boundingElements.BoundingCylinder;
	import game.isometric.camera.IsoCamera;
	import game.isometric.characters.IsometricCharacter;
	import game.items.EnemyUnitItem;
	import game.items.MapItem;
	import game.missions.MissionManager;
	import game.sound.ArmySoundManager;
	import game.sound.SoundCollection;
	import game.states.GameState;
	import game.utils.TimeUtils;

	public class EnemyUnit extends IsometricCharacter {

		public static const UNIT_ID_SCOUT: String = "Scout";

		public static const UNIT_ID_INFANTRY: String = "Infantry";

		public static const UNIT_ID_STORM_TROOPER: String = "StormTroop";

		public static const UNIT_ID_ELITE_STORM_TROOPER: String = "EliteStormtrooper";

		public static const UNIT_ID_APC: String = "APC";

		public static const UNIT_ID_ARTILLERY: String = "Artillery";

		public static const UNIT_ID_TANK: String = "Armor";

		public static const UNIT_ID_ROCKET_BATTERY: String = "RocketBattery";

		public static const UNIT_ID_WARFLY: String = "Warfly";

		public static const UNIT_ID_ELITE_WARFLY: String = "EliteWarfly";

		public static const UNIT_ID_SUPPLY_TRUCK: String = "SupplyTruck";

		public static const UNIT_ID_DROID: String = "Droid";

		public static const UNIT_ID_BULLDOZER: String = "Bulldozer";

		public static const UNIT_ID_SNIPER: String = "Sniper";

		public static const UNIT_ID_PREMIUM_TANK: String = "PremiumTank";

		public static const REACT_STATE_WAIT_FOR_TIMER: int = 0;

		public static const REACT_STATE_WAIT_FOR_ORDERS: int = 1;

		public static const REACT_STATE_WAIT_FOR_ORDERS_PREMIUM: int = 2;

		public static const REACT_STATE_ACTION: int = 3;

		public static const REACT_STATE_ACTION_COMPLETED: int = 4;

		public static const REACT_STATE_BYPASS_THE_LINE: int = 5;

		private static const ACTIVATION_NONE: int = 0;

		private static const ACTIVATION_IN_TOP_3: int = 2;


		public var mUnitId: String;

		public var mMovementRange: int;

		private var mReactionState: int;

		private var mNewReactionState: int;

		public var mReactionStateCounter: int;

		public var mReactionActivitionTimeInMinutes: int;

		private var mActivationTimeInMinutes: int;

		public var mRemainingTimeToNextAction: int;

		public var mCurrentAction: Action;

		public var mActionQueue: ActionQueue;

		private var mReactCounterTextField: TextField;

		public var mActivationIcon: MovieClip;

		private var mActivationIconState: int;

		private var mAlertSounds: SoundCollection;

		private var mMovementStepsLeft: int;

		public var mPermanentDestroyArray: Array;

		public var mUnderCloudImage: Sprite;

		private var mActivationIconVisible: int = -1;

		private var mWaitingForAirplane: Boolean = false;

		private static const OFFLINE_ATTACK_TWO_CHANCE: Number = 40;

		private static const OFFLINE_ATTACK_THREE_CHANCE: Number = 5;

		private var mOfflineAttackActionsRemaining: int = 0;

		private var mOfflineAttackTurnActive: Boolean = false;

		private var mOfflineResponseTurnActive:Boolean = false;
		private var mOfflineResponseRoundId:int = 0;
		private var mOfflineResponsePrimary:Boolean = false;
		private var mOfflineResponseMoved:Boolean = false;
		private var mOfflineResponseGroupLaunched:Boolean = false;
		private var mOfflineResponseLockedTarget:Object = null;
		private var mOfflineResponseRecentlyAttacked:Boolean = false;
		private var mOfflineResponseLastAttacker:PlayerUnit = null;

		public function EnemyUnit(param1: int, param2: IsometricScene, param3: MapItem) {
			var _loc4_: EnemyUnitItem = null;
			var _loc5_: Object = null;
			super(param1, param2, param3, null);
			_loc4_ = param3 as EnemyUnitItem;
			mName = _loc4_.mName;
			this.mUnitId = _loc4_.mId;
			mHealth = _loc4_.mHealth;
			mMaxHealth = mHealth;
			mMaxHealTimeInMinutes = _loc4_.mMaxHealTime;
			mPower = _loc4_.mDamage;
			this.mReactionActivitionTimeInMinutes = _loc4_.mReactionTime;
			this.mActivationTimeInMinutes = -1;
			this.mRemainingTimeToNextAction = -1;
			mHitRewardXP = _loc4_.mHitRewardXP;
			mHitRewardMoney = _loc4_.mHitRewardMoney;
			mHitRewardMaterial = _loc4_.mHitRewardMaterial;
			mHitRewardSupplies = _loc4_.mHitRewardSupplies;
			mHitRewardEnergy = _loc4_.mHitRewardEnergy;
			mKillRewardXP = _loc4_.mKillRewardXP;
			mKillRewardMoney = _loc4_.mKillRewardMoney;
			mKillRewardMaterial = _loc4_.mKillRewardMaterial;
			mKillRewardSupplies = _loc4_.mKillRewardSupplies;
			mKillRewardEnergy = _loc4_.mKillRewardEnergy;
			mAttackRange = _loc4_.mAttackRange;
			this.mMovementRange = _loc4_.mMovementRange;
			this.mPermanentDestroyArray = _loc4_.mPermanentDestroyArray;
			var _loc6_: Array = null;
			var _loc7_: int = int((_loc6_ = (param3 as EnemyUnitItem).mPassableGroups).length);
			var _loc8_: int = 0;
			while (_loc8_ < _loc7_) {
				_loc5_ = _loc6_[_loc8_] as Object;
				mMovementFlags |= 1 << MOVER_TYPE_PASSABILITY_OFFSET + MapData.TILE_PASSABILITY_STRING_TO_ID[_loc5_.ID];
				_loc8_++;
			}
			if ((param3 as EnemyUnitItem).mMovementType == MOVEMENT_TYPE_STEALTH) {
				mMovementFlags |= MOVER_TYPE_STEALTH_FLAG;
			}
			mWeaponType = _loc4_.mWeaponType;
			if (mWeaponType == null) {
				mWeaponType = IsometricCharacter.WEAPON_TYPE_EXPLOSION;
			}
			this.changeReactionState(REACT_STATE_WAIT_FOR_TIMER);
			mBoundingElement = new BoundingCylinder(0, 0, 50, 100, 25);
			mSpeed = 300;
			mContainer.mouseEnabled = false;
			mContainer.mouseChildren = false;
			initAnimations(_loc4_.mGraphicsArray);
			setPos(500, 500, 0);
			updateAnimation(true, false);
			mVisible = false;
			mContainer.visible = false;
			this.mActionQueue = new ActionQueue();
			updateMovement(0);
			if (FeatureTuner.USE_SOUNDS) {
				this.initSounds();
			}
		}

		override protected function initSounds(): void {
			super.initSounds();
			mAttackSoundsSecondary = ArmySoundManager.SC_ENM_ATTACK_SECONDARY;
			this.mAlertSounds = ArmySoundManager.SC_ENM_ALERT;
			switch (this.mUnitId) {
				case UNIT_ID_WARFLY:
				case UNIT_ID_ELITE_WARFLY:
				case UNIT_ID_INFANTRY:
				case UNIT_ID_SCOUT:
				case UNIT_ID_DROID:
					mMoveSounds = ArmySoundManager.SC_GENERAL_INFANTRY_MOVING;
					mDieSounds = ArmySoundManager.SC_ENM_INF_DEATH;
					mAttackSounds = ArmySoundManager.SC_ENM_INF_ATTACK;
					break;
				case UNIT_ID_SUPPLY_TRUCK:
				case UNIT_ID_APC:
					mMoveSounds = ArmySoundManager.SC_APC_MOVING;
					mDieSounds = ArmySoundManager.SC_ENM_APC_DEATH;
					mAttackSounds = ArmySoundManager.SC_ENM_APC_ATTACK;
					break;
				case UNIT_ID_TANK:
				case UNIT_ID_PREMIUM_TANK:
					mMoveSounds = ArmySoundManager.SC_TANK_MOVING;
					mDieSounds = ArmySoundManager.SC_ENM_TANK_DEATH;
					mAttackSounds = ArmySoundManager.SC_ENM_TANK_ATTACK;
					break;
				case UNIT_ID_ARTILLERY:
					mMoveSounds = ArmySoundManager.SC_ARTILLERY_MOVING;
					mDieSounds = ArmySoundManager.SC_ENM_ARTILLERY_DEATH;
					mAttackSounds = ArmySoundManager.SC_ENM_ARTILLERY_ATTACK;
					break;
				case UNIT_ID_ROCKET_BATTERY:
					mMoveSounds = ArmySoundManager.SC_ROCKET_MOVING;
					mDieSounds = ArmySoundManager.SC_ROCKET_DEATH;
					mAttackSounds = ArmySoundManager.SC_ROCKET_ATTACK;
					break;
				case UNIT_ID_ELITE_STORM_TROOPER:
				case UNIT_ID_STORM_TROOPER:
					mMoveSounds = ArmySoundManager.SC_GENERAL_INFANTRY_MOVING;
					mDieSounds = ArmySoundManager.SC_ENM_COMMANDO_DEATH;
					mAttackSounds = ArmySoundManager.SC_ENM_COMMANDO_ATTACK;
					break;
				case UNIT_ID_BULLDOZER:
					mMoveSounds = ArmySoundManager.SC_ROCKET_MOVING;
					mDieSounds = ArmySoundManager.SC_ROCKET_DEATH;
					mAttackSounds = ArmySoundManager.SC_ROCKET_ATTACK;
					break;
				case UNIT_ID_SNIPER:
					mMoveSounds = ArmySoundManager.SC_GENERAL_INFANTRY_MOVING;
					mDieSounds = ArmySoundManager.SC_ENM_INF_DEATH;
					mAttackSounds = ArmySoundManager.SC_ENM_INF_ATTACK;
					break;
				default:
					mMoveSounds = ArmySoundManager.SC_GENERAL_INFANTRY_MOVING;
					mDieSounds = ArmySoundManager.SC_ENM_INF_DEATH;
					mAttackSounds = ArmySoundManager.SC_ENM_INF_ATTACK;
					throw new Error("No sounds for EnemyUnit:" + mItem.mType + " id: " + mItem.mType);
			}
			mDieSounds.load();
			mAttackSounds.load();
			mAttackSoundsSecondary.load();
			mMoveSounds.load();
			this.mAlertSounds.load();
		}

		public function setActivationTime(param1: int): void {
			this.mActivationTimeInMinutes = param1;
		}

		override public function setupFromServer(param1: Object): void {
			super.setupFromServer(param1);
			if (param1.next_action_at != null) {
				this.mRemainingTimeToNextAction = param1.next_action_at * 1000;
			}
			if (mHealth == 0) {
				this.die();
			}
		}

		public function queueAction(param1: Action): void {
			GameState.mInstance.queueAction(param1, true);
		}

		override public function resetActions(): void {
			this.mActionQueue.mActions.length = 0;
			this.mCurrentAction = null;
			mWalkingPath.length = 0;
		}

		public function hasImportantActionsInQueue(): Boolean {
			var _loc1_: Action = null;
			if (this.mCurrentAction != null) {
				if (!(this.mCurrentAction is WalkingAction)) {
					return true;
				}
			}
			var _loc2_: int = int(this.mActionQueue.mActions.length);
			var _loc3_: int = 0;
			while (_loc3_ < _loc2_) {
				_loc1_ = this.mActionQueue.mActions[_loc3_] as Action;
				if (!(_loc1_ is WalkingAction)) {
					return true;
				}
				_loc3_++;
			}
			return false;
		}

		private function updateActivationIcon(): void {
			var _loc3_: Class = null;
			var _loc4_: int = 0;
			var _loc5_: Number = NaN;
			var _loc6_: Number = NaN;
			var _loc7_: Number = NaN;
			var _loc8_: Number = NaN;
			var _loc9_: Number = NaN;
			var _loc10_: Number = NaN;
			var _loc11_: int = 0;
			var _loc12_: int = 0;
			var _loc13_: int = 0;
			var _loc14_: int = 0;
			var _loc15_: int = 0;
			var _loc16_: int = 0;
			var _loc17_: int = 0;
			var _loc18_: Boolean = false;
			var _loc19_: MovieClip = null;
			var _loc20_: Number = NaN;
			if (!mScene.isInsideVisibleArea(getCell())) {
				return;
			}
			var _loc1_: int = 20;
			var _loc2_: Sprite = GameState.mInstance.mScene.mSceneHud;
			if (this.mReactionStateCounter <= 3) {
				this.showActivationIcon(true);

				if (this.mActivationIconState != ACTIVATION_IN_TOP_3) {
					this.changeActivationIcon("icon_status_urgent_enemy");
					this.mActivationIconState = ACTIVATION_IN_TOP_3;
					reactToZoom(mScene.mContainer.scaleX);
				}
				_loc4_ = 50;
				_loc5_ = this.mActivationIcon.x;
				_loc6_ = this.mActivationIcon.y;
				_loc7_ = GameState.mInstance.getStageWidth() * 0.5;
				_loc8_ = GameState.mInstance.getStageHeight() * 0.5;
				_loc9_ = mScene.mCamera.getCameraX();
				_loc10_ = mScene.mCamera.getCameraY();
				_loc11_ = mY + (mScene.mGridDimY >> 1) - _loc1_;
				_loc12_ = mX;
				_loc13_ = _loc11_;
				this.mActivationIcon.x = mX;
				this.mActivationIcon.y = _loc11_;
				_loc14_ = (-_loc7_ + _loc1_ + mScene.mGridDimX) / mScene.mContainer.scaleX;
				_loc15_ = (_loc7_ - _loc1_) / mScene.mContainer.scaleX;
				_loc16_ = (-_loc7_ + mScene.mGridDimY * 2) / mScene.mContainer.scaleY;
				_loc17_ = (_loc7_ - mScene.mGridDimY * 2 - _loc1_) / mScene.mContainer.scaleY - 5;
				if (_loc12_ < _loc9_ + _loc14_ - _loc4_) {
					_loc12_ = _loc9_ + _loc14_;
					_loc18_ = true;
				} else if (_loc12_ > _loc9_ + _loc15_) {
					_loc12_ = _loc9_ + _loc15_ - _loc4_;
					_loc18_ = true;
				}
				if (_loc13_ < _loc10_ + _loc16_ - _loc4_) {
					_loc13_ = _loc10_ + _loc16_;
					_loc18_ = true;
				} else if (_loc13_ > _loc10_ + _loc17_ + _loc4_) {
					_loc13_ = _loc10_ + _loc17_;
					_loc18_ = true;
				}
				if (_loc18_) {
					if (_loc5_ != _loc12_ || _loc6_ != _loc13_) {
						(_loc19_ = this.mActivationIcon.getChildAt(1) as MovieClip).visible = true;
						_loc20_ = Math.atan2(this.mActivationIcon.y - _loc13_, this.mActivationIcon.x - _loc12_);
						_loc19_.rotation = _loc20_ * 180 / Math.PI + 90;
					}
				} else if (_loc5_ != _loc12_ || _loc6_ != _loc13_) {
					(_loc19_ = this.mActivationIcon.getChildAt(1) as MovieClip).rotation = 0;
					_loc19_.visible = false;
				}
				this.mActivationIcon.x = _loc12_;
				this.mActivationIcon.y = _loc13_;
				this.showOffScreenArrowIcon(mContainer.visible && _loc18_);
			} else {
				this.showActivationIcon(false);
				if (this.mActivationIconState != ACTIVATION_NONE) {
					this.mActivationIconState = ACTIVATION_NONE;
				}

			}
		}

		private function showOffScreenArrowIcon(param1: Boolean): void {
			if (this.mActivationIcon) {
				if (param1 && !this.mActivationIcon.parent) {
					GameState.mInstance.mScene.mSceneHud.addChild(this.mActivationIcon);
					this.mActivationIcon.addEventListener(MouseEvent.CLICK, this.centerOnUnit, false, 0, true);
					this.mActivationIcon.buttonMode = true;
					this.mActivationIcon.mouseEnabled = true;
					this.mActivationIcon.mouseChildren = false;
				} else if (!param1 && Boolean(this.mActivationIcon.parent)) {
					this.mActivationIcon.parent.removeChild(this.mActivationIcon);
					this.mActivationIcon.removeEventListener(MouseEvent.CLICK, this.centerOnUnit);
				}
			}

		}

		private function centerOnUnit(param1: MouseEvent = null): void {
			var _loc2_: IsoCamera = null;
			if (FeatureTuner.USE_CAMERA_TRANSITION) {
				_loc2_ = GameState.mInstance.mScene.mCamera;
				_loc2_.setTargetTo(mX, mY);
			}
		}

		public function unSetActivationIcon(): void {

			this.showActivationIcon(false);
			this.showOffScreenArrowIcon(false);
			if (this.mActivationIcon) {
				this.mActivationIconState = ACTIVATION_NONE;
			}

		}

		private function changeActivationIcon(param1: String): void {

			if (this.mActivationIcon) {
				//this.mActivationIcon.addEventListener(Event.ENTER_FRAME, this.removeActionIcon);
				//if (this.mActivationIcon.parent) {
				//	this.mActivationIcon.parent.removeChild(this.mActivationIcon);
				//}
			}
			var _loc2_: Class = DCResourceManager.getInstance().getSWFClass(Config.SWF_INTERFACE_NAME, param1);
			//this.mActivationIcon = new _loc2_();
			var _loc8_: MovieClip = null;
			var _loc3_: int = 0;
			var _loc4_: MovieClip = null;
			var _loc5_: MovieClip = null;
			if (!mAnimationController) {
				return;
			}
							_loc8_ = mAnimationController.getCurrentAnimation();
				_loc3_ = 0;
				while (_loc3_ < _loc8_.numChildren) {
					if (_loc5_ = (_loc4_ = _loc8_.getChildAt(_loc3_) as MovieClip).getChildByName("Hint_Health_Friendly_Attention") as MovieClip) {
						_loc5_.visible = true;
						this.mActivationIcon = _loc5_
						this.mActivationIcon.addEventListener(Event.ENTER_FRAME, this.removeActionIcon);
					}
					if (_loc5_ = (_loc4_ = _loc8_.getChildAt(_loc3_) as MovieClip).getChildByName("Hint_Health_Friendly") as MovieClip) {
						_loc5_.visible = true;
					}
					_loc3_++;
				}
		    
			this.showOffScreenArrowIcon(true);

		}

		private function removeActionIcon(param1: Event): void {

			if (this.mActivationIcon) {
				if (this.mActivationIcon.currentFrame == this.mActivationIcon.totalFrames) {
					//if (this.mActivationIcon.parent) {
					//	this.mActivationIcon.parent.removeChild(this.mActivationIcon);
					//}
					//this.mActivationIcon.stop();
					//this.mActivationIcon.removeEventListener(Event.ENTER_FRAME, this.removeActionIcon);
					//this.mActivationIcon = null;
				    //trace("removed activation icon")
				}
			}

		}

		public function reloadAvatar(param1: String, param2: Array): void {}

		override public function update(param1: int): void {
			super.update(param1);
			if (!isAlive()) {
				// A mine can kill the acting enemy inside EnemyAttackingAction.execute().
				// Death resets its action queue, so REACT_STATE_ACTION_COMPLETED never
				// fires and the three-primary enemy round otherwise remains locked.
				// Complete at the character update boundary, not reentrantly while
				// the mine blast iterates its other victims.
				if (Config.OFFLINE_MODE && this.mOfflineResponseTurnActive) {
					Utils.DiagEvent("ENEMY_RESPONSE_ACTOR_DIED","map=" + (GameState.mInstance ? GameState.mInstance.mCurrentMapId : "") + ";enemy=" + this.mUnitId + ";round=" + this.mOfflineResponseRoundId + ";primary=" + this.mOfflineResponsePrimary);
					this.finishOfflineResponseTurn("actor_died_during_response");
				}
				return;
			}
			if (mState == STATE_SUPPRESS) {
				if (mActionDelayTimer <= 0) {
					mState = STATE_WALKING;
				}
			} else if (mState == STATE_AIR_DROP) {
				mAnimationController.getCurrentAnimationFrameLabel();
				if (!mScene.mParatrooperAnimation && this.mWaitingForAirplane) {
					mAnimationController.playCurrentAnimation();
					this.mWaitingForAirplane = false;
				} else if (mAnimationController.getCurrentAnimationFrameLabel() == "end") {
					setAnimationAction(AnimationController.CHARACTER_ANIMATION_IDLE, false, true);
					mState = STATE_WALKING;
					mScene.characterArrivedInCell(this, this.getCell(), false);
				}
			} else if (GameState.mInstance.mState != GameState.STATE_VISITING_NEIGHBOUR) {
				this.updateReactionState(param1);
				if (GameState.smCheatCodeTyped) {
					if (this.mReactCounterTextField) {
						this.mReactCounterTextField.x = mX;
						this.mReactCounterTextField.y = mY;
					}
				}
			}
			if (!this.mUnderCloudImage) {
				this.loadUnderCloudImage();
			}
		}

		public function hasPriorityPlayerTargetInRange(): Boolean {
			return this.findPriorityPlayerTargetInRange() != null;
		}

		private function findPriorityPlayerTargetInRange(): PlayerUnit {
			var origin: GridCell = getCell();
			if (!origin || mAttackRange < 1) {
				return null;
			}
			var best: PlayerUnit = null;
			var bestDistanceSq: int = int.MAX_VALUE;
			var x: int = origin.mPosI - mAttackRange;
			var y: int = 0;
			var cell: GridCell = null;
			var candidate: PlayerUnit = null;
			var dx: int = 0;
			var dy: int = 0;
			var distanceSq: int = 0;
			while (x <= origin.mPosI + mAttackRange) {
				y = origin.mPosJ - mAttackRange;
				while (y <= origin.mPosJ + mAttackRange) {
					cell = mScene.getCellAt(x, y);
					if (cell && cell.mCharacter && cell.mCharacter is PlayerUnit && cell.mCharacter.isAlive()) {
						candidate = cell.mCharacter as PlayerUnit;
						dx = int(Math.abs(x - origin.mPosI));
						dy = int(Math.abs(y - origin.mPosJ));
						if (dx <= mAttackRange && dy <= mAttackRange) {
							distanceSq = dx * dx + dy * dy;
							if (distanceSq < bestDistanceSq) {
								best = candidate;
								bestDistanceSq = distanceSq;
							}
						}
					}
					y++;
				}
				x++;
			}
			return best;
		}

		private function findPriorityPlayerObjectCellInRange(): GridCell {
			var origin: GridCell = getCell();
			if (!origin || mAttackRange < 1) return null;
			var best: GridCell = null;
			var bestDistanceSq: int = int.MAX_VALUE;
			var x: int = origin.mPosI - mAttackRange;
			var y: int = 0;
			var cell: GridCell = null;
			var dx: int = 0;
			var dy: int = 0;
			var distanceSq: int = 0;
			var attackable: Boolean = false;
			while (x <= origin.mPosI + mAttackRange) {
				y = origin.mPosJ - mAttackRange;
				while (y <= origin.mPosJ + mAttackRange) {
					cell = mScene.getCellAt(x, y);
					attackable = false;
					if (cell && cell.mObject) {
						if (cell.mObject is PlayerInstallationObject && (cell.mObject as PlayerInstallationObject).getHealth() > 0) {
							attackable = true;
						} else if (cell.mObject is PlayerBuildingObject && !(cell.mObject is ResourceBuildingObject) && !(cell.mObject is SignalObject) && (cell.mObject as PlayerBuildingObject).getHealth() > 0) {
							attackable = !(cell.mObject is ConstructionObject) || (cell.mObject as ConstructionObject).mHasBeenCompleted;
						}
					}
					if (attackable) {
						dx = int(Math.abs(x - origin.mPosI));
						dy = int(Math.abs(y - origin.mPosJ));
						if (dx <= mAttackRange && dy <= mAttackRange) {
							distanceSq = dx * dx + dy * dy;
							if (distanceSq < bestDistanceSq) {
								best = cell;
								bestDistanceSq = distanceSq;
							}
						}
					}
					y++;
				}
				x++;
			}
			return best;
		}

		public function hasPriorityAttackTargetInRange(): Boolean {
			return this.findPriorityPlayerTargetInRange() != null || this.findPriorityPlayerObjectCellInRange() != null;
		}


		public function canStartOfflineResponseTurn():Boolean {
			if (!Config.OFFLINE_MODE || !GameState.mInstance || GameState.mInstance.mState != GameState.STATE_PLAY) return false;
			if (!this.isAlive() || this.mOfflineResponseTurnActive) return false;
			if (mState == STATE_AIR_DROP || mState == STATE_SUPPRESS) return false;
			if (this.hasImportantActionsInQueue()) return false;
			return this.mReactionState != REACT_STATE_ACTION && this.mReactionState != REACT_STATE_ACTION_COMPLETED;
		}

		public function noteOfflinePlayerAttacker(param1:PlayerUnit):void {
			if (!Config.OFFLINE_MODE || !param1 || !param1.isAlive()) return;
			this.mOfflineResponseLastAttacker = param1;
		}

		public function wasRecentlyAttackedForOfflineResponse():Boolean {
			return this.mOfflineResponseRecentlyAttacked && this.isAlive();
		}

		public function prepareOfflineResponseTurn(param1:int, param2:Boolean):void {
			if (param2) this.mOfflineResponseRecentlyAttacked = false;
			this.endOfflineAttackTurn();
			this.mOfflineResponseTurnActive = true;
			this.mOfflineResponseRoundId = param1;
			this.mOfflineResponsePrimary = param2;
			this.mOfflineResponseMoved = false;
			this.mOfflineResponseGroupLaunched = false;
			this.mOfflineResponseLockedTarget = null;
			this.mMovementStepsLeft = 1;
			Utils.DiagEvent("ENEMY_RESPONSE_TURN_BEGIN","map=" + GameState.mInstance.mCurrentMapId + ";round=" + param1 + ";enemy=" + this.mUnitId + ";primary=" + param2);
			this.changeReactionState(REACT_STATE_ACTION);
		}

		private function canAttackOfflineTarget(param1:Object):Boolean {
			if (!param1 || !this.isAlive() || !this.getCell()) return false;
			var targetCell:GridCell = null;
			var dx:int = 0;
			var dy:int = 0;
			if (param1 is PlayerUnit) {
				if (!(param1 as PlayerUnit).isAlive()) return false;
				targetCell = (param1 as PlayerUnit).getCell();
				if (!targetCell) return false;
				dx = int(Math.abs(targetCell.mPosI - getCell().mPosI));
				dy = int(Math.abs(targetCell.mPosJ - getCell().mPosJ));
				return dx <= mAttackRange && dy <= mAttackRange;
			}
			if (param1 is PlayerInstallationObject) {
				if ((param1 as PlayerInstallationObject).getHealth() <= 0) return false;
				targetCell = (param1 as PlayerInstallationObject).getCell();
				if (!targetCell) return false;
				dx = int(Math.abs(targetCell.mPosI - getCell().mPosI));
				dy = int(Math.abs(targetCell.mPosJ - getCell().mPosJ));
				return dx <= mAttackRange && dy <= mAttackRange;
			}
			if (param1 is PlayerBuildingObject) {
				var building:PlayerBuildingObject = param1 as PlayerBuildingObject;
				if (building.getHealth() <= 0 || building is ResourceBuildingObject || building is SignalObject) return false;
				if (building is ConstructionObject && !(building as ConstructionObject).mHasBeenCompleted) return false;
				var area:MapArea = MapArea.getArea(mScene,building.getCell().mPosI,building.getCell().mPosJ,building.getTileSize().x,building.getTileSize().y);
				var cells:Array = area.getCells();
				var i:int = 0;
				while (i < cells.length) {
					targetCell = cells[i] as GridCell;
					if (targetCell) {
						dx = int(Math.abs(targetCell.mPosI - getCell().mPosI));
						dy = int(Math.abs(targetCell.mPosJ - getCell().mPosJ));
						if (dx <= mAttackRange && dy <= mAttackRange) return true;
					}
					++i;
				}
			}
			return false;
		}

		private function selectOfflineResponseTarget():Object {
			if (this.mOfflineResponseLastAttacker && this.canAttackOfflineTarget(this.mOfflineResponseLastAttacker)) return this.mOfflineResponseLastAttacker;
			if (this.mOfflineResponseLockedTarget && this.canAttackOfflineTarget(this.mOfflineResponseLockedTarget)) return this.mOfflineResponseLockedTarget;
			var unit:PlayerUnit = this.findPriorityPlayerTargetInRange();
			if (unit) return unit;
			var objectCell:GridCell = this.findPriorityPlayerObjectCellInRange();
			return objectCell ? objectCell.mObject : null;
		}

		private function queueOfflineResponseAttack(param1:Object):Boolean {
			if (!this.canAttackOfflineTarget(param1)) return false;
			if (param1 is PlayerUnit) { this.attackPlayerUnit(param1 as PlayerUnit); return true; }
			if (param1 is PlayerInstallationObject) { this.attackPlayerInstallation(param1 as PlayerInstallationObject); return true; }
			if (param1 is PlayerBuildingObject) { this.attackPlayerBuilding(param1 as PlayerBuildingObject); return true; }
			return false;
		}

		private function launchOfflineGroupAssists(param1:Object):void {
			if (!this.mOfflineResponsePrimary || this.mOfflineResponseGroupLaunched || !param1 || !GameState.mInstance) return;
			this.mOfflineResponseGroupLaunched = true;
			var enemies:Array = mScene.getEnemyUnits();
			var i:int = 0;
			var ally:EnemyUnit = null;
			var assists:int = 0;
			while (enemies && i < enemies.length) {
				ally = enemies[i] as EnemyUnit;
				if (ally && ally != this && ally.canStartOfflineResponseTurn() && ally.canAttackOfflineTarget(param1)) {
					if (GameState.mInstance.registerOfflineEnemyAssist(ally,this.mOfflineResponseRoundId)) {
						if (ally.startOfflineAssistAttack(param1,this.mOfflineResponseRoundId)) ++assists;
						else GameState.mInstance.releaseOfflineEnemyAssist(ally,this.mOfflineResponseRoundId);
					}
				}
				++i;
			}
			Utils.DiagEvent("ENEMY_GROUP_ATTACK","map=" + GameState.mInstance.mCurrentMapId + ";round=" + this.mOfflineResponseRoundId + ";primary=" + this.mUnitId + ";assists=" + assists);
		}

		public function startOfflineAssistAttack(param1:Object, param2:int):Boolean {
			if (!this.canStartOfflineResponseTurn() || !this.canAttackOfflineTarget(param1)) return false;
			this.endOfflineAttackTurn();
			this.mOfflineResponseTurnActive = true;
			this.mOfflineResponseRoundId = param2;
			this.mOfflineResponsePrimary = false;
			this.mOfflineResponseMoved = false;
			this.mOfflineResponseGroupLaunched = true;
			this.mOfflineResponseLockedTarget = param1;
			this.beginOfflineAttackTurn();
			this.mReactionState = REACT_STATE_ACTION;
			this.mNewReactionState = -1;
			if (!this.queueOfflineResponseAttack(param1)) {
				this.mOfflineResponseTurnActive = false;
				this.endOfflineAttackTurn();
				return false;
			}
			this.consumeOfflineAttackAction();
			Utils.DiagEvent("ENEMY_GROUP_ATTACK_ASSIST","map=" + GameState.mInstance.mCurrentMapId + ";round=" + param2 + ";enemy=" + this.mUnitId + ";remaining=" + this.mOfflineAttackActionsRemaining);
			return true;
		}

		private function finishOfflineResponseTurn(param1:String):void {
			var roundId:int = this.mOfflineResponseRoundId;
			var wasPrimary:Boolean = this.mOfflineResponsePrimary;
			this.endOfflineAttackTurn();
			this.mOfflineResponseTurnActive = false;
			this.mOfflineResponseRoundId = 0;
			this.mOfflineResponsePrimary = false;
			this.mOfflineResponseMoved = false;
			this.mOfflineResponseGroupLaunched = false;
			this.mOfflineResponseLockedTarget = null;
			this.mMovementStepsLeft = 0;
			if (this.isAlive()) {
				this.changeReactionState(REACT_STATE_WAIT_FOR_TIMER);
				this.updateActivationIcon();
			}
			if (GameState.mInstance) GameState.mInstance.completeOfflineEnemyResponseTurn(this,roundId,wasPrimary,param1);
		}

		private function executeOfflineResponseTurnAction():void {
			this.mReactionStateCounter = 0;
			this.reconcileCampaignTerritoryUnderEnemy();
			var target:Object = this.selectOfflineResponseTarget();
			if (target) {
				this.mOfflineResponseLockedTarget = target;
				if (!this.mOfflineAttackTurnActive) this.beginOfflineAttackTurn();
				if (this.mOfflineResponsePrimary) this.launchOfflineGroupAssists(target);
				this.mReactionState = REACT_STATE_ACTION;
				this.mNewReactionState = -1;
				if (this.queueOfflineResponseAttack(target)) {
					this.consumeOfflineAttackAction();
					this.mMovementStepsLeft = 0;
					Utils.DiagEvent("ENEMY_RESPONSE_ATTACK","map=" + GameState.mInstance.mCurrentMapId + ";round=" + this.mOfflineResponseRoundId + ";enemy=" + this.mUnitId + ";primary=" + this.mOfflineResponsePrimary + ";remaining=" + this.mOfflineAttackActionsRemaining + ";after_move=" + this.mOfflineResponseMoved);
					return;
				}
				this.finishOfflineResponseTurn("attack_queue_failed");
				return;
			}
			if (this.mOfflineResponsePrimary && !this.mOfflineResponseMoved) {
				this.mOfflineResponseMoved = true;
				this.mMovementStepsLeft = 1;
				Utils.DiagEvent("ENEMY_RESPONSE_MOVE","map=" + GameState.mInstance.mCurrentMapId + ";round=" + this.mOfflineResponseRoundId + ";enemy=" + this.mUnitId);
				this.queueAction(new EnemyMovingAction(this));
				return;
			}
			this.finishOfflineResponseTurn(this.mOfflineResponseMoved ? "move_complete_no_target" : "no_target");
		}

		private function completeOfflineResponseAction():void {
			if (this.mOfflineAttackTurnActive) {
				if (this.mOfflineAttackActionsRemaining > 0 && this.mOfflineResponseLockedTarget && this.canAttackOfflineTarget(this.mOfflineResponseLockedTarget)) {
					this.mReactionState = REACT_STATE_ACTION;
					this.mNewReactionState = -1;
					if (this.queueOfflineResponseAttack(this.mOfflineResponseLockedTarget)) {
						this.consumeOfflineAttackAction();
						Utils.DiagEvent("ENEMY_RESPONSE_ATTACK_REPEAT","map=" + GameState.mInstance.mCurrentMapId + ";round=" + this.mOfflineResponseRoundId + ";enemy=" + this.mUnitId + ";remaining=" + this.mOfflineAttackActionsRemaining);
						return;
					}
				}
				this.endOfflineAttackTurn();
				this.finishOfflineResponseTurn("attack_budget_complete");
				return;
			}
			if (this.mOfflineResponsePrimary && this.mOfflineResponseMoved) {
				var postMoveTarget:Object = this.selectOfflineResponseTarget();
				if (postMoveTarget) {
					this.mOfflineResponseLockedTarget = postMoveTarget;
					this.changeReactionState(REACT_STATE_ACTION);
					return;
				}
			}
			this.finishOfflineResponseTurn(this.mOfflineResponseMoved ? "move_complete" : "action_complete");
		}

		private function reconcileCampaignTerritoryUnderEnemy(): void {
			if (!Config.OFFLINE_MODE || !GameState.mInstance || GameState.mInstance.mState != GameState.STATE_PLAY || String(GameState.mInstance.mCurrentMapId).indexOf("pvp_") == 0) return;
			var cell: GridCell = getCell();
			if (!cell || cell.mOwner != MapData.TILE_OWNER_FRIENDLY) return;
			var ownerBefore: int = cell.mOwner;
			mScene.characterArrivedInCell(this, cell, false);
			if (cell.mOwner != ownerBefore) {
				Utils.DiagEvent("CAMPAIGN_TERRITORY_CAPTURE","map=" + GameState.mInstance.mCurrentMapId + ";side=enemy;enemy=" + this.mUnitId + ";x=" + cell.mPosI + ";y=" + cell.mPosJ + ";before=" + ownerBefore + ";after=" + cell.mOwner + ";reason=turn_reconcile;visual_commit=scene");
			}
		}

		private function beginOfflineAttackTurn(): void {
			if (!Config.OFFLINE_MODE || this.mOfflineAttackTurnActive) return;
			var roll: Number = Math.random() * 100;
			if (roll < OFFLINE_ATTACK_THREE_CHANCE) {
				this.mOfflineAttackActionsRemaining = 3;
			} else if (roll < OFFLINE_ATTACK_THREE_CHANCE + OFFLINE_ATTACK_TWO_CHANCE) {
				this.mOfflineAttackActionsRemaining = 2;
			} else {
				this.mOfflineAttackActionsRemaining = 1;
			}
			this.mOfflineAttackTurnActive = true;
			Utils.DiagEvent("ENEMY_ATTACK_TURN","map=" + GameState.mInstance.mCurrentMapId + ";enemy=" + this.mUnitId + ";attacks=" + this.mOfflineAttackActionsRemaining + ";p1=55;p2=40;p3=5;round=" + this.mOfflineResponseRoundId + ";primary=" + this.mOfflineResponsePrimary);
		}

		private function consumeOfflineAttackAction(): void {
			if (this.mOfflineAttackTurnActive && this.mOfflineAttackActionsRemaining > 0) --this.mOfflineAttackActionsRemaining;
		}

		private function endOfflineAttackTurn(): void {
			this.mOfflineAttackTurnActive = false;
			this.mOfflineAttackActionsRemaining = 0;
		}

		private function updateReactionState(param1: int): void {
			var _loc2_: int = 0;
			var _loc3_: int = 0;
			var _loc4_: Boolean = false;
			var _loc5_: Boolean = false;
			var _loc6_: Boolean = false;
			var _loc7_: GridCell = null;
			var _loc8_: int = 0;
			var _loc9_: int = 0;
			var _loc10_: int = 0;
			var _loc11_: TextFormat = null;
			var _loc12_: PlayerUnit = null;
			var _loc13_: Boolean = false;
			var _loc14_: GridCell = null;
			if (this.mNewReactionState > -1) {
				this.mReactionState = this.mNewReactionState;
				this.mNewReactionState = -1;
				switch (this.mReactionState) {
					case REACT_STATE_WAIT_FOR_TIMER:
						if (this.mRemainingTimeToNextAction >= 0) {
							this.mReactionStateCounter = this.mRemainingTimeToNextAction;
							this.mRemainingTimeToNextAction = -1;
						} else if (this.mActivationTimeInMinutes > 0) {
							this.mReactionStateCounter = this.mActivationTimeInMinutes * 60000;
							this.mActivationTimeInMinutes = 0;
						} else {
							this.mReactionStateCounter = this.mReactionActivitionTimeInMinutes * 60000;
						}
						this.unSetActivationIcon();
						break;
					case REACT_STATE_WAIT_FOR_ORDERS:
						this.mReactionStateCounter = mScene.getNextEnemyUnitActionQueueNumber();
						break;
					case REACT_STATE_WAIT_FOR_ORDERS_PREMIUM:
						this.changeReactionState(REACT_STATE_WAIT_FOR_ORDERS);
						mScene.setPremiumEnemyUnitActionQueueNumber(this);
						break;
					case REACT_STATE_BYPASS_THE_LINE:
						this.mReactionState = REACT_STATE_WAIT_FOR_ORDERS;
						this.mReactionStateCounter = 1;
						break;
					case REACT_STATE_ACTION:
						if (Config.OFFLINE_MODE && GameState.mInstance && GameState.mInstance.mState == GameState.STATE_PLAY && this.mOfflineResponseTurnActive) {
							this.executeOfflineResponseTurnAction();
							break;
						}
						this.mReactionStateCounter = 0;
						this.reconcileCampaignTerritoryUnderEnemy();
						_loc2_ = getCell().mPosI;
						_loc3_ = getCell().mPosJ;
						_loc12_ = this.findPriorityPlayerTargetInRange();
						_loc14_ = this.findPriorityPlayerObjectCellInRange();
						if (_loc12_) {
							this.beginOfflineAttackTurn();
							Utils.DiagEvent("ENEMY_ATTACK_PRIORITY","map=" + GameState.mInstance.mCurrentMapId + ";enemy=" + this.mUnitId + ";target_type=unit;range=" + mAttackRange + ";enemy_x=" + _loc2_ + ";enemy_y=" + _loc3_ + ";target_x=" + _loc12_.getCell().mPosI + ";target_y=" + _loc12_.getCell().mPosJ + ";turn_remaining=" + this.mOfflineAttackActionsRemaining);
							this.attackPlayerUnit(_loc12_);
							this.consumeOfflineAttackAction();
							this.mMovementStepsLeft = 0;
							break;
						}
						if (_loc14_ && _loc14_.mObject is PlayerInstallationObject) {
							this.beginOfflineAttackTurn();
							Utils.DiagEvent("ENEMY_ATTACK_PRIORITY","map=" + GameState.mInstance.mCurrentMapId + ";enemy=" + this.mUnitId + ";target_type=installation;range=" + mAttackRange + ";target_x=" + _loc14_.mPosI + ";target_y=" + _loc14_.mPosJ + ";turn_remaining=" + this.mOfflineAttackActionsRemaining);
							this.attackPlayerInstallation(_loc14_.mObject as PlayerInstallationObject);
							this.consumeOfflineAttackAction();
							this.mMovementStepsLeft = 0;
							break;
						}
						if (_loc14_ && _loc14_.mObject is PlayerBuildingObject) {
							this.beginOfflineAttackTurn();
							Utils.DiagEvent("ENEMY_ATTACK_PRIORITY","map=" + GameState.mInstance.mCurrentMapId + ";enemy=" + this.mUnitId + ";target_type=building;range=" + mAttackRange + ";target_x=" + _loc14_.mPosI + ";target_y=" + _loc14_.mPosJ + ";turn_remaining=" + this.mOfflineAttackActionsRemaining);
							this.attackPlayerBuilding(_loc14_.mObject as PlayerBuildingObject);
							this.consumeOfflineAttackAction();
							this.mMovementStepsLeft = 0;
							break;
						}
						this.endOfflineAttackTurn();
						if (this.mMovementStepsLeft <= 0) this.mMovementStepsLeft = this.mMovementRange;
						this.queueAction(new EnemyMovingAction(this));
						break;
					case REACT_STATE_ACTION_COMPLETED:
						if (Config.OFFLINE_MODE && this.mOfflineResponseTurnActive) {
							this.completeOfflineResponseAction();
							break;
						}
						if (Config.OFFLINE_MODE && this.mOfflineAttackTurnActive) {
							if (this.mOfflineAttackActionsRemaining > 0 && this.hasPriorityAttackTargetInRange()) {
								this.changeReactionState(REACT_STATE_ACTION);
							} else {
								this.endOfflineAttackTurn();
								this.changeReactionState(REACT_STATE_WAIT_FOR_TIMER);
								this.updateActivationIcon();
							}
							break;
						}
						--this.mMovementStepsLeft;
						if (this.mMovementStepsLeft > 0) {
							this.changeReactionState(REACT_STATE_ACTION);
						} else {
							this.changeReactionState(REACT_STATE_WAIT_FOR_TIMER);
							this.updateActivationIcon();
						}
				}
				if (GameState.smCheatCodeTyped) {
					if (this.mReactCounterTextField) {
						this.mReactCounterTextField.visible = false;
					}
				}
			}
			switch (this.mReactionState) {
				case REACT_STATE_WAIT_FOR_TIMER:
					if (this.mReactionStateCounter > 0) {
						this.mReactionStateCounter -= param1;
					} else {
						this.changeReactionState(REACT_STATE_WAIT_FOR_ORDERS);
					}
					this.showActivationIcon(false);
					break;
				case REACT_STATE_WAIT_FOR_ORDERS:
					if (Config.OFFLINE_MODE && GameState.mInstance && GameState.mInstance.mState == GameState.STATE_PLAY && !this.mOfflineResponseTurnActive) {
						this.updateActivationIcon();
						break;
					}
					if (!MissionManager.modalMissionActive()) {
						if (this.mReactionStateCounter <= 0) {
							this.changeReactionState(REACT_STATE_ACTION);
						}
					}
					this.updateActivationIcon();
					if (Config.DEBUG_ENEMY_QUEUE_NUMBERS) {
						if (!this.mReactCounterTextField) {
							this.mReactCounterTextField = new TextField();
							this.mReactCounterTextField.autoSize = TextFieldAutoSize.RIGHT;
							this.mReactCounterTextField.mouseEnabled = false;
							this.mReactCounterTextField.defaultTextFormat = Config.TEXT_FORMAT;
							(_loc11_ = new TextFormat()).align = TextFormatAlign.RIGHT;
							this.mReactCounterTextField.defaultTextFormat = _loc11_;
							mScene.mSceneHud.addChild(this.mReactCounterTextField);
							this.mReactCounterTextField.visible = false;
						}
					}
					if (GameState.smCheatCodeTyped) {
						if (this.mReactCounterTextField) {
							this.mReactCounterTextField.text = "" + this.mReactionStateCounter;
							this.mReactCounterTextField.visible = mContainer.visible;
						}
					}
					break;
				case REACT_STATE_ACTION:
				case REACT_STATE_ACTION_COMPLETED:
			}
		}

		public function reduceMovementCounter(): void {
			--this.mMovementStepsLeft;
			if (this.mMovementStepsLeft > 0) {
				this.changeReactionState(REACT_STATE_ACTION);
			}
		}

		public function nullMovementCounter(): void {
			this.mMovementStepsLeft = 0;
		}

		public function destroysPermanently(param1: MapItem): Boolean {
			var _loc2_: Object = null;
			var _loc3_: int = 0;
			var _loc4_: int = 0;
			if (this.mPermanentDestroyArray) {
				_loc3_ = int(this.mPermanentDestroyArray.length);
				_loc4_ = 0;
				while (_loc4_ < _loc3_) {
					_loc2_ = this.mPermanentDestroyArray[_loc4_] as Object;
					if (param1.mId == _loc2_.ID) {
						if (param1.mType == _loc2_.Type) {
							return true;
						}
					}
					_loc4_++;
				}
			}
			return false;
		}

		override public function die(): void {
			super.die();
			var _loc1_: * = Math.random() * 100 < GameState.mConfig.DebrisSetup.SpawnAfterEnemy.Probability;
			if (_loc1_) {
				GameState.mInstance.spawnNewDebris(GameState.mConfig.DebrisSetup.SpawnAfterEnemy.DebrisObject.ID, GameState.mConfig.DebrisSetup.SpawnAfterEnemy.DebrisObject.Type, mX, mY);
			}
			this.unSetActivationIcon();
			if (this.mReactCounterTextField) {
				if (this.mReactCounterTextField.parent) {
					this.mReactCounterTextField.parent.removeChild(this.mReactCounterTextField);
				}
				this.mReactCounterTextField = null;
			}
			this.mMovementStepsLeft = 0;
			if (this.mUnderCloudImage) {
				if (this.mUnderCloudImage.parent) {
					mScene.mSceneHud.removeChild(this.mUnderCloudImage);
				}
				this.mUnderCloudImage = null;
			}
		}

		public function changeReactionState(param1: int): void {
			if (param1 == this.mReactionState) {
				return;
			}
			if (param1 == REACT_STATE_ACTION) {
				if (getContainer().visible) {
					if (FeatureTuner.USE_SOUNDS) {
						ArmySoundManager.getInstance().playSound(this.mAlertSounds.getSound());
					}
				}
			}
			this.mNewReactionState = param1;
		}

		public function getReactionState(): int {
			return this.mReactionState;
		}

		override public function startAction(): void {
			super.startAction();
		}

		override public function stopAction(): void {
			super.stopAction();
			this.resetActions();
		}

		override public function reduceHealth(param1: int, param2: int = 0): void {
			if (Config.OFFLINE_MODE && GameState.mInstance && GameState.mInstance.mState == GameState.STATE_PLAY && param1 > 0 && this.isAlive()) {
				this.mOfflineResponseRecentlyAttacked = true;
				// The attack action supplies the exact attacking player unit, if any.
				Utils.DiagEvent("ENEMY_RESPONSE_HIT_PRIORITY","map=" + GameState.mInstance.mCurrentMapId + ";enemy=" + this.mUnitId + ";attacker_known=" + Boolean(this.mOfflineResponseLastAttacker));
			}
			super.reduceHealth(param1, param2);
		}

		public function attackPlayerUnit(param1: PlayerUnit = null): void {
			var _loc2_: int = 0;
			if (!isAlive()) {
				return;
			}
			if (this.hasAttackActionInQueue()) {
				return;
			}
			if (param1) {
				_loc2_ = Math.abs(param1.getCell().mPosI - getCell().mPosI);
				if (_loc2_ > mAttackRange) {
					return;
				}
				_loc2_ = Math.abs(param1.getCell().mPosJ - getCell().mPosJ);
				if (_loc2_ > mAttackRange) {
					return;
				}
			}
			this.queueAction(new EnemyAttackingAction(this, param1));
		}

		public function attackPlayerBuilding(param1: PlayerBuildingObject): void {
			var _loc2_: MapArea = null;
			var _loc3_: GridCell = null;
			var _loc4_: Array = null;
			var _loc5_: int = 0;
			var _loc6_: int = 0;
			var _loc7_: int = 0;
			if (!isAlive() || param1 && param1 is ResourceBuildingObject) {
				return;
			}
			if (param1) {
				_loc2_ = MapArea.getArea(mScene, param1.getCell().mPosI, param1.getCell().mPosJ, param1.getTileSize().x, param1.getTileSize().y);
				_loc4_ = null;
				_loc5_ = int((_loc4_ = _loc2_.getCells()).length);
				_loc6_ = 0;
				while (_loc6_ < _loc5_) {
					_loc3_ = _loc4_[_loc6_] as GridCell;
					if ((_loc7_ = Math.abs(_loc3_.mPosI - getCell().mPosI)) <= mAttackRange) {
						if ((_loc7_ = Math.abs(_loc3_.mPosJ - getCell().mPosJ)) <= mAttackRange) {
							this.queueAction(new RecapturePlayerBuildingAction([this], param1));
							return;
						}
					}
					_loc6_++;
				}
			}
		}

		public function attackPlayerInstallation(param1: PlayerInstallationObject): void {
			var _loc2_: int = 0;
			if (!isAlive()) {
				return;
			}
			if (this.hasAttackActionInQueue()) {
				return;
			}
			if (param1) {
				_loc2_ = Math.abs(param1.getCell().mPosI - getCell().mPosI);
				if (_loc2_ > mAttackRange) {
					return;
				}
				_loc2_ = Math.abs(param1.getCell().mPosJ - getCell().mPosJ);
				if (_loc2_ > mAttackRange) {
					return;
				}
			}
			this.queueAction(new EnemyAttackingPlayerInstallationAction(this, param1));
		}

		private function hasAttackActionInQueue(): Boolean {
			var _loc1_: Action = null;
			if (this.mCurrentAction is EnemyAttackingAction) {
				return true;
			}
			var _loc2_: int = int(this.mActionQueue.mActions.length);
			var _loc3_: int = 0;
			while (_loc3_ < _loc2_) {
				_loc1_ = this.mActionQueue.mActions[_loc3_] as Action;
				if (_loc1_ is EnemyAttackingAction) {
					return true;
				}
				_loc3_++;
			}
			return false;
		}

		public function loadUnderCloudImage(): void {
			var _loc1_: String = null;
			var _loc2_: DCResourceManager = null;
			var _loc3_: Sprite = null;
			if (!this.mUnderCloudImage) {
				_loc1_ = Config.DIR_DATA + (mItem as EnemyUnitItem).mCloudShadow;
				_loc2_ = DCResourceManager.getInstance();
				if (_loc2_.isLoaded(_loc1_)) {
					_loc3_ = _loc2_.get(_loc1_);
					_loc3_.scaleX = 1;
					_loc3_.scaleY = 1;
					_loc3_.x = getContainer().x - _loc3_.width / 2;
					_loc3_.y = getContainer().y - _loc3_.height / 2;
					_loc3_.mouseEnabled = false;
					_loc3_.mouseChildren = false;
					this.mUnderCloudImage = _loc3_;
				} else if (!_loc2_.isAddedToLoadingList(_loc1_)) {
					_loc2_.load(_loc1_, _loc1_, "Sprite", false);
				}
			}
		}

		override public function updateTooltip(param1: int, param2: TooltipHealth): void {
			super.updateTooltip(param1, param2);
			if (GameState.mInstance.mVisitingFriend) {
				param2.setDetailsText(GameState.getText("MOUSEOVER_ENEMY_IDLE"));
			} else if (mState == STATE_SUPPRESS) {
				param2.setDetailsText(GameState.getText("UNIT_STATUS_SUPPRESS"));
			} else if ((this as EnemyUnit).getReactionState() == EnemyUnit.REACT_STATE_WAIT_FOR_TIMER) {
				param2.setDetailsText(GameState.getText("MOUSEOVER_ENEMY_TIMER", [TimeUtils.milliSecondsToString(this.mReactionStateCounter, 1)]));
			} else if ((this as EnemyUnit).getReactionState() == EnemyUnit.REACT_STATE_WAIT_FOR_ORDERS) {
				param2.setDetailsText(GameState.getText("MOUSEOVER_ENEMY_MOVING_ORDERS"));
			}
		}

		override public function MousePressed(param1: MouseEvent): void {
			var _loc2_: GameState = GameState.mInstance;
			if (_loc2_.mState == GameState.STATE_VISITING_NEIGHBOUR) {
				_loc2_.moveCameraToSeeRenderable(this);
				if (!mInQueueForAction) {
					if (mNeighborActionAvailable) {
						if (mState != STATE_SUPPRESS) {
							mInQueueForAction = true;
							_loc2_.queueAction(new VisitNeighborSuppressEnemyUnitAction(this));
						}
					}
				}
			}
		}

		override public function neighborClicked(param1: String): Action {
			var _loc2_: Action = null;
			if (!mInQueueForAction) {
				mInQueueForAction = true;
				_loc2_ = new AcceptHelpSuppressEnemyUnitAction(this, param1);
			}
			return _loc2_;
		}

		public function startSuppress(): void {
			mState = STATE_SUPPRESS;
			showLoadingBar();
			mInQueueForAction = false;
		}

		public function startAirDrop(): void {
			mState = STATE_AIR_DROP;
			setAnimationAction(AnimationController.CHARACTER_ANIMATION_AIRDROP);
			stopAnimation();
			this.mWaitingForAirplane = true;
		}

		public function skipSuppress(): void {
			if (Config.DEBUG_MODE) {}
			if (mState == STATE_SUPPRESS) {
				mState = STATE_WALKING;
			}
			mInQueueForAction = false;
			mActionDelayTimer = 0;
			hideLoadingBar();
		}

		public function isSuppressOver(): Boolean {
			return mState != STATE_SUPPRESS;
		}

		public function handleSuppress(): void {
			this.changeReactionState(REACT_STATE_WAIT_FOR_TIMER);
			var _loc1_: int = int(GameState.mConfig.AllyAction.SuppressEnemyUnit.Damage);
			this.reduceHealth(_loc1_);
		}

		override protected function updateHintHealth(): void {
			super.updateHintHealth();
		}

		public function showActivationIcon(param1: Boolean): void {
			var _loc2_: MovieClip = null;
			var _loc3_: int = 0;
			var _loc4_: MovieClip = null;
			var _loc5_: MovieClip = null;
			if (!mAnimationController) {
				return;
			}
			if (this.mActivationIconVisible == -1 || this.mActivationIconVisible == 1 != param1) {
				this.mActivationIconVisible = param1 ? 1 : 0;
				_loc2_ = mAnimationController.getCurrentAnimation();
				_loc3_ = 0;
				while (_loc3_ < _loc2_.numChildren) {
					if (_loc5_ = (_loc4_ = _loc2_.getChildAt(_loc3_) as MovieClip).getChildByName("Hint_Health_Friendly_Attention") as MovieClip) {
						if (param1 != _loc5_.visible) {
							_loc5_.visible = param1;
						}
					}
					_loc3_++;
				}
			}
		}

		public function getActivationTimeInMinutes(): int {
			return this.mActivationTimeInMinutes;
		}
	}
}