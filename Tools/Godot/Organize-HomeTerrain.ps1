param(
  [Parameter(Mandatory=$true)][string]$Checkout,
  [Parameter(Mandatory=$true)][string]$ExtractionRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [Parameter(Mandatory=$true)][string]$OutputRoot
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
function Extract-JsonObject {
  param([string]$Text,[string]$PropertyName)
  $needle='"'+$PropertyName+'"'
  $p=$Text.IndexOf($needle,[StringComparison]::Ordinal)
  if($p -lt 0){throw "JSON_EXTRACT=FAIL property_missing=$PropertyName"}
  $colon=$Text.IndexOf(':',$p+$needle.Length)
  if($colon -lt 0){throw "JSON_EXTRACT=FAIL colon_missing=$PropertyName"}
  $start=$Text.IndexOf('{',$colon+1)
  if($start -lt 0){throw "JSON_EXTRACT=FAIL object_start_missing=$PropertyName"}
  $depth=0;$inString=$false;$escape=$false
  for($i=$start;$i -lt $Text.Length;$i++){
    $c=$Text[$i]
    if($inString){
      if($escape){$escape=$false;continue}
      if($c -eq '\'){$escape=$true;continue}
      if($c -eq '"'){$inString=$false}
      continue
    }
    if($c -eq '"'){$inString=$true;continue}
    if($c -eq '{'){$depth++}
    elseif($c -eq '}'){
      $depth--
      if($depth -eq 0){return $Text.Substring($start,$i-$start+1)}
    }
  }
  throw "JSON_EXTRACT=FAIL unterminated=$PropertyName"
}
function Category-ForDescription {
  param([string]$Description)
  if($Description -match '^Grasslands'){return 'base'}
  if($Description -match '^Rock_'){return 'overlays/rocks'}
  if($Description -match '^Hill_'){return 'overlays/hills'}
  if($Description -match '^Bank_'){return 'overlays/banks'}
  if($Description -match '^Misc_'){return 'overlays/misc'}
  if($Description -match '^Forest_'){return 'overlays/forest'}
  if($Description -match '^Pond_'){return 'overlays/ponds'}
  if($Description -eq 'River'){return 'overlays/river'}
  if($Description -match '^Railroad_'){return 'overlays/railroad'}
  if($Description -match '^Mountain'){return 'mountains'}
  if($Description -match '^Shore_'){return 'coast'}
  if($Description -match '^Weapon_Wreck'){return 'overlays/wrecks'}
  if($Description -eq 'Water'){return 'water'}
  return 'misc'
}
function Link-Or-Copy {
  param([string]$Source,[string]$Destination)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination)|Out-Null
  if(Test-Path -LiteralPath $Destination){return 'EXISTS'}
  try{
    New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop|Out-Null
    return 'HARDLINK'
  }catch{
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return 'COPY'
  }
}
function Safe-Name([string]$s){
  $x=$s -replace '[^A-Za-z0-9_.-]+','_'
  if($x.Length -gt 120){$x=$x.Substring(0,120)}
  return $x.Trim('_')
}

$checkout=(Resolve-Path -LiteralPath $Checkout).Path
$head=(& $GitPath -C $checkout rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $head -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$head"}
Write-Host "EXACT_HEAD=PASS sha=$head"

$manifestPath=Join-Path $ExtractionRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw "ORGANIZE_PRECHECK=FAIL extraction_manifest_missing=$manifestPath"}
$m=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
if([string]$m.source_sha -ne $ExpectedSha){throw "ORGANIZE_PRECHECK=FAIL source_sha expected=$ExpectedSha actual=$($m.source_sha)"}
if([int]$m.export.curated_png -lt 1){throw 'ORGANIZE_PRECHECK=FAIL no_curated_png'}
$originalRoot=Join-Path $ExtractionRoot 'original'
$trimmedRoot=Join-Path $ExtractionRoot 'trimmed'
if(-not(Test-Path -LiteralPath $originalRoot -PathType Container)){throw 'ORGANIZE_PRECHECK=FAIL original_missing'}
Write-Host "ORGANIZE_PRECHECK=PASS curated_png=$($m.export.curated_png)"

$configPath=Join-Path $checkout 'src\config\army_config_base.json'
$configText=Get-Content -LiteralPath $configPath -Raw
$tileJson=Extract-JsonObject -Text $configText -PropertyName 'TileType'
$tileType=$tileJson|ConvertFrom-Json
$mapPath=Join-Path $checkout 'src\config\tile_map.csv'
$used=New-Object 'System.Collections.Generic.HashSet[int]'
foreach($line in Get-Content -LiteralPath $mapPath){
  foreach($part in $line.Split(',')){
    $n=0
    if([int]::TryParse($part.Trim(),[ref]$n)){[void]$used.Add($n)}
  }
}
$homeIds=@($used|Sort-Object|Where-Object{$_ -ge 0 -and $_ -lt 100})
Write-Host "HOME_TILE_IDS=PASS count=$($homeIds.Count) ids=$($homeIds -join ',')"

$spriteRows=@($m.sprites)
$bySymbol=@{}
foreach($row in $spriteRows){
  $name=[IO.Path]::GetFileNameWithoutExtension([string]$row.source_relative)
  if(-not $name){continue}
  if($name -match '(Bg_[A-Za-z0-9_]+)'){
    $symbol=$Matches[1]
    if(-not $bySymbol.ContainsKey($symbol)){$bySymbol[$symbol]=New-Object System.Collections.ArrayList}
    [void]$bySymbol[$symbol].Add($row)
  }
}
if($bySymbol.Count -lt 1){throw 'ORGANIZE_DISCOVERY=FAIL no_symbol_index'}
Write-Host "ORGANIZE_DISCOVERY=PASS symbol_index=$($bySymbol.Count)"

$registrationPath=Join-Path $ExtractionRoot 'registration\swf-terrain-registration.json'
$regIndex=@{}
if(Test-Path -LiteralPath $registrationPath -PathType Leaf){
  $reg=Get-Content -LiteralPath $registrationPath -Raw|ConvertFrom-Json
  foreach($r in @($reg.summary)){
    foreach($sym in ([string]$r.symbols).Split('|')){
      if($sym){$regIndex[$sym]=$r}
    }
  }
  Write-Host "REGISTRATION_INDEX=PASS symbols=$($regIndex.Count)"
}else{
  Write-Host 'REGISTRATION_INDEX=SKIPPED report_missing=true'
}

if(Test-Path -LiteralPath $OutputRoot){Remove-Item -LiteralPath $OutputRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $OutputRoot|Out-Null
$sourceView=Join-Path $OutputRoot 'source'
$trimView=Join-Path $OutputRoot 'trimmed'
$records=New-Object System.Collections.ArrayList
$missing=New-Object System.Collections.ArrayList
$linked=0;$copied=0;$reused=0

foreach($id in $homeIds){
  $prop=$tileType.PSObject.Properties[[string]$id]
  if($null -eq $prop){[void]$missing.Add([ordered]@{tile_id=$id;reason='TileType row missing'});continue}
  $row=$prop.Value
  $desc=[string]$row.Description
  $category=Category-ForDescription $desc
  foreach($field in @('GraphicsFriendly','GraphicsEnemy','OverlaysFriendly','OverlaysEnemy')){
    $value=[string]$row.$field
    if([string]::IsNullOrWhiteSpace($value)){continue}
    $side=if($field -match 'Enemy'){'enemy'}else{'friendly'}
    $role=if($field -match '^Overlays'){'overlay'}else{'base'}
    $resources=@($value.Split(',')|ForEach-Object{$_.Trim()}|Where-Object{$_})
    $variant=0
    foreach($resource in $resources){
      $variant++
      $symbol=($resource -split '/')[-1]
      $matches=@()
      if($bySymbol.ContainsKey($symbol)){$matches=@($bySymbol[$symbol])}
      if($matches.Count -eq 0){
        [void]$missing.Add([ordered]@{tile_id=$id;description=$desc;field=$field;resource=$resource;symbol=$symbol;reason='exported PNG not found'})
        continue
      }
      $seq=0
      foreach($sr in $matches){
        $seq++
        $src=Join-Path $ExtractionRoot ([string]$sr.original_relative).Replace('/','\')
        if(-not(Test-Path -LiteralPath $src -PathType Leaf)){continue}
        $base=[IO.Path]::GetFileName($src)
        $stem=('tile_{0:d3}__{1}__{2}__v{3:d2}__s{4:d2}__{5}' -f $id,(Safe-Name $desc),$side,$variant,$seq,$base)
        $dest=Join-Path $sourceView (Join-Path $category (Join-Path $side $stem))
        $mode=Link-Or-Copy -Source $src -Destination $dest
        if($mode -eq 'HARDLINK'){$linked++}elseif($mode -eq 'COPY'){$copied++}else{$reused++}
        $trimDest=$null;$trimMode=$null
        if($sr.trimmed_relative){
          $tsrc=Join-Path $ExtractionRoot ([string]$sr.trimmed_relative).Replace('/','\')
          if(Test-Path -LiteralPath $tsrc -PathType Leaf){
            $tstem=[IO.Path]::GetFileName($tsrc)
            $tdest=Join-Path $trimView (Join-Path $category (Join-Path $side ('tile_{0:d3}__{1}__{2}__v{3:d2}__s{4:d2}__{5}' -f $id,(Safe-Name $desc),$side,$variant,$seq,$tstem)))
            $trimMode=Link-Or-Copy -Source $tsrc -Destination $tdest
            $trimDest=$tdest.Substring($OutputRoot.Length).TrimStart('\').Replace('\','/')
          }
        }
        $regRow=$null
        if($regIndex.ContainsKey($symbol)){$regRow=$regIndex[$symbol]}
        [void]$records.Add([ordered]@{
          tile_id=$id;description=$desc;category=$category;field=$field;side=$side;role=$role;variant=$variant
          resource=$resource;symbol=$symbol
          original_source=[string]$sr.original_relative
          organized_source=$dest.Substring($OutputRoot.Length).TrimStart('\').Replace('\','/')
          trimmed_source=$trimDest
          canvas_width=[int]$sr.canvas_width;canvas_height=[int]$sr.canvas_height
          visible_width=[int]$sr.visible_width;visible_height=[int]$sr.visible_height
          crop_left=[int]$sr.crop_left;crop_top=[int]$sr.crop_top
          source_sha256=[string]$sr.original_sha256
          identical_to=[string]$sr.identical_to
          registration=if($regRow){[ordered]@{
            define_sprite_found=[bool]$regRow.define_sprite_found
            place_objects=[int]$regRow.place_objects;matrix_records=[int]$regRow.matrix_records;bounds_records=[int]$regRow.bounds_records
            tx_min_raw=$regRow.tx_min_raw;tx_max_raw=$regRow.tx_max_raw;ty_min_raw=$regRow.ty_min_raw;ty_max_raw=$regRow.ty_max_raw
          }}else{$null}
        })
      }
    }
  }
}

# Keep currently-unmapped candidates in a read-only index instead of mixing them
# into Home's proven TileType mapping.
$mappedSource=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($r in $records){[void]$mappedSource.Add([string]$r.original_source)}
$unmapped=@($spriteRows|Where-Object{-not $mappedSource.Contains([string]$_.original_relative)}|ForEach-Object{
  [ordered]@{
    original_source=[string]$_.original_relative;canvas_width=[int]$_.canvas_width;canvas_height=[int]$_.canvas_height
    visible_width=[int]$_.visible_width;visible_height=[int]$_.visible_height;crop_left=[int]$_.crop_left;crop_top=[int]$_.crop_top
    sha256=[string]$_.original_sha256
  }
})

$catalog=[ordered]@{
  schema='armyattack-godot-home-catalog/v1';status='PASS';source_sha=$ExpectedSha
  logical_grid=[ordered]@{cell_width=96;cell_height=96;note='visual PNG dimensions may differ; keep recorded offsets/registration'}
  source_manifest=$manifestPath;registration_report=if(Test-Path -LiteralPath $registrationPath){$registrationPath}else{$null}
  home_tile_ids=$homeIds;mapped_records=$records.Count;missing_records=$missing.Count;unmapped_candidates=$unmapped.Count
  storage=[ordered]@{hardlinks=$linked;copies=$copied;existing=$reused}
  records=@($records);missing=@($missing);unmapped=@($unmapped)
}
$catalogPath=Join-Path $OutputRoot 'catalog.json'
$catalog|ConvertTo-Json -Depth 14|Set-Content -LiteralPath $catalogPath -Encoding UTF8
$csvOut=Join-Path $OutputRoot 'catalog.csv'
@($records|ForEach-Object{[pscustomobject]@{
 tile_id=$_.tile_id;description=$_.description;category=$_.category;side=$_.side;role=$_.role;variant=$_.variant
 symbol=$_.symbol;organized_source=$_.organized_source;trimmed_source=$_.trimmed_source
 canvas_width=$_.canvas_width;canvas_height=$_.canvas_height;visible_width=$_.visible_width;visible_height=$_.visible_height
 crop_left=$_.crop_left;crop_top=$_.crop_top;source_sha256=$_.source_sha256
}})|Export-Csv -LiteralPath $csvOut -NoTypeInformation -Encoding UTF8

$readme=@"
Army Attack Home terrain - organized Godot view

Logical cell: 96 x 96.
Do not resize PNGs to the logical cell.
source/ keeps original FFDec canvas.
trimmed/ keeps optional alpha-cropped PNGs while catalog.json preserves crop_left/crop_top.
Folder classification is derived from TileType + tile_map.csv, not manual guessing.
Missing references stay in catalog.json; currently-unmapped curated sprites are indexed but not mixed into proven Home categories.
"@
$readme|Set-Content -LiteralPath (Join-Path $OutputRoot 'README.txt') -Encoding UTF8
$catHash=Get-Sha256Hex -Path $catalogPath
Write-Host "HOME_ASSET_ORGANIZE=PASS mapped=$($records.Count) missing=$($missing.Count) unmapped=$($unmapped.Count) hardlinks=$linked copies=$copied catalog_sha256=$catHash"
Write-Host "HOME_ASSET_ROOT=$OutputRoot"
Write-Host "HOME_ASSET_CATALOG=$catalogPath"
