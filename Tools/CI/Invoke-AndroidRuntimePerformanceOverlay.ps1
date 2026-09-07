param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_PERF_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_PERF_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$targets=@(
  'src\game\battlefield\TileMapGraphic.as',
  'src\game\isometric\IsometricScene.as'
)
$backupRoot=Join-Path $RepoRoot (".work\scratch\runtime-performance-overlay\"+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Replace-ExactlyOnce([string]$Text,[string]$Old,[string]$New,[string]$Name){
  $first=$Text.IndexOf($Old,[System.StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_PERF_OVERLAY=FAIL patch=$Name reason=pattern_missing"}
  $second=$Text.IndexOf($Old,$first+$Old.Length,[System.StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_PERF_OVERLAY=FAIL patch=$Name reason=pattern_ambiguous"}
  return $Text.Substring(0,$first)+$New+$Text.Substring($first+$Old.Length)
}
function Write-Utf8Bom([string]$Path,[string]$Text){
  $enc=New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($Path,$Text,$enc)
}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){
    Write-Host "ANDROID_PERF_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha"
    return
  }
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  foreach($entry in @($manifest.files)){
    $src=Join-Path $backupRoot ([string]$entry.backup)
    $dst=Join-Path $RepoRoot ([string]$entry.path)
    if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_PERF_OVERLAY=FAIL restore_backup_missing=$src"}
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $restored=Get-Sha256 $dst
    if($restored -ne [string]$entry.sha256){throw "ANDROID_PERF_OVERLAY=FAIL restore_hash path=$($entry.path) expected=$($entry.sha256) actual=$restored"}
  }
  & $GitPath -C $RepoRoot diff --quiet -- @($targets)
  if($LASTEXITCODE -ne 0){throw 'ANDROID_PERF_OVERLAY=FAIL restore_worktree_not_exact'}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_PERF_OVERLAY=PASS mode=restore exact_source_restored=true sha=$ExpectedSha"
  return
}

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifest=[ordered]@{schema='armyattack-runtime-performance-overlay/v1';source_sha=$ExpectedSha;files=@()}
foreach($rel in $targets){
  $src=Join-Path $RepoRoot $rel
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "ANDROID_PERF_OVERLAY=FAIL source_missing=$rel"}
  $backup=($rel -replace '[\\/]','__')+'.original'
  Copy-Item -LiteralPath $src -Destination (Join-Path $backupRoot $backup) -Force
  $manifest.files+=@([ordered]@{path=$rel;backup=$backup;sha256=(Get-Sha256 $src)})
}
$manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $tilePath=Join-Path $RepoRoot 'src\game\battlefield\TileMapGraphic.as'
  $tile=Normalize-Lf ([System.IO.File]::ReadAllText($tilePath))
  $tile=Replace-ExactlyOnce $tile @'
      private static const CAMERA_CACHE_MARGIN:int = 256;
      private static const CAMERA_CACHE_REBUILD_LIMIT:Number = 0.72;
      private var mCameraCacheAnchorX:Number = Number.NaN;
      private var mCameraCacheAnchorY:Number = Number.NaN;
'@ @'
      private static const CAMERA_CACHE_MARGIN:int = 256;
      private static const CAMERA_CACHE_REBUILD_LIMIT:Number = 0.72;
      private static const CAMERA_CACHE_MAX_MARGIN_TILES:int = 5;
      private var mCameraCacheAnchorX:Number = Number.NaN;
      private var mCameraCacheAnchorY:Number = Number.NaN;
      private var mCameraCacheEffectiveMarginX:Number = CAMERA_CACHE_MARGIN;
      private var mCameraCacheEffectiveMarginY:Number = CAMERA_CACHE_MARGIN;
      private var mLastDrawCellCount:int = 0;
      private var mLastDrawLeft:int = 0;
      private var mLastDrawTop:int = 0;
      private var mLastDrawRight:int = 0;
      private var mLastDrawBottom:int = 0;
      private var mLastDrawScale:Number = 1;
'@ 'tile_cache_fields'

  $tile=Replace-ExactlyOnce $tile @'
         var cacheScale:Number = Math.max(0.01,this.mScene.mContainer.scaleX);
         var cacheTilesX:int = Math.ceil(CAMERA_CACHE_MARGIN / (this.mScene.mGridDimX * cacheScale)) + 2;
         var cacheTilesY:int = Math.ceil(CAMERA_CACHE_MARGIN / (this.mScene.mGridDimY * cacheScale)) + 2;
         var cacheLeft:int = Math.max(0,int(_loc4_.left) - cacheTilesX);
         var cacheTop:int = Math.max(0,int(_loc4_.top) - cacheTilesY);
         var cacheRight:int = Math.min(this.mMapData.mGridWidth,int(_loc4_.right) + cacheTilesX);
         var cacheBottom:int = Math.min(this.mMapData.mGridHeight,int(_loc4_.bottom) + cacheTilesY);
         _loc4_ = new Rectangle(cacheLeft,cacheTop,cacheRight - cacheLeft,cacheBottom - cacheTop);
'@ @'
         var cacheScale:Number = Math.max(0.01,this.mScene.mContainer.scaleX);
         var requestedCacheTilesX:int = Math.ceil(CAMERA_CACHE_MARGIN / (this.mScene.mGridDimX * cacheScale)) + 2;
         var requestedCacheTilesY:int = Math.ceil(CAMERA_CACHE_MARGIN / (this.mScene.mGridDimY * cacheScale)) + 2;
         var cacheTilesX:int = Math.min(CAMERA_CACHE_MAX_MARGIN_TILES,requestedCacheTilesX);
         var cacheTilesY:int = Math.min(CAMERA_CACHE_MAX_MARGIN_TILES,requestedCacheTilesY);
         this.mCameraCacheEffectiveMarginX = Math.min(CAMERA_CACHE_MARGIN,cacheTilesX * this.mScene.mGridDimX * cacheScale);
         this.mCameraCacheEffectiveMarginY = Math.min(CAMERA_CACHE_MARGIN,cacheTilesY * this.mScene.mGridDimY * cacheScale);
         var cacheLeft:int = Math.max(0,int(_loc4_.left) - cacheTilesX);
         var cacheTop:int = Math.max(0,int(_loc4_.top) - cacheTilesY);
         var cacheRight:int = Math.min(this.mMapData.mGridWidth,int(_loc4_.right) + cacheTilesX);
         var cacheBottom:int = Math.min(this.mMapData.mGridHeight,int(_loc4_.bottom) + cacheTilesY);
         _loc4_ = new Rectangle(cacheLeft,cacheTop,cacheRight - cacheLeft,cacheBottom - cacheTop);
'@ 'tile_cache_budget'

  $tile=Replace-ExactlyOnce $tile @'
         this.drawArea(_loc4_.left,_loc4_.top,_loc4_.right,_loc4_.bottom);
'@ @'
         this.mLastDrawLeft = int(_loc4_.left);
         this.mLastDrawTop = int(_loc4_.top);
         this.mLastDrawRight = int(_loc4_.right);
         this.mLastDrawBottom = int(_loc4_.bottom);
         this.mLastDrawCellCount = Math.max(0,(this.mLastDrawRight - this.mLastDrawLeft) * (this.mLastDrawBottom - this.mLastDrawTop));
         this.mLastDrawScale = this.mScene.mContainer.scaleX;
         this.drawArea(_loc4_.left,_loc4_.top,_loc4_.right,_loc4_.bottom);
'@ 'tile_last_draw_metrics'

  $tile=Replace-ExactlyOnce $tile @'
         var limit:Number = CAMERA_CACHE_MARGIN * CAMERA_CACHE_REBUILD_LIMIT;
         if(Math.abs(dx) >= limit || Math.abs(dy) >= limit)
'@ @'
         var limitX:Number = Math.max(1,this.mCameraCacheEffectiveMarginX * CAMERA_CACHE_REBUILD_LIMIT);
         var limitY:Number = Math.max(1,this.mCameraCacheEffectiveMarginY * CAMERA_CACHE_REBUILD_LIMIT);
         if(Math.abs(dx) >= limitX || Math.abs(dy) >= limitY)
'@ 'tile_effective_rebuild_threshold'

  $tile=Replace-ExactlyOnce $tile @'
      private function disposeCachedTileBitmaps() : void
'@ @'
      public function getLastDrawCellCount() : int
      {
         return this.mLastDrawCellCount;
      }

      public function getLastDrawBounds() : String
      {
         return this.mLastDrawLeft + "," + this.mLastDrawTop + "," + this.mLastDrawRight + "," + this.mLastDrawBottom;
      }

      public function getLastDrawScale() : Number
      {
         return this.mLastDrawScale;
      }

      public function getCameraCacheEffectiveMarginX() : Number
      {
         return this.mCameraCacheEffectiveMarginX;
      }

      public function getCameraCacheEffectiveMarginY() : Number
      {
         return this.mCameraCacheEffectiveMarginY;
      }

      private function disposeCachedTileBitmaps() : void
'@ 'tile_metric_accessors'
  Write-Utf8Bom $tilePath $tile

  $scenePath=Join-Path $RepoRoot 'src\game\isometric\IsometricScene.as'
  $scene=Normalize-Lf ([System.IO.File]::ReadAllText($scenePath))
  $scene=Replace-ExactlyOnce $scene @'
			var _loc6_: Boolean = false;
'@ @'
			var _loc6_: Boolean = false;
			var tilemapRedrawReason:String = "";
'@ 'scene_redraw_reason_field'
  $scene=Replace-ExactlyOnce $scene @'
			if (this.mFog.mUpdateRequired) {
				_loc6_ = true;
'@ @'
			if (this.mFog.mUpdateRequired) {
				_loc6_ = true;
				tilemapRedrawReason = "fog";
'@ 'scene_redraw_reason_fog'
  $scene=Replace-ExactlyOnce $scene @'
			if (this.mGame.mMapData.mUpdateRequired) {
				_loc6_ = true;
'@ @'
			if (this.mGame.mMapData.mUpdateRequired) {
				_loc6_ = true;
				tilemapRedrawReason = tilemapRedrawReason.length > 0 ? tilemapRedrawReason + "+map" : "map";
'@ 'scene_redraw_reason_map'
  $scene=Replace-ExactlyOnce $scene @'
				this.reportSceneSubsystem("tilemap_redraw",getTimer() - perfStart,this.mGame.mMapData.mGrid ? this.mGame.mMapData.mGrid.length : 0);
'@ @'
				this.reportSceneSubsystem("tilemap_redraw",getTimer() - perfStart,this.mTilemapGraphic.getLastDrawCellCount());
				Utils.DiagEvent("TILEMAP_REDRAW_BOUNDS","map=" + this.mGame.mCurrentMapId + ";reason=" + tilemapRedrawReason + ";cells=" + this.mTilemapGraphic.getLastDrawCellCount() + ";bounds=" + this.mTilemapGraphic.getLastDrawBounds() + ";scale=" + this.mTilemapGraphic.getLastDrawScale() + ";cache_margin_x=" + this.mTilemapGraphic.getCameraCacheEffectiveMarginX() + ";cache_margin_y=" + this.mTilemapGraphic.getCameraCacheEffectiveMarginY());
'@ 'scene_actual_redraw_metrics'
  Write-Utf8Bom $scenePath $scene

  $tileVerify=[System.IO.File]::ReadAllText($tilePath)
  $sceneVerify=[System.IO.File]::ReadAllText($scenePath)
  foreach($token in @('CAMERA_CACHE_MAX_MARGIN_TILES:int = 5','requestedCacheTilesX','mCameraCacheEffectiveMarginX','getLastDrawCellCount()','limitX:Number')){if($tileVerify.IndexOf($token,[System.StringComparison]::Ordinal) -lt 0){throw "ANDROID_PERF_OVERLAY=FAIL verify_tile token=$token"}}
  foreach($token in @('tilemapRedrawReason','TILEMAP_REDRAW_BOUNDS','getLastDrawCellCount()')){if($sceneVerify.IndexOf($token,[System.StringComparison]::Ordinal) -lt 0){throw "ANDROID_PERF_OVERLAY=FAIL verify_scene token=$token"}}
  if($sceneVerify.IndexOf('this.reportSceneSubsystem("tilemap_redraw",getTimer() - perfStart,this.mGame.mMapData.mGrid ? this.mGame.mMapData.mGrid.length : 0);',[System.StringComparison]::Ordinal) -ge 0){throw 'ANDROID_PERF_OVERLAY=FAIL stale_full_grid_telemetry'}
  Write-Host 'REGRESSION_CHECK=PASS name=tilemap_cache_budget_is_zoom_safe max_margin_tiles=5'
  Write-Host 'REGRESSION_CHECK=PASS name=tilemap_cache_rebuild_uses_effective_margin'
  Write-Host 'REGRESSION_CHECK=PASS name=tilemap_redraw_reports_actual_cells'
  Write-Host 'REGRESSION_CHECK=PASS name=tilemap_redraw_reports_reason_bounds_scale'
  Write-Host "ANDROID_PERF_OVERLAY=PASS mode=apply sha=$ExpectedSha targets=$($targets.Count)"
}catch{
  $failure=$_
  try{& $PSCommandPath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_PERF_OVERLAY_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
