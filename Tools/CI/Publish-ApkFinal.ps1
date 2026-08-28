param(
  [Parameter(Mandatory=$true)][string]$SourceApk,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$RelativePath,
  [Parameter(Mandatory=$true)][string]$Kind
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(-not (Test-Path -LiteralPath $SourceApk)){throw "APK_FINAL_COPY=FAIL source_missing=$SourceApk"}
$source=Get-Item -LiteralPath $SourceApk
$sourceSha=(Get-FileHash -LiteralPath $SourceApk -Algorithm SHA256).Hash.ToLowerInvariant()

$finalRoot=Join-Path $AndroidBuildRoot 'APK-FINAL'
$archiveRoot=Join-Path $finalRoot (Join-Path 'archive' $ExpectedSha)
$archiveDest=Join-Path $archiveRoot $RelativePath
$latestDest=Join-Path $finalRoot $RelativePath

foreach($dir in @((Split-Path -Parent $archiveDest),(Split-Path -Parent $latestDest))){
  New-Item -ItemType Directory -Force -Path $dir|Out-Null
}

Copy-Item -LiteralPath $SourceApk -Destination $archiveDest -Force
$archiveSha=(Get-FileHash -LiteralPath $archiveDest -Algorithm SHA256).Hash.ToLowerInvariant()
if($archiveSha -ne $sourceSha){throw "APK_FINAL_ARCHIVE=FAIL expected=$sourceSha actual=$archiveSha path=$archiveDest"}

$meta=[ordered]@{
  repository='Valverde-101/code-army-client'
  tested_sha=$ExpectedSha
  kind=$Kind
  source_apk=$SourceApk
  apk_size=$source.Length
  apk_sha256=$sourceSha
  archive_path=$archiveDest
  latest_path=$latestDest
  published_utc=(Get-Date).ToUniversalTime().ToString('o')
}
$meta|ConvertTo-Json -Depth 5|Set-Content -LiteralPath ($archiveDest+'.json') -Encoding UTF8
Write-Host "APK_FINAL_ARCHIVE=PASS path=$archiveDest sha256=$archiveSha"

$canonicalRepo=Join-Path $AndroidBuildRoot 'Repositories\code-army-client'
$gitCandidates=@()
$gitCmd=Get-Command git.exe -ErrorAction SilentlyContinue
if($gitCmd){$gitCandidates+=$gitCmd.Source}
$gitCandidates+=@(
  (Join-Path $AndroidBuildRoot 'Tools\Git\cmd\git.exe'),
  (Join-Path $AndroidBuildRoot 'PortableGit\cmd\git.exe')
)
$git=$gitCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
$canonicalSha=''
if($git -and (Test-Path -LiteralPath $canonicalRepo)){
  $canonicalSha=(& $git -C $canonicalRepo rev-parse HEAD 2>$null).Trim()
}
if($canonicalSha -ne $ExpectedSha){
  Write-Host "APK_FINAL_LATEST=SKIPPED_WITH_REASON stale_head expected=$ExpectedSha canonical=$canonicalSha archive=$archiveDest"
  exit 0
}

Copy-Item -LiteralPath $SourceApk -Destination $latestDest -Force
$latestSha=(Get-FileHash -LiteralPath $latestDest -Algorithm SHA256).Hash.ToLowerInvariant()
if($latestSha -ne $sourceSha){throw "APK_FINAL_LATEST=FAIL expected=$sourceSha actual=$latestSha path=$latestDest"}
$meta|ConvertTo-Json -Depth 5|Set-Content -LiteralPath ($latestDest+'.json') -Encoding UTF8
Write-Host "APK_FINAL_LATEST=PASS path=$latestDest sha256=$latestSha"
Write-Host "APK_FINAL_COPY=PASS kind=$Kind"
