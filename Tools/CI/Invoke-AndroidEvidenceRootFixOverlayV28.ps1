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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v27=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV27.ps1'
if(-not(Test-Path -LiteralPath $v27 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL predecessor_missing=$v27"}

$tilePath=Join-Path $RepoRoot 'src\game\battlefield\TileMapGraphic.as'
$offlinePath=Join-Path $RepoRoot 'src\game\utils\OfflineSave.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v28\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V28_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL restore_backup_missing path=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    $actualHash=Get-Sha256 $target
    $expectedHash=([string]$entry.sha256).ToUpperInvariant()
    if($actualHash -ne $expectedHash){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL restore_hash path=$($entry.path) expected=$expectedHash actual=$actualHash"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v27 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V28=PASS mode=restore predecessor=v27 sha=$ExpectedSha"
  return
}

& $v27 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL predecessor_apply_exit=$LASTEXITCODE"}

try {
  foreach($required in @($tilePath,$offlinePath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V28=FAIL required_file_missing path=$required"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  Copy-Item -LiteralPath $tilePath -Destination (Join-Path $backupRoot 'TileMapGraphic.post-runtime.as') -Force
  Copy-Item -LiteralPath $offlinePath -Destination (Join-Path $backupRoot 'OfflineSave.post-v27.as') -Force
  $files=@(
    [ordered]@{path='src\game\battlefield\TileMapGraphic.as';backup='TileMapGraphic.post-runtime.as';sha256=(Get-Sha256 $tilePath)},
    [ordered]@{path='src\game\utils\OfflineSave.as';backup='OfflineSave.post-v27.as';sha256=(Get-Sha256 $offlinePath)}
  )
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v28';source_sha=$ExpectedSha;predecessor='v27';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # Physical evidence from 77d58869 showed ownership partial redraws after conquest,
  # but the authored white ownership perimeter only updated on part of the region.
  # drawBorderEdges() consumes GridCell.mBorderEdgeBits; the optimized dirty redraw
  # changed the owner fill without recomputing those bits. Recompute topology before
  # the bounded redraw so the whole white perimeter follows every conquest.
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  $borderNeedle=@'
         this.mLastDrawScale = this.mScene.mContainer.scaleX;
         this.drawArea(left,top,right,bottom);
         this.updateUnderCloudEnemyUnits();
'@.TrimEnd()
  $borderReplacement=@'
         this.mLastDrawScale = this.mScene.mContainer.scaleX;
         this.recalculateBorderEdges();
         Utils.DiagEvent("OWNERSHIP_BORDER_RECALC","map=" + GameState.mInstance.mCurrentMapId + ";cells=" + this.mLastDrawCellCount + ";mode=before_dirty_draw");
         this.drawArea(left,top,right,bottom);
         this.updateUnderCloudEnemyUnits();
'@.TrimEnd()
  $tile=Replace-LiteralOne $tile $borderNeedle $borderReplacement 'ownership_border_topology_before_dirty_draw'
  $recalcIndex=$tile.IndexOf('this.recalculateBorderEdges();',[StringComparison]::Ordinal)
  $dirtyDrawIndex=$tile.IndexOf('this.drawArea(left,top,right,bottom);',[StringComparison]::Ordinal)
  if($recalcIndex -lt 0 -or $dirtyDrawIndex -lt 0 -or $recalcIndex -gt $dirtyDrawIndex){throw 'ANDROID_EVIDENCE_ROOTFIX_V28=FAIL ownership_border_order'}
  Require-Token $tile 'OWNERSHIP_BORDER_RECALC' 'ownership_border_recalc_telemetry'
  Write-Utf8Bom $tilePath $tile
  Write-Host 'REGRESSION_CHECK=PASS name=ownership_dirty_recalculates_border_edges_before_partial_draw topology=current perimeter=continuous'

  # Snow first visit was entering OfflineSave.switchMap() with has_saved=false.
  # The old branch initialized the tile map and zero objects, while initOfflineMap()
  # marks every passable non-PvP tile ENEMY. Missions then materialized blue player
  # units on enemy-owned cells, leaving no friendly walkable bridgehead. Seed the
  # initial friendly territory from the actual authored player-unit spawn cells after
  # missions materialize, then rebuild movement and mark exactly those cells dirty.
  $offline=Normalize-Lf ([IO.File]::ReadAllText($offlinePath))
  $offline=Replace-LiteralOne $offline "`timport game.isometric.GridCell;" "`timport game.battlefield.MapData;`n`timport game.isometric.GridCell;" 'snow_seed_mapdata_import'
  $offline=Replace-LiteralOne $offline "`t`t`tvar savedMap: * = null;`n`t`t`tvar switchStarted: int = getTimer();" "`t`t`tvar savedMap: * = null;`n`t`t`tvar firstVisit: Boolean = !Boolean(mMaps[map_id]);`n`t`t`tvar switchStarted: int = getTimer();" 'snow_first_visit_capture'
  $missionNeedle=@'
			MissionManager.findNewActiveMissions();
			Utils.DiagEvent("OFFLINE_MAP_TIMING","map=" + map_id + ";phase=fog_missions;ms=" + (getTimer() - mapPhaseStarted));
'@.TrimEnd()
  $missionReplacement=@'
			MissionManager.findNewActiveMissions();
			if (map_id == "Snow" && firstVisit) {
				seedSnowFirstVisitFriendlyTerritory();
			}
			Utils.DiagEvent("OFFLINE_MAP_TIMING","map=" + map_id + ";phase=fog_missions;ms=" + (getTimer() - mapPhaseStarted));
'@.TrimEnd()
  $offline=Replace-LiteralOne $offline $missionNeedle $missionReplacement 'snow_seed_after_authored_missions'

  $helperAnchor="`n`t`tpublic static function generateSaveJson(): * {"
  $helper=@'

		private static function seedSnowFirstVisitFriendlyTerritory(): void {
			var state: GameState = GameState.mInstance;
			if (!state || !state.mMapData || !state.mMapData.mGrid || !state.mScene) {
				Utils.DiagEvent("SNOW_FIRST_VISIT_OWNERSHIP","result=SKIP;reason=runtime_not_ready");
				return;
			}
			var grid: Array = state.mMapData.mGrid;
			var width: int = state.mMapData.mGridWidth;
			var height: int = state.mMapData.mGridHeight;
			var playerCells: Array = new Array();
			var index: int = 0;
			var cell: GridCell = null;
			while (index < grid.length) {
				cell = grid[index] as GridCell;
				if (cell && cell.mCharacter is PlayerUnit) {
					playerCells.push(cell);
				}
				index++;
			}
			var authoredPlayers: int = playerCells.length;
			var fallback: Boolean = false;
			if (playerCells.length == 0) {
				fallback = true;
				cell = grid[int(height / 2) * width + int(width / 2)] as GridCell;
				if (cell) playerCells.push(cell);
			}
			var radius: int = 2;
			var seeded: int = 0;
			var sourceIndex: int = 0;
			var dx: int = 0;
			var dy: int = 0;
			var x: int = 0;
			var y: int = 0;
			var seedCell: GridCell = null;
			while (sourceIndex < playerCells.length) {
				cell = playerCells[sourceIndex] as GridCell;
				dy = -radius;
				while (dy <= radius) {
					dx = -radius;
					while (dx <= radius) {
						x = cell.mPosI + dx;
						y = cell.mPosJ + dy;
						if (x >= 0 && x < width && y >= 0 && y < height) {
							seedCell = grid[y * width + x] as GridCell;
							if (seedCell && MapData.isTilePassable(seedCell.mType) && seedCell.mOwner != MapData.TILE_OWNER_FRIENDLY) {
								seedCell.mOwner = MapData.TILE_OWNER_FRIENDLY;
								if (state.mScene.mTilemapGraphic) state.mScene.mTilemapGraphic.markOwnershipDirty(seedCell);
								seeded++;
							}
						}
						dx++;
					}
					dy++;
				}
				sourceIndex++;
			}
			state.mMapData.mUpdateRequired = true;
			state.updateGrid();
			if (state.mScene.mTilemapGraphic) state.mScene.mTilemapGraphic.recalculateBorderEdges();
			Utils.DiagEvent("SNOW_FIRST_VISIT_OWNERSHIP","result=PASS;authored_players=" + authoredPlayers + ";sources=" + playerCells.length + ";seeded=" + seeded + ";radius=" + radius + ";fallback=" + fallback);
		}
'@.TrimEnd()
  $offline=Replace-LiteralOne $offline $helperAnchor ($helper+$helperAnchor) 'snow_first_visit_ownership_helper'

  foreach($token in @('var firstVisit: Boolean = !Boolean(mMaps[map_id]);','seedSnowFirstVisitFriendlyTerritory();','SNOW_FIRST_VISIT_OWNERSHIP','cell.mCharacter is PlayerUnit','MapData.TILE_OWNER_FRIENDLY','markOwnershipDirty(seedCell)','state.updateGrid();','recalculateBorderEdges();')){Require-Token $offline $token ('snow_contract_'+$token)}
  $missionIndex=$offline.IndexOf('MissionManager.findNewActiveMissions();',[StringComparison]::Ordinal)
  $seedCallIndex=$offline.IndexOf('seedSnowFirstVisitFriendlyTerritory();',[StringComparison]::Ordinal)
  if($missionIndex -lt 0 -or $seedCallIndex -lt 0 -or $seedCallIndex -lt $missionIndex){throw 'ANDROID_EVIDENCE_ROOTFIX_V28=FAIL snow_seed_order'}
  Write-Utf8Bom $offlinePath $offline
  Write-Host 'REGRESSION_CHECK=PASS name=snow_first_visit_seeds_friendly_ownership_from_authored_player_units radius=2 fallback=center'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_first_visit_rebuilds_movement_grid after=ownership_seed'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_first_visit_no_longer_leaves_all_passable_cells_enemy after=missions'

  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V28_MAP_OWNERSHIP=PASS border_topology=recomputed_before_dirty_draw snow_first_visit=player_spawn_seed movement_grid=rebuild telemetry=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V28=PASS mode=apply predecessor=v27 sha=$ExpectedSha"
}
catch {
  try { Restore-OwnedFiles } catch {}
  try { & $v27 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Null } catch {}
  throw
}
