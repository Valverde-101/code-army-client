param(
  [Parameter(Mandatory=$true)][string]$SourceApk,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$RelativePath,
  [Parameter(Mandatory=$true)][string]$Kind,
  [switch]$PhysicalValidated
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

# One-time migration repair: candidate c3ec09ff was proven valid but was incorrectly
# copied to APK-FINAL before physical validation by the pre-Core publisher contract.
# Delete only Army-owned entries whose sidecar proves that exact SHA; never touch
# another project's APK-FINAL ownership.
function Remove-PrematureMigrationFinal {
  $badSha='c3ec09fff4c06da08aeebdd070bf570534cd4fbe'
  $finalRoot=Join-Path $AndroidBuildRoot 'APK-FINAL'
  $targets=@(
    (Join-Path $finalRoot (Join-Path (Join-Path 'archive' $badSha) 'ArmyAttack-23.2.apk')),
    (Join-Path $finalRoot 'ArmyAttack-23.2.apk')
  )
  foreach($apkPath in $targets){
    $metaPath=$apkPath+'.json'
    if(-not(Test-Path -LiteralPath $metaPath -PathType Leaf)){continue}
    try{$meta=Get-Content -LiteralPath $metaPath -Raw|ConvertFrom-Json}catch{continue}
    if([string]$meta.repository -ne 'Valverde-101/code-army-client' -or [string]$meta.tested_sha -ne $badSha){continue}
    Remove-Item -LiteralPath $apkPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
    Write-Host "APK_FINAL_MIGRATION_CLEANUP=PASS tested_sha=$badSha path=$apkPath ownership=army-attack"
  }
}

Remove-PrematureMigrationFinal

if(-not $PhysicalValidated){
  Write-Host "APK_FINAL_PUBLICATION=DEFERRED_UNTIL_PHYSICAL_VALIDATION tested_sha=$ExpectedSha kind=$Kind"
  return
}

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
  physical_validation='PASS'
  source_apk=$SourceApk
  apk_size=$source.Length
  apk_sha256=$sourceSha
  archive_path=$archiveDest
  latest_path=$latestDest
  published_utc=(Get-Date).ToUniversalTime().ToString('o')
}
$meta|ConvertTo-Json -Depth 5|Set-Content -LiteralPath ($archiveDest+'.json') -Encoding UTF8
Write-Host "APK_FINAL_ARCHIVE=PASS path=$archiveDest sha256=$archiveSha physical_validation=PASS"

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
  return
}

Copy-Item -LiteralPath $SourceApk -Destination $latestDest -Force
$latestSha=(Get-FileHash -LiteralPath $latestDest -Algorithm SHA256).Hash.ToLowerInvariant()
if($latestSha -ne $sourceSha){throw "APK_FINAL_LATEST=FAIL expected=$sourceSha actual=$latestSha path=$latestDest"}
$meta|ConvertTo-Json -Depth 5|Set-Content -LiteralPath ($latestDest+'.json') -Encoding UTF8
Write-Host "APK_FINAL_LATEST=PASS path=$latestDest sha256=$latestSha physical_validation=PASS"
Write-Host "APK_FINAL_COPY=PASS kind=$Kind physical_validation=PASS"
