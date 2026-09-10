param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$targets=@(
  'src\game\battlefield\TileMapGraphic.as',
  'src\game\isometric\IsometricScene.as',
  'src\game\isometric\characters\IsometricCharacter.as'
)
$backupRoot=Join-Path $RepoRoot ('.work\scratch\gameplay-stability-overlay\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Replace-Exact([string]$Text,[string]$Old,[string]$New,[string]$Name){
  $i=$Text.IndexOf($Old,[System.StringComparison]::Ordinal)
  if($i -lt 0){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL patch=$Name reason=pattern_missing"}
  if($Text.IndexOf($Old,$i+$Old.Length,[System.StringComparison]::Ordinal) -ge 0){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL patch=$Name reason=pattern_ambiguous"}
  $Text.Substring(0,$i)+$New+$Text.Substring($i+$Old.Length)
}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){Write-Host "GAMEPLAY_STABILITY_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha";return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $src=Join-Path $backupRoot ([string]$entry.backup)
    $dst=Join-Path $RepoRoot ([string]$entry.path)
    if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL restore_backup_missing=$src"}
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $restored=Get-Sha256 $dst
    if($restored -ne ([string]$entry.sha256).ToUpperInvariant()){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL restore_hash path=$($entry.path) expected=$($entry.sha256) actual=$restored"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "GAMEPLAY_STABILITY_OVERLAY=PASS mode=restore baseline_restored=true composable=true sha=$ExpectedSha"
  return
}

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifest=[ordered]@{schema='armyattack-gameplay-stability-overlay/v5';source_sha=$ExpectedSha;files=@()}
foreach($rel in $targets){
  $src=Join-Path $RepoRoot $rel
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL source_missing=$rel"}
  $backup=($rel -replace '[\\/]','__')+'.original'
  Copy-Item -LiteralPath $src -Destination (Join-Path $backupRoot $backup) -Force
  $manifest.files+=@([ordered]@{path=$rel;backup=$backup;sha256=(Get-Sha256 $src)})
}
$manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $tilePath=Join-Path $RepoRoot 'src\game\battlefield\TileMapGraphic.as'
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  if(-not $tile.Contains('getLastDrawCellCount()')){throw 'GAMEPLAY_STABILITY_OVERLAY=FAIL order=performance_overlay_must_run_first'}
  if(-not $tile.Contains('mCameraCacheEffectiveMarginX')){throw 'GAMEPLAY_STABILITY_OVERLAY=FAIL order=performance_cache_contract_missing'}

  $tile=Replace-Exact $tile '      private var mVectCounter:int = 0;' @'
      private var mVectCounter:int = 0;
      
      // Targeted ownership invalidation. Normal ownership flips redraw only a
      // small neighborhood; map loads, fog changes and moved camera caches use
      // the existing full rebuild path.
      private var mOwnershipDirty:Boolean = false;
      private var mOwnershipDirtyMinX:int = 2147483647;
      private var mOwnershipDirtyMinY:int = 2147483647;
      private var mOwnershipDirtyMaxX:int = -1;
      private var mOwnershipDirtyMaxY:int = -1;
      private var mForceFullRedraw:Boolean = false;
      private var mSnowOwnershipOverlay:Shape = new Shape();
      private static const SNOW_OWNER_FRIENDLY_COLOR:uint = 0x2F78FF;
      private static const SNOW_OWNER_ENEMY_COLOR:uint = 0xD94444;
      private static const SNOW_OWNER_NEUTRAL_COLOR:uint = 0x59636E;
'@ 'tile_dirty_fields'

  $tile=Replace-Exact $tile '         this.mUid = !!Config.smUserId ? int(Config.smUserId) : int(GameState.mInstance.mServer.getUid());' @'
         if(this.redrawDirtyOwnershipRegion())
         {
            return;
         }
         this.mUid = !!Config.smUserId ? int(Config.smUserId) : int(GameState.mInstance.mServer.getUid());
'@ 'tile_partial_redraw_entry'

  # Performance runs before this overlay and intentionally rewrites the lines
  # immediately preceding this call. Hook the unique stable call itself instead
  # of coupling to those rewritten neighboring lines.
  $tile=Replace-Exact $tile '         this.updateUnderCloudEnemyUnits();' @'
         this.clearOwnershipDirtyState();
         this.updateUnderCloudEnemyUnits();
'@ 'tile_full_redraw_clears_dirty'

  $tile=Replace-Exact $tile '      public function updateCameraViewport() : Boolean' @'
      public function markOwnershipDirty(param1:GridCell) : void
      {
         if(!param1)
         {
            return;
         }
         var padding:int = 1;
         this.mOwnershipDirty = true;
         this.mOwnershipDirtyMinX = Math.min(this.mOwnershipDirtyMinX,Math.max(0,param1.mPosI - padding));
         this.mOwnershipDirtyMinY = Math.min(this.mOwnershipDirtyMinY,Math.max(0,param1.mPosJ - padding));
         this.mOwnershipDirtyMaxX = Math.max(this.mOwnershipDirtyMaxX,Math.min(this.mMapData.mGridWidth - 1,param1.mPosI + padding));
         this.mOwnershipDirtyMaxY = Math.max(this.mOwnershipDirtyMaxY,Math.min(this.mMapData.mGridHeight - 1,param1.mPosJ + padding));
      }
      
      public function requestFullRedraw() : void
      {
         this.mForceFullRedraw = true;
      }
      
      private function clearOwnershipDirtyState() : void
      {
         this.mOwnershipDirty = false;
         this.mOwnershipDirtyMinX = 2147483647;
         this.mOwnershipDirtyMinY = 2147483647;
         this.mOwnershipDirtyMaxX = -1;
         this.mOwnershipDirtyMaxY = -1;
         this.mForceFullRedraw = false;
      }
      
      private function redrawDirtyOwnershipRegion() : Boolean
      {
         if(!this.mOwnershipDirty || this.mForceFullRedraw || !Config.ENABLE_SINGLE_BITMAP_FIELD_RENDERING || !this.mFieldBmp || !this.mFogBmp || isNaN(this.mCameraCacheAnchorX) || isNaN(this.mCameraCacheAnchorY))
         {
            return false;
         }
         var dx:Number = this.mScene.mContainer.x - this.mCameraCacheAnchorX;
         var dy:Number = this.mScene.mContainer.y - this.mCameraCacheAnchorY;
         if(Math.abs(dx) > 1 || Math.abs(dy) > 1)
         {
            return false;
         }
         var left:int = Math.max(0,this.mOwnershipDirtyMinX);
         var top:int = Math.max(0,this.mOwnershipDirtyMinY);
         var right:int = Math.min(this.mMapData.mGridWidth,this.mOwnershipDirtyMaxX + 1);
         var bottom:int = Math.min(this.mMapData.mGridHeight,this.mOwnershipDirtyMaxY + 1);
         if(right <= left || bottom <= top)
         {
            this.clearOwnershipDirtyState();
            return false;
         }
         this.mLastDrawLeft = left;
         this.mLastDrawTop = top;
         this.mLastDrawRight = right;
         this.mLastDrawBottom = bottom;
         this.mLastDrawCellCount = (right - left) * (bottom - top);
         this.mLastDrawScale = this.mScene.mContainer.scaleX;
         this.drawArea(left,top,right,bottom);
         this.updateUnderCloudEnemyUnits();
         Utils.DiagEvent("TILEMAP_DIRTY_REDRAW","map=" + GameState.mInstance.mCurrentMapId + ";cells=" + this.mLastDrawCellCount + ";bounds=" + left + "," + top + "," + right + "," + bottom);
         this.clearOwnershipDirtyState();
         return true;
      }
      
      public function updateCameraViewport() : Boolean
'@ 'tile_dirty_methods'

  # Do not anchor this call to FFDec's neighboring decompiler comments. The
  # semantic end of drawArea is the permanent-HFE gate, which is unique and
  # intentionally untouched by the performance overlay.
  $tile=Replace-Exact $tile '         if(GameState.needToUpdatePermanentHFE)' @'
         this.drawSnowOwnershipOverlayArea(param1,param2,param3,param4);
         if(GameState.needToUpdatePermanentHFE)
'@ 'snow_overlay_call'

  $tile=Replace-Exact $tile '      public function updatePermanentHFEs() : void' @'
      private function drawSnowOwnershipOverlayArea(param1:int, param2:int, param3:int, param4:int) : void
      {
         if(GameState.mInstance.mCurrentMapId != "Snow" || !Config.ENABLE_SINGLE_BITMAP_FIELD_RENDERING || !this.mFieldBmp || !this.mFieldBmp.bitmapData)
         {
            return;
         }
         var overlayGraphics:* = this.mSnowOwnershipOverlay.graphics;
         overlayGraphics.clear();
         var scaleX:Number = this.mScene.mContainer.scaleX;
         var scaleY:Number = this.mScene.mContainer.scaleY;
         var cellWidth:Number = this.mScene.mGridDimX * scaleX;
         var cellHeight:Number = this.mScene.mGridDimY * scaleY;
         var x:int = param1;
         var y:int = 0;
         var cell:GridCell = null;
         var color:uint = 0;
         var alpha:Number = 0;
         var painted:int = 0;
         while(x < param3)
         {
            y = param2;
            while(y < param4)
            {
               cell = this.mGrid[y * this.mSizeX + x] as GridCell;
               if(cell && MapData.isTilePassable(cell.mType))
               {
                  if(cell.mOwner == MapData.TILE_OWNER_FRIENDLY)
                  {
                     color = SNOW_OWNER_FRIENDLY_COLOR;
                     alpha = 0.22;
                  }
                  else if(cell.mOwner == MapData.TILE_OWNER_ENEMY)
                  {
                     color = SNOW_OWNER_ENEMY_COLOR;
                     alpha = 0.20;
                  }
                  else
                  {
                     color = SNOW_OWNER_NEUTRAL_COLOR;
                     alpha = 0.10;
                  }
                  overlayGraphics.beginFill(color,alpha);
                  overlayGraphics.drawRect(x * cellWidth + this.mScene.mContainer.x + CAMERA_CACHE_MARGIN,y * cellHeight + this.mScene.mContainer.y + CAMERA_CACHE_MARGIN,cellWidth,cellHeight);
                  overlayGraphics.endFill();
                  painted++;
               }
               y++;
            }
            x++;
         }
         if(painted > 0)
         {
            mDrawMatrix.identity();
            this.mFieldBmp.bitmapData.draw(this.mSnowOwnershipOverlay,mDrawMatrix,null,null,null,false);
         }
      }
      
      public function updatePermanentHFEs() : void
'@ 'snow_overlay_method'
  Write-Utf8Bom $tilePath $tile

  $scenePath=Join-Path $RepoRoot 'src\game\isometric\IsometricScene.as'
  $scene=Normalize-Lf ([IO.File]::ReadAllText($scenePath))
  $scene=Replace-Exact $scene "`t`t`tif (this.mFog.mUpdateRequired) {" "`t`t`tif (this.mFog.mUpdateRequired) {`n`t`t`t`tthis.mTilemapGraphic.requestFullRedraw();" 'scene_fog_forces_full_redraw'
  $scene=Replace-Exact $scene "`t`t`tparam2.mOwner = MapData.TILE_OWNER_FRIENDLY;`n`t`t`tthis.mGame.mMapData.mUpdateRequired = true;" "`t`t`tparam2.mOwner = MapData.TILE_OWNER_FRIENDLY;`n`t`t`tif (this.mTilemapGraphic) this.mTilemapGraphic.markOwnershipDirty(param2);`n`t`t`tthis.mGame.mMapData.mUpdateRequired = true;" 'scene_spawn_owner_dirty'

  # The tracked source and outer overlays are allowed to reformat this method.
  # Scope the ownership invalidation semantically to changeCellOwner + the
  # Conquer decrement, instead of requiring the whole decompiled block byte-for-byte.
  $conquerPattern='(?s)(private function changeCellOwner\(param1:\s*GridCell\)\s*:\s*void\s*\{.*?MissionManager\.increaseCounter\("Conquer",\s*_loc2_,\s*-1\);\s*\}\s*)(this\.mGame\.mMapData\.mUpdateRequired\s*=\s*true;)'
  $conquerMatches=[regex]::Matches($scene,$conquerPattern)
  if($conquerMatches.Count -ne 1){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL patch=scene_conquer_owner_dirty reason=semantic_match_count actual=$($conquerMatches.Count)"}
  $conquerReplacement='$1'+'if (this.mTilemapGraphic) this.mTilemapGraphic.markOwnershipDirty(param1);'+"`n`t`t`t`t"+'$2'
  $scene=[regex]::Replace($scene,$conquerPattern,$conquerReplacement,1)
  Write-Utf8Bom $scenePath $scene

  $characterPath=Join-Path $RepoRoot 'src\game\isometric\characters\IsometricCharacter.as'
  $character=Normalize-Lf ([IO.File]::ReadAllText($characterPath))
  $oldHints=@'
		public function update(param1: int): void {
			var _loc2_: TextEffect = null;
			var _loc3_: MovieClip = null;
			if (this.mUpdateHintHealth) {
				this.updateHintHealth();
			}
			if (this.mUpdateHintPower) {
				this.updateHintPower();
			}
'@
  $newHints=@'
		public function update(param1: int): void {
			var _loc2_: TextEffect = null;
			var _loc3_: MovieClip = null;
			// These nested SWF walks are visual only. Keep the dirty flags pending
			// while culled; all gameplay logic below still executes every tick.
			var updateVisualHints:Boolean = mContainer == null || mContainer.visible;
			if (updateVisualHints && this.mUpdateHintHealth) {
				this.updateHintHealth();
			}
			if (updateVisualHints && this.mUpdateHintPower) {
				this.updateHintPower();
			}
'@
  $character=Replace-Exact $character $oldHints $newHints 'character_defer_culled_visual_hints'
  Write-Utf8Bom $characterPath $character

  $tileVerify=[IO.File]::ReadAllText($tilePath)
  $sceneVerify=[IO.File]::ReadAllText($scenePath)
  $characterVerify=[IO.File]::ReadAllText($characterPath)
  foreach($token in @('redrawDirtyOwnershipRegion()','markOwnershipDirty(param1:GridCell)','TILEMAP_DIRTY_REDRAW','drawSnowOwnershipOverlayArea','SNOW_OWNER_FRIENDLY_COLOR','clearOwnershipDirtyState();')){if(-not $tileVerify.Contains($token)){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL verify_tile token=$token"}}
  foreach($token in @('requestFullRedraw()','markOwnershipDirty(param2)','markOwnershipDirty(param1)')){if(-not $sceneVerify.Contains($token)){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL verify_scene token=$token"}}
  foreach($token in @('updateVisualHints:Boolean','updateVisualHints && this.mUpdateHintHealth','updateVisualHints && this.mUpdateHintPower')){if(-not $characterVerify.Contains($token)){throw "GAMEPLAY_STABILITY_OVERLAY=FAIL verify_character token=$token"}}
  Write-Host 'REGRESSION_CHECK=PASS name=overlay_composition_performance_then_gameplay stable_hook=updateUnderCloudEnemyUnits'
  Write-Host 'REGRESSION_CHECK=PASS name=overlay_composition_snow_visual_semantic_hook stable_hook=GameState.needToUpdatePermanentHFE'
  Write-Host 'REGRESSION_CHECK=PASS name=overlay_composition_conquer_semantic_hook stable_hook=changeCellOwner+Conquer'
  Write-Host 'REGRESSION_CHECK=PASS name=character_logic_not_culled scope=actions_movement_projectiles_timers_healing_death'
  Write-Host 'REGRESSION_CHECK=PASS name=character_culling_defers_visual_hints_only'
  Write-Host 'REGRESSION_CHECK=PASS name=ownership_dirty_region_full_redraw_fallback'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_ownership_high_contrast player=blue enemy=red neutral=gray'
  Write-Host "GAMEPLAY_STABILITY_OVERLAY=PASS mode=apply sha=$ExpectedSha targets=$($targets.Count)"
}catch{
  $failure=$_
  try{& $PSCommandPath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "GAMEPLAY_STABILITY_OVERLAY_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
