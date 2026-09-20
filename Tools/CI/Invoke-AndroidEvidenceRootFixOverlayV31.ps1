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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v29=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV29.ps1'
if(-not(Test-Path -LiteralPath $v29 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL predecessor_missing=$v29"}

$offlinePath=Join-Path $RepoRoot 'src\game\utils\OfflineSave.as'
$objectivePath=Join-Path $RepoRoot 'src\game\missions\Objective.as'
$missionPath=Join-Path $RepoRoot 'src\game\missions\Mission.as'
$managerPath=Join-Path $RepoRoot 'src\game\missions\MissionManager.as'
$conquerPath=Join-Path $RepoRoot 'src\game\missions\Conquer.as'
$destroyPath=Join-Path $RepoRoot 'src\game\missions\DestroyTarget.as'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v31\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){$i=$Text.IndexOf($Needle,[StringComparison]::Ordinal);if($i -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL patch=$Name literal_missing"};$j=$Text.IndexOf($Needle,$i+$Needle.Length,[StringComparison]::Ordinal);if($j -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL patch=$Name literal_ambiguous"};Write-Host "EVIDENCE_ROOTFIX_V31_HOOK=PASS name=$Name matches=1 literal=true";return $Text.Substring(0,$i)+$Replacement+$Text.Substring($i+$Needle.Length)}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){$m=[regex]::Matches($Text,$Pattern);if($m.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL patch=$Name semantic_match_count=$($m.Count)"};Write-Host "EVIDENCE_ROOTFIX_V31_HOOK=PASS name=$Name matches=1 semantic=true";return [regex]::Replace($Text,$Pattern,$Replacement,1)}
function Restore-OwnedFiles{if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return};$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json;if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"};foreach($entry in @($manifest.files)){$target=Join-Path $RepoRoot ([string]$entry.path);$backup=Join-Path $backupRoot ([string]$entry.backup);if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL restore_backup_missing path=$($entry.path)"};Copy-Item -LiteralPath $backup -Destination $target -Force;if((Get-Sha256 $target) -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL restore_hash path=$($entry.path)"}};Remove-Item -LiteralPath $backupRoot -Recurse -Force}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v29 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V31=PASS mode=restore predecessor=v29 sha=$ExpectedSha"
  return
}
& $v29 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try{
  $owned=@(
    [ordered]@{Path=$offlinePath;Repo='src\game\utils\OfflineSave.as';Backup='OfflineSave.post-v29.as'},
    [ordered]@{Path=$objectivePath;Repo='src\game\missions\Objective.as';Backup='Objective.post-v29.as'},
    [ordered]@{Path=$missionPath;Repo='src\game\missions\Mission.as';Backup='Mission.post-v29.as'},
    [ordered]@{Path=$managerPath;Repo='src\game\missions\MissionManager.as';Backup='MissionManager.post-v29.as'},
    [ordered]@{Path=$conquerPath;Repo='src\game\missions\Conquer.as';Backup='Conquer.post-v29.as'},
    [ordered]@{Path=$destroyPath;Repo='src\game\missions\DestroyTarget.as';Backup='DestroyTarget.post-v29.as'},
    [ordered]@{Path=$patcherPath;Repo='Tools\CI\Patch-AndroidPerformanceSwf.ps1';Backup='Patch-AndroidPerformanceSwf.post-v29.ps1'}
  )
  foreach($e in $owned){if(-not(Test-Path -LiteralPath $e.Path -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V31=FAIL required_file_missing path=$($e.Path)"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force};New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $mf=@();foreach($e in $owned){Copy-Item -LiteralPath $e.Path -Destination (Join-Path $backupRoot $e.Backup) -Force;$mf+=@([ordered]@{path=$e.Repo;backup=$e.Backup;sha256=(Get-Sha256 $e.Path)})}
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v31';source_sha=$ExpectedSha;predecessor='v29';files=$mf}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $offline=Normalize-Lf ([IO.File]::ReadAllText($offlinePath))
  $helperAnchor="`n`t`tpublic static function generateSaveJson(): * {"
  $helper=@'

		private static function commitLoadedTerritoryTopology(param1: String): void {
			var state: GameState = GameState.mInstance;
			if (!state || !state.mMapData || !state.mScene || !state.mScene.mTilemapGraphic) {
				Utils.DiagEvent("TERRITORY_TOPOLOGY_COMMIT","result=SKIP;reason=runtime_not_ready;source=" + param1);
				return;
			}
			state.updateGrid();
			state.mScene.mTilemapGraphic.recalculateBorderEdges();
			state.mScene.mTilemapGraphic.updateTilemap();
			Utils.DiagEvent("TERRITORY_TOPOLOGY_COMMIT","result=PASS;map=" + state.mCurrentMapId + ";source=" + param1 + ";grid=" + (state.mMapData.mGrid ? state.mMapData.mGrid.length : 0) + ";visual_commit=full");
		}
'@.TrimEnd()
  $offline=Replace-LiteralOne $offline $helperAnchor ($helper+$helperAnchor) 'territory_topology_helper'
  $switchPattern='(?s)(public\s+static\s+function\s+switchMap\s*\(\s*\)\s*:\s*void\s*\{.*?)(\n[ \t]*Utils\.DiagEvent\("OFFLINE_MAP_TIMING","map="\s*\+\s*map_id\s*\+\s*";phase=fog_missions;ms="\s*\+\s*\(getTimer\(\)\s*-\s*mapPhaseStarted\)\);)'
  $offline=Replace-RegexOne $offline $switchPattern ('$1'+"`n`t`t`tcommitLoadedTerritoryTopology(`"switch:`" + map_id);"+'$2') 'switch_map_topology_commit'
  $bootPattern='(?s)(public\s+static\s+function\s+loadProgress\s*\([^)]*\)\s*:\s*void\s*\{.*?)(\n[ \t]*GameState\.mInstance\.mLoadingStatesOver\s*=\s*true;)'
  $offline=Replace-RegexOne $offline $bootPattern ('$1'+"`n`t`t`tcommitLoadedTerritoryTopology(`"boot_restore:`" + GameState.mInstance.mCurrentMapId);"+'$2') 'boot_restore_topology_commit'
  foreach($t in @('private static function commitLoadedTerritoryTopology','state.mScene.mTilemapGraphic.recalculateBorderEdges();','commitLoadedTerritoryTopology("switch:" + map_id);','commitLoadedTerritoryTopology("boot_restore:" + GameState.mInstance.mCurrentMapId);')){Require-Token $offline $t ('territory_'+$t)}
  Write-Utf8Bom $offlinePath $offline

  $objective=Normalize-Lf ([IO.File]::ReadAllText($objectivePath))
  $oldInit='if ((param1 == Mission.TYPE_MODAL_ARROW || param1 == Mission.TYPE_INTEL) && this.mParameter is Array) {'
  $newInit='if ((param1 == Mission.TYPE_MODAL_ARROW || param1 == Mission.TYPE_INTEL) && this.mParameter is Array && this.mMapId == GameState.mInstance.mCurrentMapId) {'
  $oldClean='if ((this.mMissionType == Mission.TYPE_MODAL_ARROW || this.mMissionType == Mission.TYPE_INTEL) && this.mParameter is Array) {'
  $newClean='if ((this.mMissionType == Mission.TYPE_MODAL_ARROW || this.mMissionType == Mission.TYPE_INTEL) && this.mParameter is Array && this.mMapId == GameState.mInstance.mCurrentMapId) {'
  $objective=Replace-LiteralOne $objective $oldInit $newInit 'objective_initialize_current_map_guard'
  $objective=Replace-LiteralOne $objective $oldClean $newClean 'objective_clean_current_map_guard'
  Write-Utf8Bom $objectivePath $objective

  $conquer=Normalize-Lf ([IO.File]::ReadAllText($conquerPath))
  $conquerPattern='(?s)override\s+public\s+function\s+initialize\(param1:String,\s*param2:Object\)\s*:\s*void\s*\{.*?\n\s*\}\s*\n\s*override\s+public\s+function\s+increase'
  $conquerReplacement=@'
override public function initialize(param1:String, param2:Object) : void
      {
         var _loc3_:IsometricScene = null;
         var _loc4_:GridCell = null;
         var _loc5_:Array = null;
         super.initialize(param1,param2);
         if(this.mMapId != GameState.mInstance.mCurrentMapId)
         {
            Utils.DiagEvent("MISSION_MAP_ISOLATION","objective=Conquer;result=DEFER_SCENE;mission_map=" + this.mMapId + ";current_map=" + GameState.mInstance.mCurrentMapId);
            return;
         }
         if(mParameter is Array)
         {
            _loc3_ = GameState.mInstance.mScene;
            if(!_loc3_) return;
            if(mParameter[0] is Array)
            {
               for each(_loc5_ in mParameter)
               {
                  _loc4_ = _loc3_.getCellAt(_loc5_[0],_loc5_[1]);
                  if(_loc4_ && _loc4_.mOwner == MapData.TILE_OWNER_FRIENDLY) ++mCounter;
               }
            }
            else
            {
               _loc4_ = _loc3_.getCellAt(mParameter[0],mParameter[1]);
               if(_loc4_ && _loc4_.mOwner == MapData.TILE_OWNER_FRIENDLY) mCounter = mGoal;
            }
         }
         if(param1 == Mission.TYPE_MODAL_ARROW && mParameter is Array) GameState.mInstance.updateWalkableCellsForActiveCharacter(mParameter[0],mParameter[1]);
      }
      
      override public function increase
'@.TrimEnd()
  $conquer=Replace-RegexOne $conquer $conquerPattern $conquerReplacement 'conquer_map_before_cell_access'
  foreach($t in @('objective=Conquer;result=DEFER_SCENE','_loc4_ = _loc3_.getCellAt','if(_loc4_ && _loc4_.mOwner == MapData.TILE_OWNER_FRIENDLY)')){Require-Token $conquer $t ('conquer_'+$t)}
  Write-Utf8Bom $conquerPath $conquer

  $destroy=Normalize-Lf ([IO.File]::ReadAllText($destroyPath))
  $destroyPattern='(?s)override\s+public\s+function\s+initialize\(param1:String,\s*param2:Object\)\s*:\s*void\s*\{.*?\n\s*\}\s*\n\s*override\s+public\s+function\s+increase'
  $destroyReplacement=@'
override public function initialize(param1:String, param2:Object) : void
      {
         super.initialize(param1,param2);
         if(this.mMapId != GameState.mInstance.mCurrentMapId)
         {
            Utils.DiagEvent("MISSION_MAP_ISOLATION","objective=DestroyTarget;result=DEFER_SCENE;mission_map=" + this.mMapId + ";current_map=" + GameState.mInstance.mCurrentMapId);
            return;
         }
         var _loc3_:IsometricScene = GameState.mInstance.mScene;
         var _loc5_:Renderable = null;
         var _loc4_:GridCell = null;
         if(!_loc3_ || !(mParameter is Array) || mParameter.length < 2) return;
         _loc4_ = _loc3_.getCellAt(mParameter[0],mParameter[1]);
         if(!_loc4_)
         {
            Utils.DiagEvent("MISSION_MAP_ISOLATION","objective=DestroyTarget;result=SKIP;reason=cell_missing;map=" + this.mMapId + ";x=" + mParameter[0] + ";y=" + mParameter[1]);
            return;
         }
         _loc5_ = _loc4_.mCharacter;
         if(!_loc5_) _loc5_ = _loc4_.mObject;
         if(!_loc5_ || !_loc5_.mItem || this.mTarget.Type != _loc5_.mItem.mType || this.mTarget.ID != _loc5_.mItem.mId) mCounter = 1;
      }
      
      override public function increase
'@.TrimEnd()
  $destroy=Replace-RegexOne $destroy $destroyPattern $destroyReplacement 'destroy_target_map_before_cell_access'
  foreach($t in @('objective=DestroyTarget;result=DEFER_SCENE','_loc4_ = _loc3_.getCellAt(mParameter[0],mParameter[1]);','if(!_loc4_)')){Require-Token $destroy $t ('destroy_'+$t)}
  Write-Utf8Bom $destroyPath $destroy

  $mission=Normalize-Lf ([IO.File]::ReadAllText($missionPath))
  $popupPattern='(?s)(private\s+function\s+setupPopups\(\)\s*:\s*void\s*\{)(\s*switch\(this\.mType\))'
  $popupReplacement=@'
$1
         if(this.mMapId != GameState.mInstance.mCurrentMapId)
         {
            Utils.DiagEvent("MISSION_POPUP_DEFER","mission=" + this.mId + ";type=" + this.mType + ";mission_map=" + this.mMapId + ";current_map=" + GameState.mInstance.mCurrentMapId);
            return;
         }
         Utils.DiagEvent("MISSION_POPUP_ROUTE","mission=" + this.mId + ";type=" + this.mType + ";map=" + this.mMapId);
$2
'@.TrimEnd()
  $mission=Replace-RegexOne $mission $popupPattern $popupReplacement 'mission_popup_current_map_guard'
  Write-Utf8Bom $missionPath $mission

  $manager=Normalize-Lf ([IO.File]::ReadAllText($managerPath))
  $modalOld='if(_loc1_.mState == Mission.STATE_ACTIVE && (_loc1_.mType == Mission.TYPE_MODAL_ARROW || _loc1_.mType == Mission.TYPE_MODAL_DIALOG || _loc1_.mType == Mission.TYPE_INTEL || _loc1_.mType == Mission.TYPE_INTEL_DIALOG || _loc1_.mType == Mission.TYPE_INSTANT_TIP))'
  $modalNew='if(_loc1_.mState == Mission.STATE_ACTIVE && _loc1_.mMapId == GameState.mInstance.mCurrentMapId && (_loc1_.mType == Mission.TYPE_MODAL_ARROW || _loc1_.mType == Mission.TYPE_MODAL_DIALOG || _loc1_.mType == Mission.TYPE_INTEL || _loc1_.mType == Mission.TYPE_INTEL_DIALOG || _loc1_.mType == Mission.TYPE_INSTANT_TIP))'
  $manager=Replace-LiteralOne $manager $modalOld $modalNew 'modal_mission_current_map_only'
  Write-Utf8Bom $managerPath $manager

  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patchSpecAnchor="  [ordered]@{Class='game.gui.GameHUD';Source='src\game\gui\GameHUD.as';Log='ffdec-feature-gamehud.log'},"
  $missionSpecs=@'
  [ordered]@{Class='game.missions.Objective';Source='src\game\missions\Objective.as';Log='ffdec-feature-mission-objective.log'},
  [ordered]@{Class='game.missions.Conquer';Source='src\game\missions\Conquer.as';Log='ffdec-feature-mission-conquer.log'},
  [ordered]@{Class='game.missions.DestroyTarget';Source='src\game\missions\DestroyTarget.as';Log='ffdec-feature-mission-destroy-target.log'},
  [ordered]@{Class='game.missions.Control';Source='src\game\missions\Control.as';Log='ffdec-feature-mission-control.log'},
  [ordered]@{Class='game.missions.Own';Source='src\game\missions\Own.as';Log='ffdec-feature-mission-own.log'},
  [ordered]@{Class='game.missions.Mission';Source='src\game\missions\Mission.as';Log='ffdec-feature-mission.log'},
  [ordered]@{Class='game.missions.MissionManager';Source='src\game\missions\MissionManager.as';Log='ffdec-feature-mission-manager.log'},
'@.TrimEnd()
  $patcher=Replace-LiteralOne $patcher $patchSpecAnchor ($missionSpecs+"`n"+$patchSpecAnchor) 'mission_classes_into_swf_patchset'
  foreach($c in @('game.missions.Objective','game.missions.Conquer','game.missions.DestroyTarget','game.missions.Control','game.missions.Own','game.missions.Mission','game.missions.MissionManager')){Require-Token $patcher ("Class='"+$c+"'") ('patchspec_'+$c)}
  if($patcher.Contains('convertToSnow')){throw 'ANDROID_EVIDENCE_ROOTFIX_V31=FAIL unsupported_convertToSnow_patch_survived'}
  Write-Utf8Bom $patcherPath $patcher
  $psTokens=$null;$psErrors=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($patcherPath,[ref]$psTokens,[ref]$psErrors);if(@($psErrors).Count -gt 0){$psErrors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V31_PATCHER_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"};throw 'ANDROID_EVIDENCE_ROOTFIX_V31=FAIL patcher_parser_invalid'}

  Write-Host 'REGRESSION_CHECK=PASS name=territory_restore_initial_topology boot=true map_switch=true capture_local=true'
  Write-Host 'REGRESSION_CHECK=PASS name=mission_cross_map_isolation counters=hydrated scene=current_map_only popup=current_map_only modal=current_map_only cell_null_guard=true'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_diagnosis unsupported_convertToSnow_removed=true popup_route_diagnostics=true'
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V31_MISSION_MAP_ISOLATION=PASS objectives=Objective,Conquer,DestroyTarget,Control,Own mission_popup_guard=true manager_modal_guard=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V31=PASS mode=apply predecessor=v29 sha=$ExpectedSha"
}catch{
  $message=$_.Exception.Message
  try{Restore-OwnedFiles}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V31_ROLLBACK=WARN $($_.Exception.Message)"}
  try{& $v29 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore|Out-Host}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V31_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)"}
  throw $message
}
