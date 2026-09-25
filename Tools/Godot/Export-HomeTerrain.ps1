# Curate terrain sprites from the pinned Army Attack SWF without changing the shared checkout.
param(
 [Parameter(Mandatory=$true)][string]$Checkout,
 [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
 [Parameter(Mandatory=$true)][string]$ExpectedSha,
 [Parameter(Mandatory=$true)][string]$GitPath,
 [Parameter(Mandatory=$true)][string]$FFDecPath,
 [Parameter(Mandatory=$true)][string]$OutputRoot,
 [int]$MaxPng=1500,
 [long]$MaxBytes=157286400
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Get-Sha256Hex {
  param([Parameter(Mandatory=$true)][string]$Path)
  $stream=[IO.File]::OpenRead($Path)
  try {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
  } finally { $stream.Dispose() }
}
$swfSha='99a7e8c219610eabbe97aee74228d52ded1532b4c2d4310432d15082b2ff11c4'
$submoduleSha='306bccc7db5b1ce34dd68a3bc80093648c9224bd'
$checkout=(Resolve-Path -LiteralPath $Checkout).Path
$head=(& $GitPath -C $checkout rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $head -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$head"}
Write-Host "EXACT_HEAD=PASS sha=$head"
$sub=Join-Path $checkout 'vendor\Test_army_attack'
$subHead=(& $GitPath -C $sub rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $subHead -ne $submoduleSha){throw "SUBMODULE_PIN=FAIL expected=$submoduleSha actual=$subHead"}
$swf=Join-Path $sub 'armyattack\assets\iArmyAirOfflineSavingv23.swf'
if(-not(Test-Path -LiteralPath $swf -PathType Leaf)){throw "SWF_SOURCE=FAIL missing=$swf"}
$actualHash=Get-Sha256Hex -Path $swf
$sourceSize=(Get-Item -LiteralPath $swf).Length
if($actualHash -ne $swfSha -or $sourceSize -ne 24871956){throw "SWF_SOURCE=FAIL actual_sha256=$actualHash size=$sourceSize"}
Write-Host "SWF_SOURCE=PASS submodule=$subHead size=$sourceSize sha256=$actualHash"
$csv=Join-Path $checkout 'src\config\tile_map.csv'
if(-not(Test-Path -LiteralPath $csv -PathType Leaf)){throw 'HOME_MAP=FAIL tile_map_csv_missing'}
$csvHash=Get-Sha256Hex -Path $csv
$cache=Join-Path $AndroidBuildRoot 'Repositories\code-army-client\.work\swf-extracted\23.2'
$cacheManifest=Join-Path $cache 'manifest.json'
$cacheRows=@{}
$fromCache=$false
$exportHead=$null
$pngRoot=$null
if(Test-Path -LiteralPath $cacheManifest -PathType Leaf){
 try{
  $m=Get-Content -LiteralPath $cacheManifest -Raw | ConvertFrom-Json
  $sprites=Join-Path $cache 'sprites'
  $hashCsv=Join-Path $cache 'files.sha256.csv'
  if([string]$m.extraction_status -eq 'PASS' -and [string]$m.source.sha256 -eq $swfSha -and
     (Test-Path -LiteralPath $sprites -PathType Container) -and (Test-Path -LiteralPath $hashCsv -PathType Leaf)){
   foreach($r in @(Import-Csv -LiteralPath $hashCsv)){
    if([string]$r.path -like 'sprites/*'){$cacheRows[[string]$r.path]=$r}
   }
   $pngRoot=$sprites
   $exportHead=[string]$m.repository_head
   $fromCache=$true
   Write-Host "RAW_CACHE=PASS exported_from_sha=$exportHead hashed_sprite_rows=$($cacheRows.Count)"
  }
 }catch{Write-Host "RAW_CACHE=MISS reason=$($_.Exception.Message)";$fromCache=$false;$cacheRows=@{}}
}
if(-not $fromCache){Write-Host 'RAW_CACHE=MISS sprite_export_required=true'}
if(Test-Path -LiteralPath $OutputRoot){throw "OUTPUT_ISOLATION=FAIL already_exists=$OutputRoot"}
New-Item -ItemType Directory -Force -Path $OutputRoot|Out-Null
$original=Join-Path $OutputRoot 'original'
$trimmed=Join-Path $OutputRoot 'trimmed'
$reports=Join-Path $OutputRoot 'reports'
foreach($p in @($original,$trimmed,$reports)){New-Item -ItemType Directory -Force -Path $p|Out-Null}
if(-not $fromCache){
 $pngRoot=Join-Path $OutputRoot 'all-exported-sprites'
 New-Item -ItemType Directory -Force -Path $pngRoot|Out-Null
 if(-not(Test-Path -LiteralPath $FFDecPath -PathType Leaf)){throw "FFDEC=FAIL missing=$FFDecPath"}
 $log=Join-Path $reports 'ffdec-sprite-export.log'
 $arguments=@('-cli','-onerror','abort','-timeout','180','-exportTimeout','7200','-exportFileTimeout','300','-format','sprite:png','-export','sprite',$pngRoot,$swf)
 $response=@(& $FFDecPath @arguments 2>&1)
 $exit=$LASTEXITCODE
 $response|Set-Content -LiteralPath $log -Encoding UTF8
 if($exit -ne 0){$response|Select-Object -Last 12|ForEach-Object{Write-Host $_};throw "SWF_EXPORT=FAIL exit=$exit log=$log"}
 $exportHead=$ExpectedSha
 Write-Host "SWF_EXPORT=PASS log=$log"
}
$allPng=@(Get-ChildItem -LiteralPath $pngRoot -File -Recurse -Filter '*.png' -ErrorAction Stop)
$pattern='(?i)Bg_(?:Good|Bad|Transition|Shore|Border|Water|Fog|Cloud|[A-Za-z0-9_]*Tile)[A-Za-z0-9_]*'
$candidates=@($allPng|Where-Object{$_.FullName -match $pattern}|Sort-Object FullName)
@($allPng|Select-Object -First 40|ForEach-Object{$_.FullName.Substring($pngRoot.Length).TrimStart('\','/')}) |
 ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $reports 'filename-sample.json') -Encoding UTF8
Write-Host "SPRITE_INVENTORY=PASS exported_png=$($allPng.Count) terrain_candidates=$($candidates.Count)"
if($candidates.Count -eq 0){throw "TERRAIN_DISCOVERY=FAIL no_named_candidates sample=$(Join-Path $reports 'filename-sample.json')"}
Add-Type -AssemblyName System.Drawing
$rows=New-Object System.Collections.ArrayList
$seen=@{}
$copied=0;$bytes=0L;$duplicates=0;$truncated=$false
foreach($f in $candidates){
 if($copied -ge $MaxPng -or ($bytes+$f.Length) -gt $MaxBytes){$truncated=$true;break}
 $rel=$f.FullName.Substring($pngRoot.Length).TrimStart('\','/').Replace('\','/')
 $hash=Get-Sha256Hex -Path $f.FullName
 if($fromCache){
  $key='sprites/'+$rel
  if(-not $cacheRows.ContainsKey($key)){throw "RAW_CACHE_FILE=FAIL missing_hash_inventory=$key"}
  $item=$cacheRows[$key]
  if([long]$item.size -ne $f.Length -or [string]$item.sha256 -ne $hash){throw "RAW_CACHE_FILE=FAIL hash_mismatch=$key"}
 }
 $dest=Join-Path $original ($rel.Replace('/','\'))
 New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest)|Out-Null
 Copy-Item -LiteralPath $f.FullName -Destination $dest
 $copied++;$bytes+=$f.Length
 $img=$null;$crop=$null
 try{
  $img=New-Object System.Drawing.Bitmap($f.FullName)
  $w=$img.Width;$h=$img.Height
  $left=$w;$top=$h;$right=-1;$bottom=-1
  $state='UNCHANGED'
  $trimRel=$null;$trimHash=$null;$duplicateOf=$null
  if(([long]$w*$h) -le 1048576){
   for($y=0;$y -lt $h;$y++){
    for($x=0;$x -lt $w;$x++){
     if($img.GetPixel($x,$y).A -gt 0){
      if($x -lt $left){$left=$x}
      if($y -lt $top){$top=$y}
      if($x -gt $right){$right=$x}
      if($y -gt $bottom){$bottom=$y}
     }
    }
   }
  }else{$state='SKIPPED_LARGE_CANVAS'}
  if($right -lt 0){
   if($state -ne 'SKIPPED_LARGE_CANVAS'){$state='TRANSPARENT_OR_EMPTY';$left=0;$top=0}
   $visibleW=$w;$visibleH=$h
  }else{
   $visibleW=$right-$left+1;$visibleH=$bottom-$top+1
   if($visibleW -lt $w -or $visibleH -lt $h){
    $trimDest=Join-Path $trimmed ($rel.Replace('/','\'))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $trimDest)|Out-Null
    $crop=New-Object System.Drawing.Bitmap($visibleW,$visibleH,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g=[System.Drawing.Graphics]::FromImage($crop)
    try{
     $g.CompositingMode=[System.Drawing.Drawing2D.CompositingMode]::SourceCopy
     $g.DrawImage($img,(New-Object System.Drawing.Rectangle(0,0,$visibleW,$visibleH)),(New-Object System.Drawing.Rectangle($left,$top,$visibleW,$visibleH)),[System.Drawing.GraphicsUnit]::Pixel)
    }finally{$g.Dispose()}
    $crop.Save($trimDest,[System.Drawing.Imaging.ImageFormat]::Png)
    $trimRel='trimmed/'+$rel
    $trimHash=Get-Sha256Hex -Path $trimDest
    $state='TRIMMED_KEEP_OFFSET'
   }
  }
  $identity=if($trimHash){$trimHash}else{$hash}
  if($seen.ContainsKey($identity)){$duplicateOf=$seen[$identity];$duplicates++}else{$seen[$identity]=$rel}
  [void]$rows.Add([ordered]@{
   source_relative=$rel;original_relative='original/'+$rel
   original_size=$f.Length;original_sha256=$hash
   canvas_width=$w;canvas_height=$h;visible_width=$visibleW;visible_height=$visibleH
   crop_left=$left;crop_top=$top;crop_status=$state
   trimmed_relative=$trimRel;trimmed_sha256=$trimHash;identical_to=$duplicateOf
  })
 }finally{
  if($crop){$crop.Dispose()}
  if($img){$img.Dispose()}
 }
}
Copy-Item -LiteralPath $csv -Destination (Join-Path $OutputRoot 'tile_map_home.csv') -Force
$manifest=[ordered]@{
 schema='armyattack-godot-home-terrain/v1';repository='Valverde-101/code-army-client'
 source_sha=$ExpectedSha;runner=$env:RUNNER_NAME;run_id=$env:GITHUB_RUN_ID
 swf=[ordered]@{path='vendor/Test_army_attack/armyattack/assets/iArmyAirOfflineSavingv23.swf';sha256=$actualHash;size=$sourceSize;submodule_sha=$subHead}
 export=[ordered]@{cache=$fromCache;source_export_sha=$exportHead;total_png=$allPng.Count;terrain_candidates=$candidates.Count;curated_png=$copied;identical_png=$duplicates;truncated=$truncated;copied_bytes=$bytes}
 home_map=[ordered]@{path='tile_map_home.csv';sha256=$csvHash;tile_id_mapping_verified=$false}
 note='Original PNGs are not rescaled. If a trimmed PNG is used, preserve crop_left/crop_top relative to original SWF canvas.'
 output_root=$OutputRoot;generated_utc=[DateTime]::UtcNow.ToString('o');sprites=@($rows.ToArray())
}
$manifestPath=Join-Path $OutputRoot 'manifest.json'
$manifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifestPath -Encoding UTF8
$summary=[ordered]@{status='PASS';source_sha=$ExpectedSha;swf_sha256=$actualHash;cache=$fromCache;terrain_candidates=$candidates.Count;curated_png=$copied;identical_png=$duplicates;truncated=$truncated;original_dir=$original;trimmed_dir=$trimmed;manifest=$manifestPath}
$summary|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $reports 'summary.json') -Encoding UTF8
if($copied -eq 0){throw 'TERRAIN_CURATE=FAIL no_png_copied'}
Write-Host "TERRAIN_CURATE=PASS curated_png=$copied identical_png=$duplicates truncated=$truncated"
Write-Host "HOME_MAP=PASS csv_sha256=$csvHash tile_mapping_verified=false"
Write-Host "REPORT=PASS manifest=$manifestPath"
Write-Host "FINAL_VALIDATION=PASS scope=terrain_extraction_only source_sha=$ExpectedSha godot_import=NOT_RUN android_apk=NOT_RUN physical=NOT_RUN"
