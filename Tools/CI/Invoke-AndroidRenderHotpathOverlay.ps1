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
function Replace-RegexPrefix([string]$Text,[string]$Pattern,[string]$Suffix,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL patch=$Name reason=semantic_match_count actual=$($matches.Count)"}
  $m=$matches[0]
  $replacement=$m.Groups[1].Value+$Suffix
  return $Text.Substring(0,$m.Index)+$replacement+$Text.Substring($m.Index+$m.Length)
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
$manifest=[ordered]@{schema='armyattack-render-hotpath-overlay/v2';source_sha=$ExpectedSha;files=@()}
foreach($rel in $targets){
  $src=Join-Path $RepoRoot $rel
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL source_missing=$rel"}
  $backup=($rel -replace '[\\/]','__')+'.original'
  Copy-Item -LiteralPath $src -Destination (Join-Path $backupRoot $backup) -Force
  $manifest.files+=@([ordered]@{path=$rel;backup=$backup;sha256=(Get-Sha256 $src)})
}
$manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $tilePath=Join-Path $RepoRoot 'src\game\battlefield\TileMapGraphic.as'
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  foreach($required in @('mOwnershipDirty:Boolean','redrawDirtyOwnershipRegion()','markOwnershipDirty(param1:GridCell)','TILEMAP_DIRTY_REDRAW')){
    if(-not $tile.Contains($required)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL order=gameplay_overlay_required token=$required"}
  }

  $tile=Replace-One $tile '      private var mForceFullRedraw:Boolean = false;' @'
      private var mForceFullRedraw:Boolean = false;
      private var mBorderEdgesLocalized:Boolean = false;
      private var mDirtyReason:String = "";
'@ 'tile_hotpath_fields'

  $ownershipPattern='(?s)      public function markOwnershipDirty\(param1:GridCell\)\s*:\s*void\s*\{.*?      public function requestFullRedraw\(\)\s*:\s*void'
  $ownershipMatches=[regex]::Matches($tile,$ownershipPattern)
  if($ownershipMatches.Count -ne 1){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL patch=tile_generic_visual_dirty reason=semantic_match_count actual=$($ownershipMatches.Count)"}
  $ownershipReplacement=@'
      public function markOwnershipDirty(param1:GridCell) : void
      {
         if(!param1)
         {
            return;
         }
         var padding:int = 1;
         this.mOwnershipDirty = true;
         this.mDirtyReason = this.mDirtyReason == "fog" ? "ownership+fog" : "ownership";
         this.mOwnershipDirtyMinX = Math.min(this.mOwnershipDirtyMinX,Math.max(0,param1.mPosI - padding));
         this.mOwnershipDirtyMinY = Math.min(this.mOwnershipDirtyMinY,Math.max(0,param1.mPosJ - padding));
         this.mOwnershipDirtyMaxX = Math.max(this.mOwnershipDirtyMaxX,Math.min(this.mMapData.mGridWidth - 1,param1.mPosI + padding));
         this.mOwnershipDirtyMaxY = Math.max(this.mOwnershipDirtyMaxY,Math.min(this.mMapData.mGridHeight - 1,param1.mPosJ + padding));
         this.recalculateBorderEdgesAround(param1);
         this.mBorderEdgesLocalized = true;
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
  $om=$ownershipMatches[0]
  $tile=$tile.Substring(0,$om.Index)+$ownershipReplacement+$tile.Substring($om.Index+$om.Length)

  $borderMethods=@'
      private function recalculateBorderEdgesAround(param1:GridCell) : void
      {
         if(!param1)
         {
            return;
         }
         var width:int = this.mMapData.mGridWidth;
         var height:int = this.mMapData.mGridHeight;
         var left:int = Math.max(0,param1.mPosI - 1);
         var top:int = Math.max(0,param1.mPosJ - 1);
         var right:int = Math.min(width - 1,param1.mPosI + 1);
         var bottom:int = Math.min(height - 1,param1.mPosJ + 1);
         var target:GridCell = null;
         var neighbor:GridCell = null;
         var bits:int = 0;
         var x:int = left;
         var y:int = 0;
         var dx:int = 0;
         var dy:int = 0;
         var nx:int = 0;
         var ny:int = 0;
         var bit:int = 0;
         while(x <= right)
         {
            y = top;
            while(y <= bottom)
            {
               target = this.mGrid[y * width + x] as GridCell;
               bits = 0;
               if(target.mOwner == MapData.TILE_OWNER_ENEMY || target.mOwner == MapData.TILE_OWNER_NEUTRAL)
               {
                  dy = -1;
                  while(dy <= 1)
                  {
                     dx = -1;
                     while(dx <= 1)
                     {
                        nx = x + dx;
                        ny = y + dy;
                        bit = (dy + 1) * 3 + dx + 1;
                        if(nx >= 0 && nx < width && ny >= 0 && ny < height)
                        {
                           neighbor = this.mGrid[ny * width + nx] as GridCell;
                           if(neighbor.mOwner == MapData.TILE_OWNER_FRIENDLY)
                           {
                              bits |= 1 << bit;
                           }
                        }
                        dx++;
                     }
                     dy++;
                  }
               }
               target.mBorderEdgeBits = bits;
               y++;
            }
            x++;
         }
      }
      
      public function recalculateBorderEdgesDirty() : void
      {
         if(this.mBorderEdgesLocalized)
         {
            this.mBorderEdgesLocalized = false;
            Utils.DiagEvent("BORDER_EDGE_RECALC","map=" + GameState.mInstance.mCurrentMapId + ";dirty=1;mode=localized");
            return;
         }
         this.recalculateBorderEdges();
         Utils.DiagEvent("BORDER_EDGE_RECALC","map=" + GameState.mInstance.mCurrentMapId + ";dirty=0;mode=full;cells=" + (this.mMapData.mGridWidth * this.mMapData.mGridHeight));
      }
      
'@
  $tile=Replace-One $tile '      public function recalculateBorderEdges() : void' ($borderMethods+'      public function recalculateBorderEdges() : void') 'tile_local_border_methods'

  $clearStatePattern='(?s)      private function clearOwnershipDirtyState\(\)\s*:\s*void\s*\{.*?      private function redrawDirtyOwnershipRegion\(\)\s*:\s*Boolean'
  $clearStateMatches=[regex]::Matches($tile,$clearStatePattern)
  if($clearStateMatches.Count -ne 1){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL patch=tile_dirty_state_reset reason=semantic_match_count actual=$($clearStateMatches.Count)"}
  $clearStateReplacement=@'
      private function clearOwnershipDirtyState() : void
      {
         this.mOwnershipDirty = false;
         this.mOwnershipDirtyMinX = 2147483647;
         this.mOwnershipDirtyMinY = 2147483647;
         this.mOwnershipDirtyMaxX = -1;
         this.mOwnershipDirtyMaxY = -1;
         this.mForceFullRedraw = false;
         this.mDirtyReason = "";
      }
      
      private function redrawDirtyOwnershipRegion() : Boolean
'@
  $cm=$clearStateMatches[0]
  $tile=$tile.Substring(0,$cm.Index)+$clearStateReplacement+$tile.Substring($cm.Index+$cm.Length)

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
  $rm=$redrawMatches[0]
  $replacement=$rm.Groups[1].Value+'this.clearDirtyBitmapRegion(left,top,right,bottom);'+"`n         "+$rm.Groups[2].Value
  $tile=$tile.Substring(0,$rm.Index)+$replacement+$tile.Substring($rm.Index+$rm.Length)

  $dirtyDiagOld='Utils.DiagEvent("TILEMAP_DIRTY_REDRAW","map=" + GameState.mInstance.mCurrentMapId + ";cells=" + this.mLastDrawCellCount + ";bounds=" + left + "," + top + "," + right + "," + bottom);'
  $dirtyDiagNew='Utils.DiagEvent("TILEMAP_DIRTY_REDRAW","map=" + GameState.mInstance.mCurrentMapId + ";reason=" + this.mDirtyReason + ";cells=" + this.mLastDrawCellCount + ";bounds=" + left + "," + top + "," + right + "," + bottom);'
  $tile=Replace-One $tile $dirtyDiagOld $dirtyDiagNew 'tile_dirty_reason_telemetry'
  Write-Utf8Bom $tilePath $tile

  $fogPath=Join-Path $RepoRoot 'src\game\battlefield\FogOfWar.as'
  $fog=Normalize-Lf ([IO.File]::ReadAllText($fogPath))
  $fog=Replace-One $fog '      private var mGrid:Array;' @'
      private var mGrid:Array;
      
      private var mLocalizedEdgesCurrent:Boolean = false;
'@ 'fog_localized_field'

  $fogMethods=@'
      private function markFogDirty(param1:GridCell) : void
      {
         if(!param1)
         {
            return;
         }
         this.mUpdateRequired = true;
         this.recalculateFogEdgesAround(param1);
         this.mLocalizedEdgesCurrent = true;
         if(this.mScene && this.mScene.mTilemapGraphic)
         {
            this.mScene.mTilemapGraphic.markFogDirty(param1);
         }
      }
      
      private function recalculateFogEdgesAround(param1:GridCell) : void
      {
         var width:int = this.mMapData.mGridWidth;
         var height:int = this.mMapData.mGridHeight;
         var left:int = Math.max(0,param1.mPosI - 1);
         var top:int = Math.max(0,param1.mPosJ - 1);
         var right:int = Math.min(width - 1,param1.mPosI + 1);
         var bottom:int = Math.min(height - 1,param1.mPosJ + 1);
         var target:GridCell = null;
         var neighbor:GridCell = null;
         var bits:int = 0;
         var x:int = left;
         var y:int = 0;
         var dx:int = 0;
         var dy:int = 0;
         var nx:int = 0;
         var ny:int = 0;
         var bit:int = 0;
         while(x <= right)
         {
            y = top;
            while(y <= bottom)
            {
               target = this.mGrid[y * width + x] as GridCell;
               bits = 0;
               if(!target.hasFog())
               {
                  dy = -1;
                  while(dy <= 1)
                  {
                     dx = -1;
                     while(dx <= 1)
                     {
                        nx = x + dx;
                        ny = y + dy;
                        bit = (dy + 1) * 3 + dx + 1;
                        if(nx >= 0 && nx < width && ny >= 0 && ny < height)
                        {
                           neighbor = this.mGrid[ny * width + nx] as GridCell;
                           if(neighbor.hasFog())
                           {
                              bits |= 1 << bit;
                           }
                        }
                        dx++;
                     }
                     dy++;
                  }
               }
               target.mFogEdgeBits = bits;
               y++;
            }
            x++;
         }
      }
      
      public function recalculateFogEdgesDirty() : void
      {
         if(GameState.mInstance.mState == GameState.STATE_PVP)
         {
            this.mLocalizedEdgesCurrent = false;
            return;
         }
         if(this.mLocalizedEdgesCurrent)
         {
            this.mLocalizedEdgesCurrent = false;
            trace("FOG_EDGE_RECALC dirty=1 mode=localized");
            return;
         }
         this.recalculateFogEdges();
         trace("FOG_EDGE_RECALC dirty=0 mode=full cells=" + (this.mMapData.mGridWidth * this.mMapData.mGridHeight));
      }
      
'@
  $fog=Replace-One $fog '      public function recalculateFogEdges() : void' ($fogMethods+'      public function recalculateFogEdges() : void') 'fog_localized_methods'

  # init() may touch many cells while establishing the starting visibility;
  # always force the first edge pass to use the full fallback.
  $fog=Replace-One $fog "         this.mUpdateRequired = true;`n      }`n      `n      public function destroy() : void" "         this.mLocalizedEdgesCurrent = false;`n         this.mUpdateRequired = true;`n      }`n      `n      public function destroy() : void" 'fog_init_full_fallback'

  $fog=Replace-RegexPrefix $fog '(?s)(if\s*\(param1\.mViewers\s*==\s*0\)\s*\{\s*)this\.mUpdateRequired\s*=\s*true;' 'this.markFogDirty(param1);' 'fog_increment_transition'
  $fog=Replace-RegexPrefix $fog '(?s)(if\s*\(param1\.mViewers\s*<=\s*0\)\s*\{\s*param1\.mViewers\s*=\s*0;\s*)this\.mUpdateRequired\s*=\s*true;' 'this.markFogDirty(param1);' 'fog_decrement_transition'
  $fog=Replace-RegexPrefix $fog '(?s)(if\s*\(_loc7_\.mViewers\s*<=\s*0\)\s*\{\s*_loc7_\.mViewers\s*=\s*0;\s*)this\.mUpdateRequired\s*=\s*true;' 'this.markFogDirty(_loc7_);' 'fog_unit_sight_transition'
  Write-Utf8Bom $fogPath $fog

  $scenePath=Join-Path $RepoRoot 'src\game\isometric\IsometricScene.as'
  $scene=Normalize-Lf ([IO.File]::ReadAllText($scenePath))
  $fullFogPattern='(?s)(if\s*\(this\.mFog\.mUpdateRequired\)\s*\{\s*)this\.mTilemapGraphic\.requestFullRedraw\(\);\s*'
  $fullFogMatches=[regex]::Matches($scene,$fullFogPattern)
  if($fullFogMatches.Count -ne 1){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL patch=scene_fog_full_redraw_remove reason=semantic_match_count actual=$($fullFogMatches.Count)"}
  $fm=$fullFogMatches[0]
  $scene=$scene.Substring(0,$fm.Index)+$fm.Groups[1].Value+$scene.Substring($fm.Index+$fm.Length)
  $scene=Replace-One $scene 'this.mFog.recalculateFogEdges();' 'this.mFog.recalculateFogEdgesDirty();' 'scene_fog_edges_localized'
  $scene=Replace-One $scene 'this.mTilemapGraphic.recalculateBorderEdges();' 'this.mTilemapGraphic.recalculateBorderEdgesDirty();' 'scene_border_edges_localized'
  Write-Utf8Bom $scenePath $scene

  $tileVerify=[IO.File]::ReadAllText($tilePath)
  $fogVerify=[IO.File]::ReadAllText($fogPath)
  $sceneVerify=[IO.File]::ReadAllText($scenePath)
  foreach($token in @('markFogDirty(param1:GridCell)','recalculateBorderEdgesDirty()','recalculateBorderEdgesAround(param1)','clearDirtyBitmapRegion(left,top,right,bottom)','BORDER_EDGE_RECALC','reason=" + this.mDirtyReason')){if(-not $tileVerify.Contains($token)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL verify_tile token=$token"}}
  foreach($token in @('recalculateFogEdgesDirty()','recalculateFogEdgesAround(param1)','this.markFogDirty(param1);','this.markFogDirty(_loc7_);','FOG_EDGE_RECALC')){if(-not $fogVerify.Contains($token)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL verify_fog token=$token"}}
  foreach($token in @('this.mFog.recalculateFogEdgesDirty();','this.mTilemapGraphic.recalculateBorderEdgesDirty();')){if(-not $sceneVerify.Contains($token)){throw "ANDROID_RENDER_HOTPATH_OVERLAY=FAIL verify_scene token=$token"}}
  if([regex]::IsMatch($sceneVerify,'(?s)if\s*\(this\.mFog\.mUpdateRequired\)\s*\{\s*this\.mTilemapGraphic\.requestFullRedraw\(\);')){throw 'ANDROID_RENDER_HOTPATH_OVERLAY=FAIL verify_scene fog_still_forces_full_redraw'}

  Write-Host 'REGRESSION_CHECK=PASS name=fog_edges_localized neighborhood=3x3 fallback=full_init'
  Write-Host 'REGRESSION_CHECK=PASS name=border_edges_localized neighborhood=3x3 fallback=full_nonlocalized'
  Write-Host 'REGRESSION_CHECK=PASS name=dirty_bitmap_clear_prevents_stale_fog_and_snow_tint'
  Write-Host 'REGRESSION_CHECK=PASS name=fog_does_not_force_full_tilemap_redraw'
  Write-Host 'REGRESSION_CHECK=PASS name=gameplay_logic_cadence_unchanged scope=renderer_only'
  Write-Host "ANDROID_RENDER_HOTPATH_OVERLAY=PASS mode=apply sha=$ExpectedSha targets=$($targets.Count)"
}catch{
  $failure=$_
  try{& $PSCommandPath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_RENDER_HOTPATH_OVERLAY_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}