param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$tag='v21.1'
$asset='AA21_1_release_android_HR.apk'
$url='https://github.com/Michielvde1253/army-client/releases/download/v21.1/AA21_1_release_android_HR.apk'
$expectedSize=46393520
$expectedSha256='6136ab9b1175d75bcd53cabbe8c787bad9c51c5520324e94da230a18fb7bc824'
$inputRoot=Join-Path $AndroidBuildRoot "Inputs\code-army-client\upstream\$tag"
$apkPath=Join-Path $inputRoot $asset
$reportRoot=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android-upstream-$tag"
New-Item -ItemType Directory -Force -Path $inputRoot,$reportRoot | Out-Null

function Invoke-Download([string]$Uri,[string]$Destination){
  $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
  if($curl){
    & $curl.Source -L --fail --retry 3 --retry-delay 2 -o $Destination $Uri
    if($LASTEXITCODE -ne 0){throw "UPSTREAM_ANDROID_DOWNLOAD=FAIL exit=$LASTEXITCODE"}
  } else {
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
  }
}

$download=$true
if(Test-Path -LiteralPath $apkPath){
  $existing=Get-Item -LiteralPath $apkPath
  if($existing.Length -eq $expectedSize){
    $existingSha=(Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($existingSha -eq $expectedSha256){$download=$false}
  }
}
if($download){
  Remove-Item -LiteralPath $apkPath -Force -ErrorAction SilentlyContinue
  Invoke-Download $url $apkPath
}

$apk=Get-Item -LiteralPath $apkPath
if($apk.Length -ne $expectedSize){throw "UPSTREAM_ANDROID_VALIDATE=FAIL expected_size=$expectedSize actual=$($apk.Length)"}
$sha=(Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
if($sha -ne $expectedSha256){throw "UPSTREAM_ANDROID_VALIDATE=FAIL expected_sha256=$expectedSha256 actual=$sha"}

$buildTools=Join-Path $AndroidBuildRoot 'AndroidSDK\build-tools'
$aapt=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'aapt.exe' -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
if(-not $aapt){throw 'UPSTREAM_ANDROID_VALIDATE=FAIL aapt_missing'}

$badgingLines=@(& $aapt.FullName dump badging $apkPath 2>&1 | ForEach-Object {$_.ToString()})
$aaptExit=$LASTEXITCODE
$badging=($badgingLines -join [Environment]::NewLine)
$badging | Set-Content -LiteralPath (Join-Path $reportRoot 'aapt-badging.txt') -Encoding UTF8
if($aaptExit -ne 0){throw "UPSTREAM_ANDROID_VALIDATE=FAIL aapt_exit=$aaptExit"}

$package='';$versionCode='';$versionName='';$minSdk='';$targetSdk='';$launch=''
if($badging -match "package: name='([^']+)' versionCode='([^']*)' versionName='([^']*)'"){
  $package=$matches[1];$versionCode=$matches[2];$versionName=$matches[3]
}
if($badging -match "sdkVersion:'([^']+)'"){$minSdk=$matches[1]}
if($badging -match "targetSdkVersion:'([^']+)'"){$targetSdk=$matches[1]}
if($badging -match "launchable-activity: name='([^']+)'"){$launch=$matches[1]}
if(-not $package){throw 'UPSTREAM_ANDROID_VALIDATE=FAIL package_unparseable'}
if(-not $launch){throw 'UPSTREAM_ANDROID_VALIDATE=FAIL launchable_activity_unparseable'}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[System.IO.Compression.ZipFile]::OpenRead($apkPath)
try{
  $entries=@($zip.Entries)
  $abis=@($entries | Where-Object {$_.FullName -match '^lib/([^/]+)/'} | ForEach-Object {
    if($_.FullName -match '^lib/([^/]+)/'){$matches[1]}
  } | Sort-Object -Unique)
  $swfs=@()
  foreach($entry in @($entries | Where-Object {$_.FullName -match '(?i)\.swf$'})){
    $stream=$entry.Open()
    $hasher=[System.Security.Cryptography.SHA256]::Create()
    try{$entryHash=([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
    finally{$stream.Dispose();$hasher.Dispose()}
    $swfs+=[ordered]@{path=$entry.FullName;size=$entry.Length;sha256=$entryHash}
  }
  $assets=@($entries | Where-Object {$_.FullName -like 'assets/*'})
} finally {$zip.Dispose()}

if($abis -notcontains 'arm64-v8a'){throw "UPSTREAM_ANDROID_VALIDATE=FAIL expected_abi=arm64-v8a actual=$($abis -join ',')"}

$report=[ordered]@{
  repository='Michielvde1253/army-client'
  tag=$tag
  asset=$asset
  path=$apkPath
  size=$apk.Length
  sha256=$sha
  package_name=$package
  version_code=$versionCode
  version_name=$versionName
  min_sdk=$minSdk
  target_sdk=$targetSdk
  launchable_activity=$launch
  abis=$abis
  swfs=$swfs
  asset_entry_count=$assets.Count
  aapt=$aapt.FullName
}
$reportPath=Join-Path $reportRoot 'reference.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if($env:GITHUB_ENV){
  "UPSTREAM_ANDROID_REFERENCE_JSON=$reportPath" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "UPSTREAM_ANDROID_PACKAGE=$package" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "UPSTREAM_ANDROID_ABIS=$($abis -join ',')" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "UPSTREAM_ANDROID_TARGET_SDK=$targetSdk" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
}

Write-Host "UPSTREAM_ANDROID_REFERENCE=PASS tag=$tag asset=$asset"
Write-Host "UPSTREAM_ANDROID_APK_PATH=$apkPath"
Write-Host "UPSTREAM_ANDROID_APK_SIZE=$($apk.Length)"
Write-Host "UPSTREAM_ANDROID_APK_SHA256=$sha"
Write-Host "UPSTREAM_ANDROID_PACKAGE=$package"
Write-Host "UPSTREAM_ANDROID_VERSION_CODE=$versionCode"
Write-Host "UPSTREAM_ANDROID_VERSION_NAME=$versionName"
Write-Host "UPSTREAM_ANDROID_MIN_SDK=$minSdk"
Write-Host "UPSTREAM_ANDROID_TARGET_SDK=$targetSdk"
Write-Host "UPSTREAM_ANDROID_LAUNCHABLE_ACTIVITY=$launch"
Write-Host "UPSTREAM_ANDROID_ABIS=$($abis -join ',')"
Write-Host "UPSTREAM_ANDROID_SWF_COUNT=$($swfs.Count)"
foreach($swf in $swfs){Write-Host "UPSTREAM_ANDROID_SWF=$($swf.path) size=$($swf.size) sha256=$($swf.sha256)"}
Write-Host "UPSTREAM_ANDROID_ASSET_ENTRIES=$($assets.Count)"
Write-Host "UPSTREAM_ANDROID_REPORT=$reportPath"
