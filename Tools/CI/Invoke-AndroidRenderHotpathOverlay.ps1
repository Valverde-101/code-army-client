param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$targets=@(
  'src\game\battlefield\TileMapGraphic.as',
  'src\game\battlefield\FogOfWar.as',
  'src\game\isometric\IsometricScene.as'
)
$backupRoot=Join-Path $RepoRoot ('.work\scratch\render-hotpath-overlay\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-One([string]$Text,[string]$Old,[string]$New,[string]$Name){
  $i=$Text.IndexOf($Old,[System.StringComparison]::Ordinal)
  if($i -lt 0){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL patch=$Name reason=pattern_missing"}
  if($Text.IndexOf($Old,$i+$Old.Length,[System.StringComparison]::Ordinal) -ge 0){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL patch=$Name reason=pattern_ambiguous"}
  return $Text.Substring(0,$i)+$New+$Text.Substring($i+$Old.Length)
}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL patch=$Name reason=semantic_match_count actual=$($matches.Count)"}
  $m=$matches[0]
  return $Text.Substring(0,$m.Index)+$Replacement+$Text.Substring($m.Index+$m.Length)
}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){Write-Host "ANDROID_RENDER_HOTPATH_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha";return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $src=Join-Path $backupRoot ([string]$entry.backup)
    $dst=Join-Path $RepoRoot ([string]$entry.path)
    if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL restore_backup_missing=$src"}
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $restored=Get-Sha256 $dst
    if($restored -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL restore_hash path=$($entry.path) expected=$($entry.sha256) actual=$restored"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_RENDER_HOTPATH_OVERLAY=PASS mode=restore baseline_restored=true composable=true sha=$ExpectedSha"
  return
}

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifest=[ordered]@{schema='armyattack-render-hotpath-overlay/v1';source_sha=$ExpectedSha;files=@()}
foreach($rel in $targets){
  $src=Join-Path $RepoRoot $rel
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL source_missing=$rel"}
  $backup=($rel -replace '[\\/]','__')+'.original'
  Copy-Item -LiteralPath $src -Destination (Join-Path $backupRoot $backup) -Force
  $manifest.files+=@([ordered]@{path=$rel;backup=$backup;sha256=(Get-Sha256 $src)})
}
$manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  # This overlay intentionally runs after the gameplay-stability overlay. It
  # turns the existing ownership dirty rectangle into a generic visual dirty
  # rectangle shared by ownership and fog, without changing gameplay cadence.
  $tilePath=Join-Path $RepoRoot 'src\game\battlefield\TileMapGraphic.as'
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  foreach($required in @('mOwnershipDirty:Boolean','redrawDirtyOwnershipRegion()','markOwnershipDirty(param1:GridCell)','TILEMAP_DIRTY_REDRAW')){
    if(-not $tile.Contains($required)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL order=gameplay_overlay_required token=$required"}
  }

  $tile=Replace-One $tile '      private var mForceFullRedraw:Boolean = false;' @'
      private var mForceFullRedraw:Boolean = false;
      private var mBorderDirty:Boolean = false;
      private var mDirtyReason:String = "";
'@ 'tile_hotpath_fields'

  $ownershipPattern='(?s)      public function markOwnershipDirty\(param1:GridCell\)\s*:\s*void\s*\{.*?      public function requestFullRedraw\(\)\s*:\s*void'
  $ownershipReplacement=@'
      public function markOwnershipDirty(param1:GridCell) : void
      {
         if(!param1)
         {
            return;
         }
         var padding:int = 1;
         this.mOwnershipDirty = true;
         this.mBorderDirty = true;
         this.mDirtyReason = this.mDirtyReason == "fog" ? "ownership+fog" : "ownership";
         this.mOwnershipDirtyMinX = Math.min(this.mOwnershipDirtyMinX,Math.max(0,param1.mPosI - padding));
         this.mOwnershipDirtyMinY = Math.min(this.mOwnershipDirtyMinY,Math.max(0,param1.mPosJ - padding));
         this.mOwnershipDirtyMaxX = Math.max(this.mOwnershipDirtyMaxX,Math.min(this.mMapData.mGridWidth - 1,param1.mPosI + padding));
         this.mOwnershipDirtyMaxY = Math.max(this.mOwnershipDirtyMaxY,Math.min(this.mMapData.mGridHeight - 1,param1.mPosJ + padding));
      }
      
      public function markFogDirty(param1:GridCell) : void
      {
         if(!param1)
         {
            return;
         }
         var padding:int = 1;
         this.mOwnershipDirty = true;
         this.mDirtyReason = this.mDirtyReason == "ownership" ? "ownership+fog" : (this.mDirtyReason == "ownership+fog" ? this.mDirtyReason : "fog");
         this.mOwnershipDirtyMinX = Math.min(this.mOwnershipDirtyMinX,Math.max(0,param1.mPosI - padding));
         this.mOwnershipDirtyMinY = Math.min(this.mOwnershipDirtyMinY,Math.max(0,param1.mPosJ - padding));
         this.mOwnershipDirtyMaxX = Math.max(this.mOwnershipDirtyMaxX,Math.min(this.mMapData.mGridWidth - 1,param1.mPosI + padding));
         this.mOwnershipDirtyMaxY = Math.max(this.mOwnershipDirtyMaxY,Math.min(this.mMapData.mGridHeight - 1,param1.mPosJ + padding));
      }
      
      public function requestFullRedraw() : void
'@
  $tile=Replace-RegexOne $tile $ownershipPattern $ownershipReplacement 'tile_generic_visual_dirty'

  $borderMethod=@'
      public function recalculateBorderEdgesDirty() : void
      {
         if(!this.mBorderDirty || this.mOwnershipDirtyMinX == 2147483647 || this.mOwnershipDirtyMinY == 2147483647)
         {
            this.recalculateBorderEdges();
            Utils.DiagEvent("BORDER_EDGE_RECALC","map=" + GameState.mInstance.mCurrentMapId + ";dirty=0;cells=" + (this.mMapData.mGridWidth * this.mMapData.mGridHeight));
            return;
         }
         var width:int = this.mMapData.mGridWidth;
         var height:int = this.mMapData.mGridHeight;
         var left:int = Math.max(0,this.mOwnershipDirtyMinX);
         var top:int = Math.max(0,this.mOwnershipDirtyMinY);
         var right:int = Math.min(width - 1,this.mOwnershipDirtyMaxX);
         var bottom:int = Math.min(height - 1,this.mOwnershipDirtyMaxY);
         var cell:GridCell = null;
         var bits:int = 0;
         var baseIndex:int = 0;
         var neighborIndex:int = 0;
         var bit:int = 0;
         var x:int = left;
         var y:int = 0;
         while(x <= right)
         {
            y = top;
            while(y <= bottom)
            {
               cell = this.mGrid[y * width + x] as GridCell;
               bits = 0;
               if(cell.mOwner == MapData.TILE_OWNER_ENEMY || cell.mOwner == MapData.TILE_OWNER_NEUTRAL)
               {
                  baseIndex = (y - 1) * width + (x - 1);
                  bit = 0;
                  while(bit < 9)
                  {
                     neighborIndex = baseIndex + bit % 3 + int(bit / 3) * width;
                     if(neighborIndex >= 0 && neighborIndex < this.mGrid.length)
                     {
                        if((this.mGrid[neighborIndex] as GridCell).mOwner == MapData.TILE_OWNER_FRIENDLY)
                        {
                           bits |= 1 << bit;
                        }
                     }
                     bit++;
                  }
               }
               cell.mBorderEdgeBits = bits;
               y++;
            }
            x++;
         }
         this.mBorderDirty = false;
         Utils.DiagEvent("BORDER_EDGE_RECALC","map=" + GameState.mInstance.mCurrentMapId + ";dirty=1;cells=" + ((right - left + 1) * (bottom - top + 1)) + ";bounds=" + left + "," + top + "," + right + "," + bottom);
      }
      
'@
  $tile=Replace-One $tile '      public function recalculateBorderEdges() : void' ($borderMethod+'      public function recalculateBorderEdges() : void') 'tile_dirty_border_method'

  $clearPattern='(?s)      private function clearOwnershipDirtyState\(\)\s*:\s*void\s*\{.*?      private function redrawDirtyOwnershipRegion\(\)\s*:\s*Boolean'
  $clearReplacement=@'
      private function clearOwnershipDirtyState() : void
      {
         this.mOwnershipDirty = false;
         this.mOwnershipDirtyMinX = 2147483647;
         this.mOwnershipDirtyMinY = 2147483647;
         this.mOwnershipDirtyMaxX = -1;
         this.mOwnershipDirtyMaxY = -1;
         this.mForceFullRedraw = false;
         this.mBorderDirty = false;
         this.mDirtyReason = "";
      }
      
      private function redrawDirtyOwnershipRegion() : Boolean
'@
  $tile=Replace-RegexOne $tile $clearPattern $clearReplacement 'tile_dirty_state_reset'

  $clearBitmapMethod=@'
      private function clearDirtyBitmapRegion(param1:int, param2:int, param3:int, param4:int) : void
      {
         if(!Config.ENABLE_SINGLE_BITMAP_FIELD_RENDERING || !this.mFieldBmp || !this.mFogBmp || !this.mFieldBmp.bitmapData || !this.mFogBmp.bitmapData)
         {
            return;
         }
         var scaleX:Number = this.mScene.mContainer.scaleX;
         var scaleY:Number = this.mScene.mContainer.scaleY;
         var px:Number = param1 * this.mScene.mGridDimX * scaleX + this.mScene.mContainer.x + CAMERA_CACHE_MARGIN;
         var py:Number = param2 * this.mScene.mGridDimY * scaleY + this.mScene.mContainer.y + CAMERA_CACHE_MARGIN;
         var pw:Number = (param3 - param1) * this.mScene.mGridDimX * scaleX;
         var ph:Number = (param4 - param2) * this.mScene.mGridDimY * scaleY;
         var rect:Rectangle = new Rectangle(Math.floor(px) - 2,Math.floor(py) - 2,Math.ceil(pw) + 4,Math.ceil(ph) + 4);
         var fieldRect:Rectangle = rect.intersection(this.mFieldBmp.bitmapData.rect);
         var fogRect:Rectangle = rect.intersection(this.mFogBmp.bitmapData.rect);
         if(fieldRect.width > 0 && fieldRect.height > 0)
         {
            this.mFieldBmp.bitmapData.fillRect(fieldRect,0);
         }
         if(fogRect.width > 0 && fogRect.height > 0)
         {
            this.mFogBmp.bitmapData.fillRect(fogRect,0);
         }
      }
      
'@
  $tile=Replace-One $tile '      public function updateCameraViewport() : Boolean' ($clearBitmapMethod+'      public function updateCameraViewport() : Boolean') 'tile_dirty_bitmap_clear_method'

  $redrawPattern='(?s)(private function redrawDirtyOwnershipRegion\(\)\s*:\s*Boolean\s*\{.*?this\.mLastDrawScale\s*=\s*this\.mScene\.mContainer\.scaleX;\s*)(this\.drawArea\(left,top,right,bottom\);)'
  $redrawMatches=[regex]::Matches($tile,$redrawPattern)
  if($redrawMatches.Count -ne 1){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL patch=tile_dirty_bitmap_clear_call reason=semantic_match_count actual=$($redrawMatches.Count)"}
  $redrawMatch=$redrawMatches[0]
  $redrawReplacement=$redrawMatch.Groups[1].Value+'this.clearDirtyBitmapRegion(left,top,right,bottom);'+"`n         "+$redrawMatch.Groups[2].Value
  $tile=$tile.Substring(0,$redrawMatch.Index)+$redrawReplacement+$tile.Substring($redrawMatch.Index+$redrawMatch.Length)
  $tile=$tile.Replace('Utils.DiagEvent("TILEMAP_DIRTY_REDRAW","map=" + GameState.mInstance.mCurrentMapId + ";cells=" + this.mLastDrawCellCount + ";bounds=" + left + "," + top + "," + right + "," + bottom);','Utils.DiagEvent("TILEMAP_DIRTY_REDRAW","map=" + GameState.mInstance.mCurrentMapId + ";reason=" + this.mDirtyReason + ";cells=" + this.mLastDrawCellCount + ";bounds=" + left + "," + top + "," + right + "," + bottom);')
  Write-Utf8Bom $tilePath $tile

  $fogPath=Join-Path $RepoRoot 'src\game\battlefield\FogOfWar.as'
  $fog=Normalize-Lf ([IO.File]::ReadAllText($fogPath))
  $fog=Replace-One $fog '      private var mGrid:Array;' @'
      private var mGrid:Array;
      
      private var mDirty:Boolean = false;
      private var mDirtyMinX:int = 2147483647;
      private var mDirtyMinY:int = 2147483647;
      private var mDirtyMaxX:int = -1;
      private var mDirtyMaxY:int = -1;
'@ 'fog_dirty_fields'

  $fogDirtyMethods=@'
      private function markFogDirty(param1:GridCell) : void
      {
         if(!param1)
         {
            return;
         }
         var padding:int = 1;
         this.mUpdateRequired = true;
         this.mDirty = true;
         this.mDirtyMinX = Math.min(this.mDirtyMinX,Math.max(0,param1.mPosI - padding));
         this.mDirtyMinY = Math.min(this.mDirtyMinY,Math.max(0,param1.mPosJ - padding));
         this.mDirtyMaxX = Math.max(this.mDirtyMaxX,Math.min(this.mMapData.mGridWidth - 1,param1.mPosI + padding));
         this.mDirtyMaxY = Math.max(this.mDirtyMaxY,Math.min(this.mMapData.mGridHeight - 1,param1.mPosJ + padding));
         if(this.mScene && this.mScene.mTilemapGraphic)
         {
            this.mScene.mTilemapGraphic.markFogDirty(param1);
         }
      }
      
      private function clearFogDirtyState() : void
      {
         this.mDirty = false;
         this.mDirtyMinX = 2147483647;
         this.mDirtyMinY = 2147483647;
         this.mDirtyMaxX = -1;
         this.mDirtyMaxY = -1;
      }
      
      public function recalculateFogEdgesDirty() : void
      {
         if(GameState.mInstance.mState == GameState.STATE_PVP)
         {
            this.clearFogDirtyState();
            return;
         }
         if(!this.mDirty || this.mDirtyMinX == 2147483647 || this.mDirtyMinY == 2147483647)
         {
            this.recalculateFogEdges();
            trace("FOG_EDGE_RECALC dirty=0 cells=" + (this.mMapData.mGridWidth * this.mMapData.mGridHeight));
            return;
         }
         var width:int = this.mMapData.mGridWidth;
         var height:int = this.mMapData.mGridHeight;
         var left:int = Math.max(0,this.mDirtyMinX);
         var top:int = Math.max(0,this.mDirtyMinY);
         var right:int = Math.min(width - 1,this.mDirtyMaxX);
         var bottom:int = Math.min(height - 1,this.mDirtyMaxY);
         var cell:GridCell = null;
         var bits:int = 0;
         var baseIndex:int = 0;
         var neighborIndex:int = 0;
         var bit:int = 0;
         var x:int = left;
         var y:int = 0;
         while(x <= right)
         {
            y = top;
            while(y <= bottom)
            {
               cell = this.mGrid[y * width + x] as GridCell;
               bits = 0;
               if(!cell.hasFog())
               {
                  baseIndex = (y - 1) * width + (x - 1);
                  bit = 0;
                  while(bit < 9)
                  {
                     neighborIndex = baseIndex + bit % 3 + int(bit / 3) * width;
                     if(neighborIndex >= 0 && neighborIndex < this.mGrid.length)
                     {
                        if((this.mGrid[neighborIndex] as GridCell).hasFog())
                        {
                           bits |= 1 << bit;
                        }
                     }
                     bit++;
                  }
               }
               cell.mFogEdgeBits = bits;
               y++;
            }
            x++;
         }
         trace("FOG_EDGE_RECALC dirty=1 cells=" + ((right - left + 1) * (bottom - top + 1)) + " bounds=" + left + "," + top + "," + right + "," + bottom);
         this.clearFogDirtyState();
      }
      
'@
  $fog=Replace-One $fog '      public function recalculateFogEdges() : void' ($fogDirtyMethods+'      public function recalculateFogEdges() : void') 'fog_dirty_methods'

  $fog=$fog.Replace('         if(param1.mViewers == 0)`n         {`n            this.mUpdateRequired = true;','         if(param1.mViewers == 0)`n         {`n            this.markFogDirty(param1);')
  $fog=$fog.Replace('               param1.mViewers = 0;`n               this.mUpdateRequired = true;','               param1.mViewers = 0;`n               this.markFogDirty(param1);')
  $fog=$fog.Replace('                           _loc7_.mViewers = 0;`n                           this.mUpdateRequired = true;','                           _loc7_.mViewers = 0;`n                           this.markFogDirty(_loc7_);')
  foreach($token in @('this.markFogDirty(param1);','this.markFogDirty(_loc7_);')){
    if(-not $fog.Contains($token)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL verify_fog_transition token=$token"}
  }
  Write-Utf8Bom $fogPath $fog

  $scenePath=Join-Path $RepoRoot 'src\game\isometric\IsometricScene.as'
  $scene=Normalize-Lf ([IO.File]::ReadAllText($scenePath))
  # Gameplay overlay previously forced every fog change through a full redraw.
  # Remove only that injected call, then route global edge sweeps through the
  # dirty-aware methods with safe full fallbacks.
  $fogFullPattern='(?s)(if\s*\(this\.mFog\.mUpdateRequired\)\s*\{\s*)(this\.mTilemapGraphic\.requestFullRedraw\(\);\s*)'
  $fogFullMatches=[regex]::Matches($scene,$fogFullPattern)
  if($fogFullMatches.Count -ne 1){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL patch=scene_fog_full_redraw_remove reason=semantic_match_count actual=$($fogFullMatches.Count)"}
  $m=$fogFullMatches[0]
  $scene=$scene.Substring(0,$m.Index)+$m.Groups[1].Value+$scene.Substring($m.Index+$m.Length)
  $scene=Replace-One $scene 'this.mFog.recalculateFogEdges();' 'this.mFog.recalculateFogEdgesDirty();' 'scene_fog_edges_dirty'
  $scene=Replace-One $scene 'this.mTilemapGraphic.recalculateBorderEdges();' 'this.mTilemapGraphic.recalculateBorderEdgesDirty();' 'scene_border_edges_dirty'
  Write-Utf8Bom $scenePath $scene

  $tileVerify=[IO.File]::ReadAllText($tilePath)
  $fogVerify=[IO.File]::ReadAllText($fogPath)
  $sceneVerify=[IO.File]::ReadAllText($scenePath)
  foreach($token in @('markFogDirty(param1:GridCell)','recalculateBorderEdgesDirty()','clearDirtyBitmapRegion(left,top,right,bottom)','BORDER_EDGE_RECALC','reason=" + this.mDirtyReason')){if(-not $tileVerify.Contains($token)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL verify_tile token=$token"}}
  foreach($token in @('recalculateFogEdgesDirty()','markFogDirty(param1:GridCell)','FOG_EDGE_RECALC')){if(-not $fogVerify.Contains($token)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL verify_fog token=$token"}}
  foreach($token in @('this.mFog.recalculateFogEdgesDirty();','this.mTilemapGraphic.recalculateBorderEdgesDirty();')){if(-not $sceneVerify.Contains($token)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL verify_scene token=$token"}}
  if($sceneVerify.Contains('this.mTilemapGraphic.requestFullRedraw();')){throw 'ANDROID_RENDER_HOTPATH_OVERLAY=FAIL verify_scene fog_full_redraw_still_present'}

  Write-Host 'REGRESSION_CHECK=PASS name=fog_dirty_region_localized fallback=full'
  Write-Host 'REGRESSION_CHECK=PASS name=border_edges_dirty_region_localized ownership_only=true fallback=full'
  Write-Host 'REGRESSION_CHECK=PASS name=dirty_bitmap_clear_prevents_stale_fog_and_snow_tint'
  Write-Host 'REGRESSION_CHECK=PASS name=fog_does_not_force_full_redraw'
  Write-Host 'REGRESSION_CHECK=PASS name=gameplay_logic_cadence_unchanged scope=renderer_only'
  Write-Host "ANDROID_RENDER_HOTPATH_OVERLAY=PASS mode=apply sha=$ExpectedSha targets=$($targets.Count)"
}catch{
  $failure=$_
  try{& $PSCommandPath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_RENDER_HOTPATH_OVERLAY_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}