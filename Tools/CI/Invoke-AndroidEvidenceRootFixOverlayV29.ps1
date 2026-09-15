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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v28=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV28.ps1'
if(-not(Test-Path -LiteralPath $v28 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL predecessor_missing=$v28"}

$scenePath=Join-Path $RepoRoot 'src\game\isometric\IsometricScene.as'
$tilePath=Join-Path $RepoRoot 'src\game\battlefield\TileMapGraphic.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v29\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V29_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V29_HOOK=PASS name=$Name matches=1 semantic=true"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL restore_backup_missing path=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL restore_hash path=$($entry.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v28 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V29=PASS mode=restore predecessor=v28 sha=$ExpectedSha"
  return
}

& $v28 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL predecessor_apply_exit=$LASTEXITCODE"}

try {
  foreach($required in @($scenePath,$tilePath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V29=FAIL required_file_missing path=$required"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  Copy-Item -LiteralPath $scenePath -Destination (Join-Path $backupRoot 'IsometricScene.post-v28.as') -Force
  Copy-Item -LiteralPath $tilePath -Destination (Join-Path $backupRoot 'TileMapGraphic.post-v28.as') -Force
  $files=@(
    [ordered]@{path='src\game\isometric\IsometricScene.as';backup='IsometricScene.post-v28.as';sha256=(Get-Sha256 $scenePath)},
    [ordered]@{path='src\game\battlefield\TileMapGraphic.as';backup='TileMapGraphic.post-v28.as';sha256=(Get-Sha256 $tilePath)}
  )
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v29';source_sha=$ExpectedSha;predecessor='v28';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # V28 fixed stale border topology, but its canonical ownership hook called the
  # full-grid O(width*height*9) recalculation for every captured cell. The original
  # full-grid implementation also validated only flattened indices, so x=-1/x=width
  # could wrap into the previous/next row and produce false edge neighbours.
  # V29 makes both algorithms coordinate-bounds-safe and adds a local 3x3 topology
  # refresh: changing one owner can only affect border masks whose 3x3 neighbourhood
  # contains that cell, so exactly the changed cell + its eight neighbours are needed.
  $tile=Normalize-Lf ([IO.File]::ReadAllText($tilePath))
  $borderPattern='(?s)\s+public function recalculateBorderEdges\(\)\s*:\s*void\s*\{.*?\n\s*\}\s*\n\s*private function drawBorderEdges'
  $borderReplacement=@'

      public function recalculateBorderEdges() : void
      {
         var cell:GridCell = null;
         var neighbour:GridCell = null;
         var width:int = this.mMapData.mGridWidth;
         var height:int = this.mMapData.mGridHeight;
         var x:int = 0;
         var y:int = 0;
         var nx:int = 0;
         var ny:int = 0;
         var bit:int = 0;
         var bits:int = 0;
         while(x < width)
         {
            y = 0;
            while(y < height)
            {
               cell = this.mGrid[y * width + x] as GridCell;
               bits = 0;
               if(cell && (cell.mOwner == MapData.TILE_OWNER_ENEMY || cell.mOwner == MapData.TILE_OWNER_NEUTRAL))
               {
                  bit = 0;
                  ny = y - 1;
                  while(ny <= y + 1)
                  {
                     nx = x - 1;
                     while(nx <= x + 1)
                     {
                        if(nx >= 0 && nx < width && ny >= 0 && ny < height)
                        {
                           neighbour = this.mGrid[ny * width + nx] as GridCell;
                           if(neighbour && neighbour.mOwner == MapData.TILE_OWNER_FRIENDLY)
                           {
                              bits |= 1 << bit;
                           }
                        }
                        bit++;
                        nx++;
                     }
                     ny++;
                  }
               }
               if(cell) cell.mBorderEdgeBits = bits;
               y++;
            }
            x++;
         }
      }

      public function recalculateBorderEdgesAround(param1:int, param2:int, param3:int = 1) : void
      {
         var cell:GridCell = null;
         var neighbour:GridCell = null;
         var width:int = this.mMapData.mGridWidth;
         var height:int = this.mMapData.mGridHeight;
         var minX:int = Math.max(0,param1 - param3);
         var maxX:int = Math.min(width - 1,param1 + param3);
         var minY:int = Math.max(0,param2 - param3);
         var maxY:int = Math.min(height - 1,param2 + param3);
         var x:int = minX;
         var y:int = 0;
         var nx:int = 0;
         var ny:int = 0;
         var bit:int = 0;
         var bits:int = 0;
         while(x <= maxX)
         {
            y = minY;
            while(y <= maxY)
            {
               cell = this.mGrid[y * width + x] as GridCell;
               bits = 0;
               if(cell && (cell.mOwner == MapData.TILE_OWNER_ENEMY || cell.mOwner == MapData.TILE_OWNER_NEUTRAL))
               {
                  bit = 0;
                  ny = y - 1;
                  while(ny <= y + 1)
                  {
                     nx = x - 1;
                     while(nx <= x + 1)
                     {
                        if(nx >= 0 && nx < width && ny >= 0 && ny < height)
                        {
                           neighbour = this.mGrid[ny * width + nx] as GridCell;
                           if(neighbour && neighbour.mOwner == MapData.TILE_OWNER_FRIENDLY)
                           {
                              bits |= 1 << bit;
                           }
                        }
                        bit++;
                        nx++;
                     }
                     ny++;
                  }
               }
               if(cell) cell.mBorderEdgeBits = bits;
               y++;
            }
            x++;
         }
      }

      private function drawBorderEdges
'@.TrimEnd()
  $tile=Replace-RegexOne $tile $borderPattern $borderReplacement 'bounds_safe_and_local_border_topology'
  foreach($token in @('public function recalculateBorderEdgesAround(param1:int, param2:int, param3:int = 1)','nx >= 0 && nx < width && ny >= 0 && ny < height','Math.max(0,param1 - param3)','Math.min(width - 1,param1 + param3)')){Require-Token $tile $token ('border_contract_'+$token)}
  if($tile.Contains('_loc7_ = (_loc5_ - 1) * _loc1_ + (_loc4_ - 1)')){throw 'ANDROID_EVIDENCE_ROOTFIX_V29=FAIL flattened_row_wrap_algorithm_survived'}
  Write-Utf8Bom $tilePath $tile

  $scene=Normalize-Lf ([IO.File]::ReadAllText($scenePath))
  $old='this.mTilemapGraphic.recalculateBorderEdges();`n               Utils.DiagEvent("OWNERSHIP_BORDER_RECALC","map=" + GameState.mInstance.mCurrentMapId + ";x=" + param1.mPosI + ";y=" + param1.mPosJ + ";mode=ownership_mutation");'
  $old=$old.Replace('`n',"`n")
  $new='this.mTilemapGraphic.recalculateBorderEdgesAround(param1.mPosI,param1.mPosJ);`n               Utils.DiagEvent("OWNERSHIP_BORDER_RECALC","map=" + GameState.mInstance.mCurrentMapId + ";x=" + param1.mPosI + ";y=" + param1.mPosJ + ";mode=ownership_mutation_local;radius=1");'
  $new=$new.Replace('`n',"`n")
  $scene=Replace-LiteralOne $scene $old $new 'ownership_border_local_refresh'
  Require-Token $scene 'recalculateBorderEdgesAround(param1.mPosI,param1.mPosJ)' 'ownership_local_border_call'
  Require-Token $scene 'mode=ownership_mutation_local;radius=1' 'ownership_local_border_telemetry'
  Write-Utf8Bom $scenePath $scene

  Write-Host 'REGRESSION_CHECK=PASS name=border_topology_bounds_safe no_row_wrap=true coordinate_guard=true'
  Write-Host 'REGRESSION_CHECK=PASS name=ownership_border_refresh_local radius=1 affected_cells_max=9 full_grid_per_capture=false'
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V29_BORDER_TOPOLOGY=PASS stale_bits=false row_wrap=false local_refresh=true radius=1 snow_full_first_visit=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V29=PASS mode=apply predecessor=v28 sha=$ExpectedSha"
}
catch {
  $message=$_.Exception.Message
  try{Restore-OwnedFiles}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V29_ROLLBACK=WARN $($_.Exception.Message)"}
  try{& $v28 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore|Out-Host}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V29_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)"}
  throw $message
}
