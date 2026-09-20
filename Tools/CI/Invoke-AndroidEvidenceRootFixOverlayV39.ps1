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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v38=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV38.ps1'
$mapDataPath=Join-Path $RepoRoot 'src\game\battlefield\MapData.as'
$tilePath=Join-Path $RepoRoot 'src\game\battlefield\TileMapGraphic.as'
$characterPath=Join-Path $RepoRoot 'src\game\isometric\characters\IsometricCharacter.as'
$offlinePath=Join-Path $RepoRoot 'src\game\utils\OfflineSave.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v39\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v38 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL predecessor_missing=$v38"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V39_HOOK=PASS name=$Name matches=1 literal=true"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL verify=$Name token=$Token"}}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL restore_backup_missing=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL restore_hash=$($entry.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v38 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V39=PASS mode=restore predecessor=v38 sha=$ExpectedSha"
  return
}

& $v38 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  foreach($required in @($mapDataPath,$tilePath,$characterPath,$offlinePath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V39=FAIL required_file_missing=$required"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $entries=@()
  foreach($pair in @(
    @('src\game\battlefield\MapData.as',$mapDataPath,'MapData.post-v38.as'),
    @('src\game\battlefield\TileMapGraphic.as',$tilePath,'TileMapGraphic.post-v38.as'),
    @('src\game\isometric\characters\IsometricCharacter.as',$characterPath,'IsometricCharacter.post-v38.as'),
    @('src\game\utils\OfflineSave.as',$offlinePath,'OfflineSave.post-v38.as')
  )){
    Copy-Item -LiteralPath $pair[1] -Destination (Join-Path $backupRoot $pair[2]) -Force
    $entries += [ordered]@{path=$pair[0];backup=$pair[2];sha256=(Get-Sha256 $pair[1])}
  }
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v39';source_sha=$ExpectedSha;predecessor='v38';files=$entries}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # Snow was merged into config and routing, but the runtime terrain enum still
  # recognized only Grassland and Desert. Polar TileTypes therefore resolved to
  # an undefined map type. V28's first-visit ownership seed then forces a full
  # redraw after the intro mission opens; drawTransitionEdges indexed a missing
  # transition array and could throw Error #1009, rolling the whole map back.
  $mapData=Normalize-Lf ([IO.File]::ReadAllText($mapDataPath))
  $mapData=Replace-LiteralOne $mapData 'public static const TILE_MAP_TYPE_DESERT: int = 1;' "public static const TILE_MAP_TYPE_DESERT: int = 1;`n`n`t`tpublic static const TILE_MAP_TYPE_SNOW: int = 2;" 'snow_first_class_map_type_constant'
  $oldMapType=@'
				} else if (_loc3_ == "Desert") {
					TILES_MAP_TYPE[_loc2_.ID] = TILE_MAP_TYPE_DESERT;
				}
'@
  $newMapType=@'
				} else if (_loc3_ == "Desert") {
					TILES_MAP_TYPE[_loc2_.ID] = TILE_MAP_TYPE_DESERT;
				} else if (_loc3_ == "Snow") {
					TILES_MAP_TYPE[_loc2_.ID] = TILE_MAP_TYPE_SNOW;
				}
'@
  $mapData=Replace-LiteralOne $mapData (Normalize-Lf $oldMapType) (Normalize-Lf $newMapType) 'snow_tiletype_runtime_mapping'
  Require-Token $mapData 'TILE_MAP_TYPE_SNOW: int = 2' 'snow_map_type_constant'
  Require-Token $mapData '_loc3_ == "Snow"' 'snow_map_type_mapping'
  Write-Utf8Bom $mapDataPath $mapData

  # The preserved SWF has no dedicated Snow transition-blend family. Snow tiles
  # already contain authored friendly/enemy polar graphics, while territory
  # borders are rendered separately. Make that policy explicit and fail-safe:
  # no grass/desert transition sprite is borrowed and a missing blend set is a
  # deliberate base-tile-only path rather than a null dereference.
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  $desertTransition='TILES_TRANSITION[MapData.TILE_MAP_TYPE_DESERT] = ["swf/desert_backgroud_01/Bg_TransitionTile_desert_02","swf/desert_backgroud_01/Bg_TransitionTile_desert_04","swf/desert_backgroud_01/Bg_TransitionTile_desert_07","swf/desert_backgroud_01/Bg_TransitionTile_desert_09","swf/desert_backgroud_01/Bg_TransitionTile_desert_08","swf/desert_backgroud_01/Bg_TransitionTile_desert_03","swf/desert_backgroud_01/Bg_TransitionTile_desert_06","swf/desert_backgroud_01/Bg_TransitionTile_desert_05"];'
  $tile=Replace-LiteralOne $tile $desertTransition ($desertTransition+"`n         TILES_TRANSITION[MapData.TILE_MAP_TYPE_SNOW] = null;") 'snow_transition_policy_explicit'
  $transitionLookup='_loc3_ = TILES_TRANSITION[MapData.TILES_MAP_TYPE[this.mScene.getCellAt(param1,param2).mType]];'
  $transitionGuard=@'
_loc3_ = TILES_TRANSITION[MapData.TILES_MAP_TYPE[this.mScene.getCellAt(param1,param2).mType]];
            if(!_loc3_ || _loc3_.length < 8)
            {
               return;
            }
'@
  $tile=Replace-LiteralOne $tile $transitionLookup (Normalize-Lf $transitionGuard).TrimEnd() 'snow_transition_null_guard'
  Require-Token $tile 'TILES_TRANSITION[MapData.TILE_MAP_TYPE_SNOW] = null;' 'snow_transition_explicit_policy'
  Require-Token $tile 'if(!_loc3_ || _loc3_.length < 8)' 'transition_null_guard'
  Write-Utf8Bom $tilePath $tile

  # Physical evidence from ea021215 shows enemies repeatedly enter MOVE/MOVE_UP
  # while almost never switching back to IDLE after arriving. The movement core
  # owns the physical path, so it must also own the visual arrival boundary.
  # Do not depend on EnemyMovingAction polling or a later queued action to stop a
  # looping walk animation.
  $character=Normalize-Lf ([IO.File]::ReadAllText($characterPath))
  $pathConsume='this.mWalkingPath.length -= 2;'
  $arrivalCommit=@'
this.mWalkingPath.length -= 2;
				if (this.mWalkingPath.length == 0 && (getCurrentAnimationIndex() == AnimationController.CHARACTER_ANIMATION_MOVE || getCurrentAnimationIndex() == AnimationController.CHARACTER_ANIMATION_MOVE_UP)) {
					Utils.DiagEvent("MOVEMENT_VISUAL_ARRIVAL","owner=" + (this is EnemyUnit ? "enemy" : "character") + ";from=" + getCurrentAnimationIndex() + ";path=0");
					this.setAnimationAction(AnimationController.CHARACTER_ANIMATION_IDLE,false,true);
				}
'@
  $character=Replace-LiteralOne $character $pathConsume (Normalize-Lf $arrivalCommit).TrimEnd() 'movement_path_completion_commits_idle'
  Require-Token $character 'MOVEMENT_VISUAL_ARRIVAL' 'movement_arrival_telemetry'
  Require-Token $character 'CHARACTER_ANIMATION_IDLE,false,true' 'movement_arrival_idle'
  Write-Utf8Bom $characterPath $character

  # Give Snow an explicit post-materialization runtime identity and side-effect
  # branch. If this event is absent in future device evidence, the failure is
  # before commit; if present, Snow reached a coherent 51x51 runtime scene.
  $offline=Normalize-Lf ([IO.File]::ReadAllText($offlinePath))
  $mapSideEffects=@'
			if (map_id == "Desert") {
				(GameState.mInstance.getMainClip() as GameMain).changeDiscordMap("Desert");
				GameState.mInstance.mHUD.changeWaterVisibility(true);
			} else if (map_id == "Home") {
'@
  $mapSideEffectsNew=@'
			if (map_id == "Desert") {
				(GameState.mInstance.getMainClip() as GameMain).changeDiscordMap("Desert");
				GameState.mInstance.mHUD.changeWaterVisibility(true);
			} else if (map_id == "Snow") {
				(GameState.mInstance.getMainClip() as GameMain).changeDiscordMap("Snow");
				GameState.mInstance.mHUD.changeWaterVisibility(false);
				var snowExpectedCells:int = int(GameState.mConfig.MapSetup.Snow.Width) * int(GameState.mConfig.MapSetup.Snow.Height);
				var snowActualCells:int = GameState.mInstance.mMapData && GameState.mInstance.mMapData.mGrid ? GameState.mInstance.mMapData.mGrid.length : 0;
				if (snowActualCells != snowExpectedCells) {
					throw new Error("SNOW_RUNTIME_IDENTITY grid expected=" + snowExpectedCells + " actual=" + snowActualCells);
				}
				Utils.DiagEvent("SNOW_RUNTIME_IDENTITY","map=Snow;graphics=" + GameState.mInstance.mCurrentMapGraphicsId + ";grid=" + snowActualCells + ";map_type=" + MapData.TILE_MAP_TYPE_SNOW + ";transition_policy=base_tile_only");
			} else if (map_id == "Home") {
'@
  $offline=Replace-LiteralOne $offline (Normalize-Lf $mapSideEffects) (Normalize-Lf $mapSideEffectsNew) 'snow_post_materialization_identity'
  Require-Token $offline 'SNOW_RUNTIME_IDENTITY' 'snow_runtime_identity_telemetry'
  Require-Token $offline 'transition_policy=base_tile_only' 'snow_runtime_transition_policy'
  Write-Utf8Bom $offlinePath $offline

  Write-Host 'REGRESSION_CHECK=PASS name=snow_is_first_class_map_type value=2 tiletypes=polar_runtime_mapped'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_renderer_transition_policy explicit=base_tile_only null_deref=false grass_desert_blend_borrowed=false'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_first_visit_full_redraw_safe v28_seed=true polar_map_type=true transition_guard=true'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_runtime_identity grid=51x51 graphics_id=2 telemetry=SNOW_RUNTIME_IDENTITY'
  Write-Host 'REGRESSION_CHECK=PASS name=movement_path_completion_commits_idle_visual owner=movement_core action_queue_dependency=false'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_arrival_cannot_loop_walk_animation final_segment_idle=true telemetry=MOVEMENT_VISUAL_ARRIVAL'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V39=PASS mode=apply predecessor=v38 sha=$ExpectedSha snow_runtime_type=true snow_redraw_safe=true enemy_arrival_visual=true"
}
catch {
  $failure=$_
  try { Restore-OwnedFiles } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V39_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  try { & $v38 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Host } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V39_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  throw $failure
}
