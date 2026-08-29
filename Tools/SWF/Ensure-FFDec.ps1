param(
  [string]$RepositoryRoot,
  [string]$Version = '26.2.1',
  [string]$DownloadUri,
  [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'

function Resolve-RepositoryRoot {
  param([string]$ExplicitRoot)
  if ($ExplicitRoot) { return (Resolve-Path -LiteralPath $ExplicitRoot -ErrorAction Stop).Path }
  $candidate = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  if (Test-Path -LiteralPath (Join-Path $candidate '.git')) { return (Resolve-Path -LiteralPath $candidate).Path }
  throw 'FFDEC_PRECHECK=FAIL unable_to_resolve_repository_root'
}

function Find-FFDec {
  param([string]$Root)
  foreach ($name in @('ffdec-cli.exe','ffdec.bat','ffdec.jar')) {
    $match = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($match) { return $match.FullName }
  }
  return $null
}

$repoRoot = Resolve-RepositoryRoot -ExplicitRoot $RepositoryRoot
$toolRoot = Join-Path $repoRoot ".work\tools\ffdec\$Version"
$cacheRoot = Join-Path $repoRoot '.work\cache\tools'
$zipPath = Join-Path $cacheRoot "ffdec_$Version.zip"

if (-not $DownloadUri) {
  $DownloadUri = "https://github.com/jindrapetrik/jpexs-decompiler/releases/download/version$Version/ffdec_$Version.zip"
}
if (-not $ExpectedSha256) {
  if ($Version -ne '26.2.1') { throw "FFDEC_PRECHECK=FAIL expected_sha256_required_for_version=$Version" }
  $ExpectedSha256 = '0333b56998a55bd83f4e0deb678a811fcdc45607582b4f5dd438309c8c3ad5ce'
}

New-Item -ItemType Directory -Force -Path $toolRoot,$cacheRoot | Out-Null
$existing = Find-FFDec -Root $toolRoot
if ($existing) {
  Write-Host "FFDEC_READY=PASS source=existing path=$existing version=$Version"
  Write-Host "FFDEC_PATH=$existing"
  exit 0
}

$downloadRequired = $true
if (Test-Path -LiteralPath $zipPath) {
  $cachedHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($cachedHash -eq $ExpectedSha256.ToLowerInvariant()) {
    $downloadRequired = $false
    Write-Host "FFDEC_CACHE=PASS path=$zipPath sha256=$cachedHash"
  } else {
    Remove-Item -LiteralPath $zipPath -Force
    Write-Host "FFDEC_CACHE=MISS reason=sha256_mismatch actual=$cachedHash"
  }
}
if ($downloadRequired) {
  Write-Host "FFDEC_DOWNLOAD=START uri=$DownloadUri"
  Invoke-WebRequest -Uri $DownloadUri -OutFile $zipPath -UseBasicParsing
}

$actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $ExpectedSha256.ToLowerInvariant()) {
  throw "FFDEC_DOWNLOAD=FAIL expected_sha256=$ExpectedSha256 actual_sha256=$actualHash"
}
Write-Host "FFDEC_DOWNLOAD=PASS sha256=$actualHash size=$((Get-Item -LiteralPath $zipPath).Length)"

if (Test-Path -LiteralPath $toolRoot) { Remove-Item -LiteralPath $toolRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
Expand-Archive -LiteralPath $zipPath -DestinationPath $toolRoot -Force

$ffdec = Find-FFDec -Root $toolRoot
if (-not $ffdec) { throw "FFDEC_PROVISION=FAIL executable_not_found_under=$toolRoot" }

Write-Host "FFDEC_PROVISION=PASS version=$Version root=$toolRoot"
Write-Host "FFDEC_READY=PASS source=downloaded path=$ffdec version=$Version"
Write-Host "FFDEC_PATH=$ffdec"
