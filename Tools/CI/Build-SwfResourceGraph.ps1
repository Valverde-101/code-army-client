param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$ExpectedSha,
  [string]$OutputRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Resolve-Git([string]$Repo){
  foreach($name in @('git.exe','git')){
    $cmd=Get-Command $name -ErrorAction SilentlyContinue
    if($cmd){return $cmd.Source}
  }
  $repoParent=Split-Path -Parent $Repo
  $root=Split-Path -Parent $repoParent
  foreach($candidate in @(
    (Join-Path $root 'Tools\Git\cmd\git.exe'),
    (Join-Path $root 'PortableGit\cmd\git.exe'),
    (Join-Path $root 'AndroidBuild\Tools\Git\cmd\git.exe'),
    (Join-Path $root 'AndroidBuild\PortableGit\cmd\git.exe')
  )){if(Test-Path -LiteralPath $candidate){return $candidate}}
  throw 'SWF_RESOURCE_GRAPH=FAIL git_not_found'
}

function Get-LineNumber([string]$Text,[int]$Index){
  if($Index -le 0){return 1}
  return ([regex]::Matches($Text.Substring(0,$Index),"`n")).Count + 1
}

$repo=(Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$git=Resolve-Git $repo
$head=(& $git -C $repo rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0){throw 'SWF_RESOURCE_GRAPH=FAIL git_head'}
if($ExpectedSha -and $head -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$head"}
if(-not $OutputRoot){$OutputRoot=Join-Path $repo ".work\reports\swf-resource-graph\$head"}
New-Item -ItemType Directory -Force -Path $OutputRoot|Out-Null

$srcRoot=Join-Path $repo 'src'
if(-not(Test-Path -LiteralPath $srcRoot -PathType Container)){throw "SWF_RESOURCE_GRAPH=FAIL src_missing=$srcRoot"}
$files=@(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -ErrorAction Stop | Where-Object{$_.Extension -in @('.as','.json','.xml','.csv','.txt')})
$edges=New-Object System.Collections.Generic.List[object]
$dynamic=New-Object System.Collections.Generic.List[object]
$literalResources=New-Object System.Collections.Generic.List[object]
$symbolsByName=@{}
$resourcesByName=@{}

foreach($file in $files){
  $text=Get-Content -LiteralPath $file.FullName -Raw
  if($null -eq $text){continue}
  $rel=$file.FullName.Substring($repo.Length).TrimStart('\').Replace('\','/')

  if($file.Extension -eq '.as'){
    $staticPattern='getSWFClass\s*\(\s*([^,\r\n]+?)\s*,\s*"([^"]+)"\s*\)'
    foreach($m in [regex]::Matches($text,$staticPattern)){
      $resourceExpr=$m.Groups[1].Value.Trim()
      $symbol=$m.Groups[2].Value
      $row=[pscustomobject]@{
        consumer=$rel;line=(Get-LineNumber $text $m.Index);kind='getSWFClass_static';resource=$resourceExpr;symbol=$symbol;dynamic=$false
      }
      $edges.Add($row)
      if(-not $symbolsByName.ContainsKey($symbol)){$symbolsByName[$symbol]=New-Object System.Collections.Generic.HashSet[string]}
      [void]$symbolsByName[$symbol].Add($resourceExpr)
      if(-not $resourcesByName.ContainsKey($resourceExpr)){$resourcesByName[$resourceExpr]=0}
      $resourcesByName[$resourceExpr]=[int]$resourcesByName[$resourceExpr]+1
    }

    $allCalls=[regex]::Matches($text,'getSWFClass\s*\(([^\)]*)\)')
    foreach($m in $allCalls){
      $args=$m.Groups[1].Value
      if($args -notmatch ',\s*"[^"]+"\s*$'){
        $dynamic.Add([pscustomobject]@{consumer=$rel;line=(Get-LineNumber $text $m.Index);expression=$args.Trim()})
      }
    }
  }

  foreach($m in [regex]::Matches($text,'["''](swf/[A-Za-z0-9_./\-]+)["'']')){
    $resource=$m.Groups[1].Value
    $literalResources.Add([pscustomobject]@{consumer=$rel;line=(Get-LineNumber $text $m.Index);resource=$resource})
  }
}

$aliasCandidates=New-Object System.Collections.Generic.List[object]
foreach($symbol in ($symbolsByName.Keys|Sort-Object)){
  $owners=@($symbolsByName[$symbol])
  if($owners.Count -gt 1){
    $aliasCandidates.Add([pscustomobject]@{symbol=$symbol;resource_expressions=$owners;owner_count=$owners.Count})
  }
}

$opforEdges=@($edges|Where-Object{([string]$_.resource) -match 'units_opfor' -or ([string]$_.symbol) -match '(?i)opfor|enemy'})
$fireMissionEdges=@($edges|Where-Object{([string]$_.consumer) -match 'FireMission|PowerUp' -or ([string]$_.symbol) -match '(?i)rocket|explosion|artillery|mortar|napalm'})
$airdropEdges=@($edges|Where-Object{([string]$_.consumer) -match 'PowerUp|IsometricScene' -or ([string]$_.symbol) -match '(?i)airdrop|paratroop'})

$powerPath=Join-Path $repo 'src\game\gameElements\PowerUpObject.as'
$pvpFirePath=Join-Path $repo 'src\game\actions\PvPFireMissionAction.as'
$traceContract=[ordered]@{powerup='FAIL';firemission='FAIL'}
if(Test-Path -LiteralPath $powerPath){
  $p=Get-Content -LiteralPath $powerPath -Raw
  if($p.Contains('TRACE_BEGIN') -and $p.Contains('parent_trace=') -and $p.Contains('new PvPFireMissionAction(targetCell,param1.mPowerUpFireMissionItem,param1.mFireMissionAnimation,fireTrace)')){$traceContract.powerup='PASS'}
}
if(Test-Path -LiteralPath $pvpFirePath){
  $p=Get-Content -LiteralPath $pvpFirePath -Raw
  if($p.Contains('param4:String = null') -and $p.Contains('PVP_FIREMISSION_DAMAGE') -and $p.Contains('TRACE_END')){$traceContract.firemission='PASS'}
}
if($traceContract.powerup -ne 'PASS' -or $traceContract.firemission -ne 'PASS'){
  throw "SWF_RESOURCE_GRAPH=FAIL trace_contract powerup=$($traceContract.powerup) firemission=$($traceContract.firemission)"
}

$report=[ordered]@{
  schema='armyattack-swf-resource-graph/v1'
  repository='Valverde-101/code-army-client'
  tested_sha=$head
  generated_utc=[DateTime]::UtcNow.ToString('o')
  files_scanned=$files.Count
  static_symbol_edges=$edges.Count
  dynamic_symbol_calls=$dynamic.Count
  literal_swf_references=$literalResources.Count
  alias_collision_candidates=$aliasCandidates.Count
  trace_contract=$traceContract
  focused_counts=[ordered]@{opfor=$opforEdges.Count;firemission=$fireMissionEdges.Count;airdrop=$airdropEdges.Count}
  edges=@($edges)
  dynamic_calls=@($dynamic|Select-Object -First 500)
  literal_resources=@($literalResources|Select-Object -First 1000)
  alias_candidates=@($aliasCandidates)
  focused=[ordered]@{opfor=@($opforEdges);firemission=@($fireMissionEdges);airdrop=@($airdropEdges)}
  interpretation=@(
    'Static edges map ActionScript consumers to logical SWF resource expressions and literal symbols.',
    'Dynamic calls are audit candidates because their symbol/resource identity can only be proven at runtime.',
    'Alias candidates are not automatically defects; correlate them with SWF_EMBEDDED_SYMBOL_COLLISION and SWF_CLASS_IDENTITY_MISMATCH runtime events.',
    'OPFOR, FireMission and airdrop subsets are emitted explicitly because they are historically high-risk Army Attack paths.'
  )
}

$json=Join-Path $OutputRoot 'SWF-RESOURCE-GRAPH.json'
$csv=Join-Path $OutputRoot 'SWF-RESOURCE-GRAPH-edges.csv'
$md=Join-Path $OutputRoot 'SWF-RESOURCE-GRAPH.md'
$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $json -Encoding UTF8
$edges|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
$lines=@(
  '# Army Attack SWF resource graph',
  '',
  "TESTED_SHA: $head",
  "Files scanned: $($files.Count)",
  "Static symbol edges: $($edges.Count)",
  "Dynamic getSWFClass calls: $($dynamic.Count)",
  "Literal swf/ references: $($literalResources.Count)",
  "Alias candidates: $($aliasCandidates.Count)",
  "Focused edges: OPFOR=$($opforEdges.Count), FireMission=$($fireMissionEdges.Count), Airdrop=$($airdropEdges.Count)",
  "Trace contract: PowerUp=$($traceContract.powerup), FireMission=$($traceContract.firemission)",
  '',
  'Use this graph together with runtime-diagnostics.json / correlated-diagnostics.json. Static presence alone is not proof that a symbol resolves in the correct ApplicationDomain.'
)
$lines|Set-Content -LiteralPath $md -Encoding UTF8
Write-Host "SWF_RESOURCE_GRAPH=PASS sha=$head files=$($files.Count) static_edges=$($edges.Count) dynamic_calls=$($dynamic.Count) alias_candidates=$($aliasCandidates.Count) opfor=$($opforEdges.Count) firemission=$($fireMissionEdges.Count) airdrop=$($airdropEdges.Count)"
Write-Host "SWF_RESOURCE_GRAPH_JSON=$json"
