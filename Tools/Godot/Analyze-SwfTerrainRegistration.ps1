param(
  [Parameter(Mandatory=$true)][string]$Checkout,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [Parameter(Mandatory=$true)][string]$OutputRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Get-Attrs([Xml.XmlReader]$r){
  $h=[ordered]@{}
  if($r.HasAttributes){
    while($r.MoveToNextAttribute()){$h[$r.Name]=[string]$r.Value}
    [void]$r.MoveToElement()
  }
  return $h
}
function Get-IdFromAttrs($attrs){
  foreach($name in @('characterId','tagId','spriteId','character','id','objectId')){
    if($attrs.Contains($name)){
      $n=0
      if([int]::TryParse([string]$attrs[$name],[ref]$n)){return $n}
    }
  }
  foreach($k in $attrs.Keys){
    if($k -match '(?i)(character|tag|sprite)?id$'){
      $n=0
      if([int]::TryParse([string]$attrs[$k],[ref]$n)){return $n}
    }
  }
  return $null
}
function Try-Num([string]$s,[ref]$out){
  $v=0.0
  if([double]::TryParse($s,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$v)){
    $out.Value=$v;return $true
  }
  return $false
}
$checkout=(Resolve-Path -LiteralPath $Checkout).Path
$head=(& $GitPath -C $checkout rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $head -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$head"}
Write-Host "EXACT_HEAD=PASS sha=$head"

$cache=Join-Path $AndroidBuildRoot 'Repositories\code-army-client\.work\swf-extracted\23.2'
$manifestPath=Join-Path $cache 'manifest.json'
$xmlPath=Join-Path $cache 'raw\swf.xml'
if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw "SWF_XML_PRECHECK=FAIL manifest_missing=$manifestPath"}
if(-not(Test-Path -LiteralPath $xmlPath -PathType Leaf)){throw "SWF_XML_PRECHECK=FAIL xml_missing=$xmlPath"}
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
if([string]$manifest.source.sha256 -ne '99a7e8c219610eabbe97aee74228d52ded1532b4c2d4310432d15082b2ff11c4'){throw 'SWF_XML_PRECHECK=FAIL source_sha'}
Write-Host "SWF_XML_PRECHECK=PASS xml=$xmlPath bytes=$((Get-Item $xmlPath).Length) extracted_from_sha=$($manifest.repository_head)"

$tileSource=Join-Path $checkout 'src\game\battlefield\TileMapGraphic.as'
$text=Get-Content -LiteralPath $tileSource -Raw
$symbols=@([regex]::Matches($text,'"swf/[^"]+/(Bg_[A-Za-z0-9_]+)"')|ForEach-Object{$_.Groups[1].Value}|Sort-Object -Unique)
if($symbols.Count -lt 1){throw 'TERRAIN_SYMBOLS=FAIL no_symbols_from_TileMapGraphic'}
$wanted=@{}
foreach($s in $symbols){$wanted[$s]=$true}
Write-Host "TERRAIN_SYMBOLS=PASS referenced_symbols=$($symbols.Count)"

# Pass 1: discover SymbolClass-like rows and generic terrain references in FFDec XML.
$settings=New-Object Xml.XmlReaderSettings
$settings.IgnoreComments=$true;$settings.IgnoreWhitespace=$true;$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
$r=[Xml.XmlReader]::Create($xmlPath,$settings)
$symbolToId=@{}
$idToSymbols=@{}
$sampleRefs=New-Object System.Collections.ArrayList
$elementCounts=@{}
try{
  while($r.Read()){
    if($r.NodeType -ne [Xml.XmlNodeType]::Element){continue}
    $name=$r.Name
    if(-not $elementCounts.ContainsKey($name)){$elementCounts[$name]=0}
    $elementCounts[$name]++
    $attrs=Get-Attrs $r
    $values=@($attrs.Values)
    $matched=$null
    foreach($v in $values){
      if($wanted.ContainsKey([string]$v)){$matched=[string]$v;break}
      $m=[regex]::Match([string]$v,'(?i)(Bg_[A-Za-z0-9_]+)')
      if($m.Success -and $wanted.ContainsKey($m.Groups[1].Value)){$matched=$m.Groups[1].Value;break}
    }
    if($matched){
      $id=Get-IdFromAttrs $attrs
      if($null -ne $id){
        $symbolToId[$matched]=[int]$id
        if(-not $idToSymbols.ContainsKey([int]$id)){$idToSymbols[[int]$id]=New-Object System.Collections.ArrayList}
        if(-not($idToSymbols[[int]$id] -contains $matched)){[void]$idToSymbols[[int]$id].Add($matched)}
      }
      if($sampleRefs.Count -lt 30){[void]$sampleRefs.Add([ordered]@{element=$name;attrs=$attrs;matched_symbol=$matched;id=$id})}
    }
  }
}finally{$r.Dispose()}
Write-Host "SYMBOL_CLASS_SCAN=PASS mapped=$($symbolToId.Count) expected=$($symbols.Count)"
foreach($row in @($sampleRefs|Select-Object -First 8)){Write-Host ("SYMBOL_SAMPLE="+($row|ConvertTo-Json -Compress -Depth 4))}

$targetIds=@($idToSymbols.Keys)
if($targetIds.Count -eq 0){
  $diag=[ordered]@{status='FAIL';reason='no_terrain_symbol_ids';expected_symbols=$symbols;element_counts=$elementCounts;sample_refs=@($sampleRefs)}
  New-Item -ItemType Directory -Force -Path $OutputRoot|Out-Null
  $diag|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutputRoot 'registration-diagnostics.json') -Encoding UTF8
  throw "TERRAIN_REGISTRATION=FAIL no_symbol_ids report=$(Join-Path $OutputRoot 'registration-diagnostics.json')"
}

# Pass 2: capture DefineSprite containers, child PlaceObject matrices and any explicit bounds.
$targets=@{}
foreach($id in $targetIds){
  $targets[$id]=[ordered]@{
    id=[int]$id;symbols=@($idToSymbols[$id]);define_sprite_found=$false
    define_element=$null;define_attrs=$null;place_objects=New-Object System.Collections.ArrayList
    matrices=New-Object System.Collections.ArrayList;bounds=New-Object System.Collections.ArrayList
    tx_values=New-Object System.Collections.ArrayList;ty_values=New-Object System.Collections.ArrayList
  }
}
$r=[Xml.XmlReader]::Create($xmlPath,$settings)
$activeId=$null;$activeDepth=-1
try{
  while($r.Read()){
    if($r.NodeType -eq [Xml.XmlNodeType]::Element){
      $attrs=Get-Attrs $r
      $type=''
      if($attrs.Contains('type')){$type=[string]$attrs['type']}
      $id=Get-IdFromAttrs $attrs
      if($null -eq $activeId -and $null -ne $id -and $targets.ContainsKey([int]$id) -and (($r.Name+$type) -match '(?i)DefineSprite')){
        $activeId=[int]$id;$activeDepth=$r.Depth
        $t=$targets[$activeId];$t.define_sprite_found=$true;$t.define_element=$r.Name;$t.define_attrs=$attrs
      }
      if($null -ne $activeId){
        $t=$targets[$activeId]
        $kind=$r.Name+' '+$type
        if($kind -match '(?i)PlaceObject'){
          if($t.place_objects.Count -lt 200){[void]$t.place_objects.Add([ordered]@{depth=$r.Depth;element=$r.Name;attrs=$attrs})}
        }
        $matrixAttrs=[ordered]@{}
        $boundAttrs=[ordered]@{}
        foreach($k in $attrs.Keys){
          $v=[string]$attrs[$k]
          if($k -match '(?i)(translateX|translateY|transX|transY|scaleX|scaleY|rotateSkew0|rotateSkew1|matrix|tx|ty)$'){$matrixAttrs[$k]=$v}
          if($k -match '(?i)(xmin|xmax|ymin|ymax|xMin|xMax|yMin|yMax|left|right|top|bottom|width|height|bounds|rect)'){$boundAttrs[$k]=$v}
          $num=0.0
          if($k -match '(?i)^(translateX|transX|tx)$' -and (Try-Num $v ([ref]$num))){[void]$t.tx_values.Add($num)}
          if($k -match '(?i)^(translateY|transY|ty)$' -and (Try-Num $v ([ref]$num))){[void]$t.ty_values.Add($num)}
        }
        if($matrixAttrs.Count -gt 0 -and $t.matrices.Count -lt 300){[void]$t.matrices.Add([ordered]@{depth=$r.Depth;element=$r.Name;type=$type;attrs=$matrixAttrs})}
        if($boundAttrs.Count -gt 0 -and $t.bounds.Count -lt 300){[void]$t.bounds.Add([ordered]@{depth=$r.Depth;element=$r.Name;type=$type;attrs=$boundAttrs})}
      }
    } elseif($r.NodeType -eq [Xml.XmlNodeType]::EndElement -and $null -ne $activeId -and $r.Depth -eq $activeDepth){
      $activeId=$null;$activeDepth=-1
    }
  }
}finally{$r.Dispose()}

New-Item -ItemType Directory -Force -Path $OutputRoot|Out-Null
$summary=New-Object System.Collections.ArrayList
foreach($id in @($targets.Keys|Sort-Object)){
  $t=$targets[$id]
  $tx=@($t.tx_values);$ty=@($t.ty_values)
  $row=[ordered]@{
    id=$t.id;symbols=($t.symbols -join '|');define_sprite_found=$t.define_sprite_found
    place_objects=$t.place_objects.Count;matrix_records=$t.matrices.Count;bounds_records=$t.bounds.Count
    tx_min_raw=if($tx.Count){($tx|Measure-Object -Minimum).Minimum}else{$null}
    tx_max_raw=if($tx.Count){($tx|Measure-Object -Maximum).Maximum}else{$null}
    ty_min_raw=if($ty.Count){($ty|Measure-Object -Minimum).Minimum}else{$null}
    ty_max_raw=if($ty.Count){($ty|Measure-Object -Maximum).Maximum}else{$null}
    first_matrix=if($t.matrices.Count){$t.matrices[0]}else{$null}
    first_bounds=if($t.bounds.Count){$t.bounds[0]}else{$null}
  }
  [void]$summary.Add($row)
}
$report=[ordered]@{
  schema='armyattack-swf-registration/v1';status='PASS';repository='Valverde-101/code-army-client'
  source_sha=$ExpectedSha;swf_sha256=[string]$manifest.source.sha256
  expected_terrain_symbols=$symbols.Count;mapped_symbols=$symbolToId.Count;target_sprite_ids=$targetIds.Count
  notes=@(
    'matrix/bounds values are preserved exactly as FFDec emits them; no automatic twip-to-pixel assumption is applied',
    'DefineSprite child transforms describe Flash composition/registration, not yet the grid placement formula used by TileMapGraphic',
    'next step is correlate these values with exported PNG canvas/crop offsets and the isometric draw formulas'
  )
  samples=@($sampleRefs);summary=@($summary);details=$targets
}
$reportPath=Join-Path $OutputRoot 'swf-terrain-registration.json'
$report|ConvertTo-Json -Depth 14|Set-Content -LiteralPath $reportPath -Encoding UTF8
$csvPath=Join-Path $OutputRoot 'swf-terrain-registration.csv'
@($summary|ForEach-Object{
 [pscustomobject]@{
  id=$_.id;symbols=$_.symbols;define_sprite_found=$_.define_sprite_found;place_objects=$_.place_objects
  matrix_records=$_.matrix_records;bounds_records=$_.bounds_records
  tx_min_raw=$_.tx_min_raw;tx_max_raw=$_.tx_max_raw;ty_min_raw=$_.ty_min_raw;ty_max_raw=$_.ty_max_raw
 }
})|Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
$found=@($summary|Where-Object{$_.define_sprite_found}).Count
$withMatrix=@($summary|Where-Object{$_.matrix_records -gt 0}).Count
$withBounds=@($summary|Where-Object{$_.bounds_records -gt 0}).Count
Write-Host "TERRAIN_REGISTRATION=PASS expected_symbols=$($symbols.Count) mapped_symbols=$($symbolToId.Count) sprite_ids=$($targetIds.Count) define_sprite_found=$found with_matrix=$withMatrix with_bounds=$withBounds"
Write-Host "REGISTRATION_REPORT=PASS json=$reportPath csv=$csvPath"
@($summary|Where-Object{$_.define_sprite_found}|Select-Object -First 12)|ForEach-Object{Write-Host ("REGISTRATION_SAMPLE="+($_|ConvertTo-Json -Compress -Depth 6))}
