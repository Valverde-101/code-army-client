param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v47=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV47.ps1'
$hudPath=Join-Path $RepoRoot 'src\game\gui\GameHUD.as'
$gameStatePath=Join-Path $RepoRoot 'src\game\states\GameState.as'
$enemyPath=Join-Path $RepoRoot 'src\game\characters\EnemyUnit.as'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v48\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v47 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL predecessor_missing=$v47"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-One([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $p=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($p -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL patch=$Name missing"}
  if($Text.IndexOf($Needle,$p+$Needle.Length,[StringComparison]::Ordinal) -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL patch=$Name ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V48_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$p)+$Replacement+$Text.Substring($p+$Needle.Length)
}
function Require([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL verify=$Name token=$Token"}}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $m=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$m.source_sha -ne $ExpectedSha){throw 'ANDROID_EVIDENCE_ROOTFIX_V48=FAIL restore_sha'}
  foreach($e in @($m.files)){
    $target=Join-Path $RepoRoot ([string]$e.path)
    $backup=Join-Path $backupRoot ([string]$e.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL restore_missing=$($e.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$e.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL restore_hash=$($e.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v47 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V48=PASS mode=restore predecessor=v47 sha=$ExpectedSha"
  return
}

& $v47 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  foreach($p in @($hudPath,$gameStatePath,$enemyPath,$patcherPath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL required_file=$p"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $owned=@(
    @('src\game\gui\GameHUD.as',$hudPath,'GameHUD.post-v47.as'),
    @('src\game\states\GameState.as',$gameStatePath,'GameState.post-v47.as'),
    @('src\game\characters\EnemyUnit.as',$enemyPath,'EnemyUnit.post-v47.as'),
    @('Tools\CI\Patch-AndroidPerformanceSwf.ps1',$patcherPath,'Patch-AndroidPerformanceSwf.post-v47.ps1')
  )
  $files=@()
  foreach($x in $owned){
    Copy-Item -LiteralPath $x[1] -Destination (Join-Path $backupRoot $x[2]) -Force
    $files+=@([ordered]@{path=$x[0];backup=$x[2];sha256=(Get-Sha256 $x[1])})
  }
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v48';source_sha=$ExpectedSha;predecessor='v47';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # The Android sharesheet temporarily leaves AIR and then resumes it. On some
  # devices the resumed pointer stream can deliver another click to Button_save.
  # Gate manual exports as an explicit external-flow transaction: one accepted
  # press, no re-entry while the chooser owns focus, and a short resume guard.
  $hud=Normalize-Lf ([IO.File]::ReadAllText($hudPath))
  if(-not $hud.Contains('import flash.utils.getTimer;')){
    $hud=Replace-One $hud 'import flash.utils.getDefinitionByName;' "import flash.utils.getDefinitionByName;`n`timport flash.utils.getTimer;" 'save_guard_gettimer_import'
  }
  $hud=Replace-One $hud 'private var timer: Timer;' @'
private var timer: Timer;
			private static const PORTABLE_SAVE_DEBOUNCE_MS:int = 1200;
			private static const PORTABLE_SAVE_RESUME_GUARD_MS:int = 1800;
			private static const PORTABLE_SAVE_EXTERNAL_TIMEOUT_MS:int = 120000;
			private var mPortableSaveExternalFlow:Boolean = false;
			private var mPortableSaveExternalDeadline:int = 0;
			private var mPortableSaveResumeGuardUntil:int = 0;
			private var mPortableSaveLastAcceptedAt:int = -1000000;
'@.TrimEnd() 'save_guard_fields'

  $guardMethods=@'
			private function finishPortableSaveExternalFlow(reason:String):void {
				this.mPortableSaveExternalFlow = false;
				this.mPortableSaveExternalDeadline = 0;
				this.mPortableSaveResumeGuardUntil = getTimer() + PORTABLE_SAVE_RESUME_GUARD_MS;
				Utils.DiagEvent("SAVE_EXPORT_RESUME_GUARD", "reason=" + reason + ";guard_ms=" + PORTABLE_SAVE_RESUME_GUARD_MS);
			}

			private function onPortableSaveDeactivate(evt:Event):void {
				if (this.mPortableSaveExternalFlow) {
					Utils.DiagEvent("SAVE_EXPORT_DEACTIVATE", "external_flow=true");
				}
			}

			private function onPortableSaveActivate(evt:Event):void {
				if (!this.mPortableSaveExternalFlow) return;
				if (stage) {
					stage.removeEventListener(Event.DEACTIVATE, this.onPortableSaveDeactivate);
					stage.removeEventListener(Event.ACTIVATE, this.onPortableSaveActivate);
				}
				this.finishPortableSaveExternalFlow("activity_resume");
			}

			private function requestPortableSaveShare(evt:MouseEvent):void {
				var now:int = getTimer();
				if (this.mPortableSaveExternalFlow && now >= this.mPortableSaveExternalDeadline) {
					if (stage) {
						stage.removeEventListener(Event.DEACTIVATE, this.onPortableSaveDeactivate);
						stage.removeEventListener(Event.ACTIVATE, this.onPortableSaveActivate);
					}
					this.mPortableSaveExternalFlow = false;
					this.mPortableSaveExternalDeadline = 0;
					Utils.DiagEvent("SAVE_EXPORT_FLOW_RECOVERED", "reason=timeout");
				}
				if (this.mPortableSaveExternalFlow) {
					Utils.DiagEvent("SAVE_EXPORT_SUPPRESSED", "reason=external_flow_active");
					return;
				}
				if (now < this.mPortableSaveResumeGuardUntil) {
					Utils.DiagEvent("SAVE_EXPORT_SUPPRESSED", "reason=resume_guard;remaining_ms=" + (this.mPortableSaveResumeGuardUntil - now));
					return;
				}
				if (now - this.mPortableSaveLastAcceptedAt < PORTABLE_SAVE_DEBOUNCE_MS) {
					Utils.DiagEvent("SAVE_EXPORT_SUPPRESSED", "reason=debounce;elapsed_ms=" + (now - this.mPortableSaveLastAcceptedAt));
					return;
				}
				this.mPortableSaveLastAcceptedAt = now;
				this.mPortableSaveExternalFlow = true;
				this.mPortableSaveExternalDeadline = now + PORTABLE_SAVE_EXTERNAL_TIMEOUT_MS;
				if (stage) {
					stage.addEventListener(Event.DEACTIVATE, this.onPortableSaveDeactivate, false, 0, true);
					stage.addEventListener(Event.ACTIVATE, this.onPortableSaveActivate, false, 0, true);
				}
				Utils.DiagEvent("SAVE_EXPORT_ACCEPTED", "source=manual_button;timeout_ms=" + PORTABLE_SAVE_EXTERNAL_TIMEOUT_MS);
				this.savePortableAndShare();
			}

			private function savePortableAndShare():void {
'@
  $hud=Replace-One $hud 'private function savePortableAndShare():void {' $guardMethods.TrimEnd() 'save_guard_methods'
  $shareLine='var shareResult:String = String(shareFn(payload, "ArmyAttack-save"));'
  $shareReplacement=@'
var shareResult:String = String(shareFn(payload, "ArmyAttack-save"));
					if (shareResult.indexOf("QUEUED:") != 0) {
						if (stage) {
							stage.removeEventListener(Event.DEACTIVATE, this.onPortableSaveDeactivate);
							stage.removeEventListener(Event.ACTIVATE, this.onPortableSaveActivate);
						}
						this.finishPortableSaveExternalFlow("native_not_queued");
					}
'@
  $hud=Replace-One $hud $shareLine $shareReplacement.TrimEnd() 'save_guard_native_failure_release'
  $hud=Replace-One $hud 'this.savePortableAndShare();' 'this.requestPortableSaveShare(param1);' 'manual_save_routes_through_guard'
  foreach($token in @('PORTABLE_SAVE_DEBOUNCE_MS:int = 1200','PORTABLE_SAVE_RESUME_GUARD_MS:int = 1800','PORTABLE_SAVE_EXTERNAL_TIMEOUT_MS:int = 120000','SAVE_EXPORT_SUPPRESSED','SAVE_EXPORT_ACCEPTED','SAVE_EXPORT_RESUME_GUARD','this.requestPortableSaveShare(param1);')){Require $hud $token $token}
  Write-Utf8Bom $hudPath $hud

  # Use a bounded spatial working set instead of a hard 10/12 tile radius. A
  # fixed radius leaves almost every enemy active on dense Home/Snow layouts.
  # The nearest 24 enemies to friendly territory are active, with visible or
  # already-engaged enemies always admitted. The effective radius therefore
  # expands automatically on sparse maps or after nearby enemies are destroyed.
  $game=Normalize-Lf ([IO.File]::ReadAllText($gameStatePath))
  if(-not $game.Contains('import flash.utils.Dictionary;')){
    $game=Replace-One $game 'import flash.utils.Timer;' "import flash.utils.Timer;`n`timport flash.utils.Dictionary;" 'spatial_ai_dictionary_import'
  }
  $spatialFields=@'
private var mTrackedMainEnemyActionStartedAt:int = 0;
		private static const OFFLINE_ENEMY_SPATIAL_TARGET:int = 24;
		private static const OFFLINE_ENEMY_SPATIAL_REFRESH_MS:int = 1500;
		private static const OFFLINE_ENEMY_IMMEDIATE_RADIUS:int = 3;
		private var mOfflineEnemySpatialActive:Dictionary = new Dictionary(true);
		private var mOfflineEnemySpatialScene:IsometricScene;
		private var mOfflineEnemySpatialElapsed:int = OFFLINE_ENEMY_SPATIAL_REFRESH_MS;
		private var mOfflineEnemySpatialActiveCount:int = -1;
		private var mOfflineEnemySpatialSleepingCount:int = -1;
		private var mOfflineEnemySpatialEffectiveRadius:int = -1;
'@
  $game=Replace-One $game 'private var mTrackedMainEnemyActionStartedAt:int = 0;' $spatialFields.TrimEnd() 'spatial_ai_fields'

  $ensureAnchor='\t\tprivate function ensureOfflineEnemyAiTuned(param1:int):void {'.Replace('\t',"`t")
  $spatialMethods=@'
		private function enemyDistanceToFriendlyTerritory(param1:EnemyUnit,param2:Array):int {
			if (!param1 || !param1.getCell() || !param2 || param2.length == 0) return 0;
			var origin:GridCell = param1.getCell();
			var best:int = int.MAX_VALUE;
			var i:int = 0;
			var cell:GridCell = null;
			var d:int = 0;
			while (i < param2.length) {
				cell = param2[i] as GridCell;
				if (cell) {
					d = Math.abs(origin.mPosI - cell.mPosI) + Math.abs(origin.mPosJ - cell.mPosJ);
					if (d < best) best = d;
					if (best == 0) break;
				}
				i++;
			}
			return best == int.MAX_VALUE ? 0 : best;
		}

		private function refreshOfflineEnemySpatialSet(param1:int):void {
			if (!Config.OFFLINE_MODE || this.mState != STATE_PLAY || !this.mScene) return;
			var sceneChanged:Boolean = this.mOfflineEnemySpatialScene != this.mScene;
			this.mOfflineEnemySpatialElapsed += param1;
			if (!sceneChanged && this.mOfflineEnemySpatialElapsed < OFFLINE_ENEMY_SPATIAL_REFRESH_MS) return;
			this.mOfflineEnemySpatialElapsed = 0;
			this.mOfflineEnemySpatialScene = this.mScene;
			var friendly:Array = [];
			var x:int = 0;
			var y:int = 0;
			var cell:GridCell = null;
			while (x < this.mScene.mSizeX) {
				y = 0;
				while (y < this.mScene.mSizeY) {
					cell = this.mScene.getCellAt(x,y);
					if (cell && cell.mOwner == MapData.TILE_OWNER_FRIENDLY) friendly.push(cell);
					y++;
				}
				x++;
			}
			var enemies:Array = this.mScene.getEnemyUnits();
			var candidates:Array = [];
			var active:Dictionary = new Dictionary(true);
			var always:Array = [];
			var i:int = 0;
			var enemy:EnemyUnit = null;
			var distance:int = 0;
			var state:int = 0;
			var visible:Boolean = false;
			while (enemies && i < enemies.length) {
				enemy = enemies[i] as EnemyUnit;
				if (enemy && enemy.isAlive()) {
					distance = this.enemyDistanceToFriendlyTerritory(enemy,friendly);
					state = enemy.getReactionState();
					visible = this.mScene.isRenderableActuallyInViewport(enemy);
					candidates.push({enemy:enemy,distance:distance,index:i});
					if (visible || enemy.hasPriorityAttackTargetInRange() || distance <= OFFLINE_ENEMY_IMMEDIATE_RADIUS || state == EnemyUnit.REACT_STATE_ACTION || state == EnemyUnit.REACT_STATE_ACTION_COMPLETED) {
						active[enemy] = true;
						always.push(enemy);
					}
				}
				i++;
			}
			candidates.sort(function(a:Object,b:Object):Number {
				if (int(a.distance) < int(b.distance)) return -1;
				if (int(a.distance) > int(b.distance)) return 1;
				return int(a.index) - int(b.index);
			});
			var activeCount:int = always.length;
			var effectiveRadius:int = 0;
			i = 0;
			var candidate:Object = null;
			while (i < candidates.length) {
				candidate = candidates[i];
				enemy = candidate.enemy as EnemyUnit;
				if (active[enemy] === true) {
					effectiveRadius = Math.max(effectiveRadius,int(candidate.distance));
				} else if (activeCount < OFFLINE_ENEMY_SPATIAL_TARGET) {
					active[enemy] = true;
					activeCount++;
					effectiveRadius = Math.max(effectiveRadius,int(candidate.distance));
				}
				i++;
			}
			this.mOfflineEnemySpatialActive = active;
			var sleeping:int = Math.max(0,candidates.length - activeCount);
			if (sceneChanged || activeCount != this.mOfflineEnemySpatialActiveCount || sleeping != this.mOfflineEnemySpatialSleepingCount || effectiveRadius != this.mOfflineEnemySpatialEffectiveRadius) {
				Utils.DiagEvent("ENEMY_AI_SPATIAL_SET","map=" + this.mCurrentMapId + ";alive=" + candidates.length + ";active=" + activeCount + ";sleeping=" + sleeping + ";target=" + OFFLINE_ENEMY_SPATIAL_TARGET + ";effective_radius=" + effectiveRadius + ";friendly_tiles=" + friendly.length + ";refresh_ms=" + OFFLINE_ENEMY_SPATIAL_REFRESH_MS);
			}
			this.mOfflineEnemySpatialActiveCount = activeCount;
			this.mOfflineEnemySpatialSleepingCount = sleeping;
			this.mOfflineEnemySpatialEffectiveRadius = effectiveRadius;
		}

		public function isOfflineEnemySpatiallyActive(param1:EnemyUnit):Boolean {
			if (!param1 || !Config.OFFLINE_MODE || this.mState != STATE_PLAY || !this.mScene) return true;
			if (this.mOfflineEnemySpatialScene != this.mScene || !this.mOfflineEnemySpatialActive) return true;
			return this.mOfflineEnemySpatialActive[param1] === true;
		}

'@
  $game=Replace-One $game $ensureAnchor ((Normalize-Lf $spatialMethods)+$ensureAnchor) 'spatial_ai_methods'
  $game=Replace-One $game @'
			if (!Config.OFFLINE_MODE || this.mState != STATE_PLAY || !this.mScene) {
				return;
			}
			var sceneChanged:Boolean = this.mOfflineEnemyAiTunedScene != this.mScene;
'@.TrimEnd() @'
			if (!Config.OFFLINE_MODE || this.mState != STATE_PLAY || !this.mScene) {
				return;
			}
			this.refreshOfflineEnemySpatialSet(param1);
			var sceneChanged:Boolean = this.mOfflineEnemyAiTunedScene != this.mScene;
'@.TrimEnd() 'spatial_ai_refresh_from_tuner'
  $game=Replace-One $game 'if (enemy && enemy.isAlive()) {' 'if (enemy && enemy.isAlive() && this.isOfflineEnemySpatiallyActive(enemy)) {' 'ai_tuning_active_set_only'
  foreach($token in @('OFFLINE_ENEMY_SPATIAL_TARGET:int = 24','OFFLINE_ENEMY_SPATIAL_REFRESH_MS:int = 1500','OFFLINE_ENEMY_IMMEDIATE_RADIUS:int = 3','ENEMY_AI_SPATIAL_SET','enemyDistanceToFriendlyTerritory','isOfflineEnemySpatiallyActive','this.refreshOfflineEnemySpatialSet(param1);','this.mScene.isRenderableActuallyInViewport(enemy)','enemy.hasPriorityAttackTargetInRange()')){Require $game $token $token}
  Write-Utf8Bom $gameStatePath $game

  # Sleeping enemies do not advance AI timers or pathfinding. They still receive a
  # low-frequency base visual update so culling/animation state remains coherent.
  # Engaged ACTION/ACTION_COMPLETED enemies are never slept by the spatial set.
  $enemyText=Normalize-Lf ([IO.File]::ReadAllText($enemyPath))
  $enemyText=Replace-One $enemyText 'private var mWaitingForAirplane: Boolean = false;' @'
private var mWaitingForAirplane: Boolean = false;

		private static const OFFLINE_SLEEP_VISUAL_INTERVAL_MS:int = 250;
		private var mOfflineSleepVisualElapsed:int = 0;
'@.TrimEnd() 'enemy_sleep_fields'
  $enemyUpdateOld=@'
		override public function update(param1: int): void {
			super.update(param1);
'@.TrimEnd()
  $enemyUpdateNew=@'
		override public function update(param1: int): void {
			if (Config.OFFLINE_MODE && GameState.mInstance && GameState.mInstance.mState == GameState.STATE_PLAY && mState != STATE_AIR_DROP && mState != STATE_SUPPRESS && !GameState.mInstance.isOfflineEnemySpatiallyActive(this)) {
				this.mOfflineSleepVisualElapsed += param1;
				if (this.mOfflineSleepVisualElapsed >= OFFLINE_SLEEP_VISUAL_INTERVAL_MS) {
					super.update(this.mOfflineSleepVisualElapsed);
					this.mOfflineSleepVisualElapsed = 0;
				}
				return;
			}
			this.mOfflineSleepVisualElapsed = 0;
			super.update(param1);
'@.TrimEnd()
  $enemyText=Replace-One $enemyText $enemyUpdateOld $enemyUpdateNew 'enemy_sleep_update_throttle'
  foreach($token in @('OFFLINE_SLEEP_VISUAL_INTERVAL_MS:int = 250','mOfflineSleepVisualElapsed','isOfflineEnemySpatiallyActive(this)','super.update(this.mOfflineSleepVisualElapsed)')){Require $enemyText $token $token}
  Write-Utf8Bom $enemyPath $enemyText

  # EnemyUnit must be injected into the final SWF; GameHUD and GameState already
  # are. Insert by semantic patch-spec row so this composes with earlier overlays.
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  if($patcher -notmatch "Class='game\.characters\.EnemyUnit'") {
    $pattern="(?m)^(?<row>\s*\[ordered\]@\{Class='game\.isometric\.characters\.IsometricCharacter';Source='[^']*IsometricCharacter\.as';Log='ffdec-feature-character-hints\.log'\},\s*)$"
    $matches=[regex]::Matches($patcher,$pattern)
    if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL patch=enemy_unit_swf_patch_spec semantic_anchor_count=$($matches.Count)"}
    $row=$matches[0].Groups['row'].Value.TrimEnd()
    $indent=[regex]::Match($row,'^\s*').Value
    $enemySpec=$indent+"[ordered]@{Class='game.characters.EnemyUnit';Source='src\game\characters\EnemyUnit.as';Log='ffdec-feature-enemy-spatial-throttle.log'},"
    $insertAt=$matches[0].Index+$matches[0].Length
    $patcher=$patcher.Substring(0,$insertAt)+"`n"+$enemySpec+$patcher.Substring($insertAt)
    Write-Host 'EVIDENCE_ROOTFIX_V48_HOOK=PASS name=enemy_unit_swf_patch_spec matches=1 semantic=true'
  }
  Require $patcher "Class='game.characters.EnemyUnit'" 'enemy_unit_final_swf_patch_spec'
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=portable_save_external_reentry_guard external_flow_singleflight=true debounce_ms=1200 resume_guard_ms=1800 timeout_recovery_ms=120000 autosave_untouched=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_spatial_working_set policy=nearest_friendly_territory target=24 refresh_ms=1500 immediate_radius=3 visible_always_active=true engaged_always_active=true adaptive_radius=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_sleep_behavior ai_timers_paused=true pathfinding_paused=true visual_update_ms=250 airdrop_unslept=true suppress_unslept=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_spatial_cost expected_full_character_updates_bounded=true fixed_radius_10_12_rejected=true dense_maps_safe=true sparse_maps_expand=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_unit_final_swf_contract class=game.characters.EnemyUnit patch_spec=true telemetry=ENEMY_AI_SPATIAL_SET,SAVE_EXPORT_SUPPRESSED,SAVE_EXPORT_RESUME_GUARD'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V48=PASS mode=apply predecessor=v47 sha=$ExpectedSha feature=save_reentry_guard+adaptive_spatial_enemy_sleep"
}
catch {
  Restore-OwnedFiles
  try { & $v47 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore } catch {}
  throw
}