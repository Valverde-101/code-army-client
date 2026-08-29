param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [switch]$BaseOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$publishedExpectedSha='306bccc7db5b1ce34dd68a3bc80093648c9224bd'
$publishedRoot=Join-Path $RepoRoot 'vendor\Test_army_attack'
$publishedGame=Join-Path $publishedRoot 'armyattack'
$publishedMods=Join-Path $publishedRoot 'mods'
$reportRoot=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android\published"
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null

function Resolve-Git {
  $candidates=@(
    (Join-Path $AndroidBuildRoot 'Tools\Git\cmd\git.exe'),
    (Join-Path $AndroidBuildRoot 'PortableGit\cmd\git.exe')
  )
  $cmd=Get-Command git.exe -ErrorAction SilentlyContinue
  if($cmd){$candidates=@($cmd.Source)+$candidates}
  $git=$candidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
  if(-not $git){throw 'PUBLISHED_CONTENT=FAIL git_missing'}
  return $git
}
$git=Resolve-Git

if(-not (Test-Path -LiteralPath $publishedRoot)){throw "PUBLISHED_CONTENT=FAIL submodule_missing=$publishedRoot"}
$publishedActual=(& $git -C $publishedRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0){throw 'PUBLISHED_CONTENT=FAIL submodule_rev_parse'}
if($publishedActual -ne $publishedExpectedSha){throw "PUBLISHED_CONTENT=FAIL expected_sha=$publishedExpectedSha actual=$publishedActual"}

$versionsPath=Join-Path $publishedRoot 'launcher\versions.json'
if(-not (Test-Path -LiteralPath $versionsPath)){throw 'PUBLISHED_CONTENT=FAIL versions_json_missing'}
$versions=Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json
$game23=@($versions.game|Where-Object{[string]$_.id -eq '23'})|Select-Object -First 1
if(-not $game23){throw 'PUBLISHED_CONTENT=FAIL game23_metadata_missing'}
$publishedVersion=[string]$game23.latestVersion
if($publishedVersion -ne '23.2'){throw "PUBLISHED_CONTENT=FAIL expected_version=23.2 actual=$publishedVersion"}

$publishedSwf=Join-Path $publishedGame 'assets\iArmyAirOfflineSavingv23.swf'
$requiredPublished=@($publishedSwf,(Join-Path $publishedGame 'data'),(Join-Path $publishedGame 'config'))
if(-not $BaseOnly){$requiredPublished+=$publishedMods}
foreach($required in $requiredPublished){
  if(-not (Test-Path -LiteralPath $required)){throw "PUBLISHED_CONTENT=FAIL missing=$required"}
}
$swf=Get-Item -LiteralPath $publishedSwf
$swfSha=(Get-FileHash -LiteralPath $publishedSwf -Algorithm SHA256).Hash.ToLowerInvariant()

$modCatalog=@()
$modTotalFiles=0L
$modTotalBytes=0L
if(-not $BaseOnly){
  foreach($dir in @(Get-ChildItem -LiteralPath $publishedMods -Directory -ErrorAction Stop|Sort-Object Name)){
    $files=@(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -ErrorAction Stop)
    $bytes=($files|Measure-Object Length -Sum).Sum
    if($null -eq $bytes){$bytes=0}
    $modTotalFiles+=$files.Count
    $modTotalBytes+=[int64]$bytes
    $modCatalog+=[ordered]@{
      id=$dir.Name
      path=("vendor/Test_army_attack/mods/"+$dir.Name)
      files=$files.Count
      bytes=[int64]$bytes
      swf=@($files|Where-Object{$_.Extension -ieq '.swf'}).Count
      json=@($files|Where-Object{$_.Extension -ieq '.json'}).Count
      png=@($files|Where-Object{$_.Extension -ieq '.png'}).Count
      mp3=@($files|Where-Object{$_.Extension -ieq '.mp3'}).Count
    }
  }
}

function Get-FileMap([string]$Root){
  $map=@{}
  if(-not (Test-Path -LiteralPath $Root)){return $map}
  $prefix=(Resolve-Path -LiteralPath $Root).Path.TrimEnd('\','/')
  foreach($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Stop)){
    $rel=$file.FullName.Substring($prefix.Length).TrimStart('\','/').Replace('\','/')
    $map[$rel]=[ordered]@{
      size=$file.Length
      sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
  return $map
}

function Compare-Tree([string]$Published,[string]$Owned){
  $pub=Get-FileMap $Published
  $own=Get-FileMap $Owned
  $all=@($pub.Keys+$own.Keys|Sort-Object -Unique)
  $same=0;$different=New-Object System.Collections.Generic.List[string]
  $publishedOnly=New-Object System.Collections.Generic.List[string]
  $ownedOnly=New-Object System.Collections.Generic.List[string]
  foreach($path in $all){
    $hasPub=$pub.ContainsKey($path);$hasOwn=$own.ContainsKey($path)
    if($hasPub -and -not $hasOwn){$publishedOnly.Add($path);continue}
    if($hasOwn -and -not $hasPub){$ownedOnly.Add($path);continue}
    if($pub[$path].size -eq $own[$path].size -and $pub[$path].sha256 -eq $own[$path].sha256){$same++}
    else{$different.Add($path)}
  }
  return [ordered]@{
    published_files=$pub.Count
    owned_files=$own.Count
    identical=$same
    different=@($different)
    published_only=@($publishedOnly)
    owned_only=@($ownedOnly)
  }
}

$dataDiff=Compare-Tree (Join-Path $publishedGame 'data') (Join-Path $RepoRoot 'src\data')
$configDiff=Compare-Tree (Join-Path $publishedGame 'config') (Join-Path $RepoRoot 'src\config')

$catalogPath=Join-Path $reportRoot 'MODS-CATALOG.json'
[ordered]@{
  source_repository='Valverde-101/Test_army_attack'
  source_sha=$publishedActual
  packaged_by_default=$false
  mods=$modCatalog
  totals=[ordered]@{mods=$modCatalog.Count;files=$modTotalFiles;bytes=$modTotalBytes}
}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $catalogPath -Encoding UTF8

$report=[ordered]@{
  principal_repository='Valverde-101/code-army-client'
  tested_sha=$ExpectedSha
  published_repository='Valverde-101/Test_army_attack'
  published_source_sha=$publishedActual
  published_version=$publishedVersion
  published_name=[string]$game23.name
  published_swf=[ordered]@{
    path='vendor/Test_army_attack/armyattack/assets/iArmyAirOfflineSavingv23.swf'
    size=$swf.Length
    sha256=$swfSha
  }
  content_diff=[ordered]@{data=$dataDiff;config=$configDiff}
  base_only=[bool]$BaseOnly
  mods_catalog=$(if($BaseOnly){$null}else{$catalogPath})
}
$reportPath=Join-Path $reportRoot 'PUBLISHED-CONTENT.json'
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $reportPath -Encoding UTF8

if($env:GITHUB_ENV){
  "PUBLISHED_CONTENT_REPORT=$reportPath"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  if(-not $BaseOnly){"MODS_CATALOG=$catalogPath"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append}
  "PUBLISHED_SOURCE_SHA=$publishedActual"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "PUBLISHED_VERSION=$publishedVersion"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "PUBLISHED_SWF_PATH=$publishedSwf"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "PUBLISHED_SWF_SHA256=$swfSha"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
}

Write-Host "PUBLISHED_CONTENT=PASS repository=Valverde-101/Test_army_attack sha=$publishedActual version=$publishedVersion"
Write-Host "PUBLISHED_SWF=PASS size=$($swf.Length) sha256=$swfSha"
if($BaseOnly){
  Write-Host 'MODS_DISCOVERED=SKIPPED_WITH_REASON base_only_modern_v23_2'
  Write-Host 'PUBLISHED_BASE_ONLY=PASS version=23.2'
}else{
  Write-Host "MODS_DISCOVERED=PASS count=$($modCatalog.Count) files=$modTotalFiles bytes=$modTotalBytes names=$((@($modCatalog|ForEach-Object{$_.id})) -join ',')"
}
Write-Host "PUBLISHED_DATA_DIFF published=$($dataDiff.published_files) owned=$($dataDiff.owned_files) identical=$($dataDiff.identical) different=$($dataDiff.different.Count) published_only=$($dataDiff.published_only.Count) owned_only=$($dataDiff.owned_only.Count)"
Write-Host "PUBLISHED_CONFIG_DIFF published=$($configDiff.published_files) owned=$($configDiff.owned_files) identical=$($configDiff.identical) different=$($configDiff.different.Count) published_only=$($configDiff.published_only.Count) owned_only=$($configDiff.owned_only.Count)"
Write-Host "PUBLISHED_CONTENT_REPORT=$reportPath"
Write-Host "MODS_CATALOG=$catalogPath"
