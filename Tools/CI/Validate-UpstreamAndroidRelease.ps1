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
$inputRoot=Join-Path $AndroidBuildRoot "Inputs\code-army-client\upstream\$tag"
$apkPath=Join-Path $inputRoot $asset
$reportRoot=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android-upstream-$tag"
New-Item -ItemType Directory -Force -Path $inputRoot,$reportRoot | Out-Null
$download=$true
if(Test-Path -LiteralPath $apkPath){if((Get-Item -LiteralPath $apkPath).Length -eq $expectedSize){$download=$false}}
if($download){
  if(Test-Path -LiteralPath $apkPath){Remove-Item -LiteralPath $apkPath -Force}
  $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
  if($curl){
    & $curl.Source -L --fail --retry 3 --retry-delay 2 -o $apkPath $url
    if($LASTEXITCODE -ne 0){throw "UPSTREAM_ANDROID_DOWNLOAD=FAIL exit=$LASTEXITCODE"}
  } else {Invoke-WebRequest -Uri $url -OutFile $apkPath -UseBasicParsing}
}
$apk=Get-Item -LiteralPath $apkPath
if($apk.Length -ne $expectedSize){throw "UPSTREAM_ANDROID_VALIDATE=FAIL expected_size=$expectedSize actual=$($apk.Length)"}
$sha=(Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[System.IO.Compression.ZipFile]::OpenRead($apkPath)
try{
  $entries=@($zip.Entries)
  $abis=@($entries|Where-Object{$_.FullName -match '^lib/([^/]+)/'}|ForEach-Object{if($_.FullName -match '^lib/([^/]+)/'){$matches[1]}}|Sort-Object -Unique)
  $swfs=@($entries|Where-Object{$_.FullName -match '(?i)\.swf$'}|ForEach-Object{[ordered]@{path=$_.FullName;size=$_.Length}})
  $assets=@($entries|Where-Object{$_.FullName -like 'assets/*'})
} finally {$zip.Dispose()}
$aapt=$null
$buildTools=Join-Path $AndroidBuildRoot 'AndroidSDK\build-tools'
if(Test-Path -LiteralPath $buildTools){$aapt=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'aapt.exe' -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1}
$badging=''
if($aapt){$badging=(& $aapt.FullName dump badging $apkPath 2>&1|Out-String);$badging|Set-Content -LiteralPath (Join-Path $reportRoot 'aapt-badging.txt') -Encoding UTF8}
$aaptPath=$null
if($aapt){$aaptPath=$aapt.FullName}
$report=[ordered]@{repository='Michielvde1253/army-client';tag=$tag;asset=$asset;path=$apkPath;size=$apk.Length;sha256=$sha;abis=$abis;swfs=$swfs;asset_entry_count=$assets.Count;aapt=$aaptPath}
$reportPath=Join-Path $reportRoot 'reference.json'
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host "UPSTREAM_ANDROID_REFERENCE=PASS tag=$tag asset=$asset"
Write-Host "UPSTREAM_ANDROID_APK_PATH=$apkPath"
Write-Host "UPSTREAM_ANDROID_APK_SIZE=$($apk.Length)"
Write-Host "UPSTREAM_ANDROID_APK_SHA256=$sha"
Write-Host "UPSTREAM_ANDROID_ABIS=$($abis -join ',')"
Write-Host "UPSTREAM_ANDROID_SWF_COUNT=$($swfs.Count)"
foreach($swf in $swfs){Write-Host "UPSTREAM_ANDROID_SWF=$($swf.path) size=$($swf.size)"}
Write-Host "UPSTREAM_ANDROID_ASSET_ENTRIES=$($assets.Count)"
Write-Host "UPSTREAM_ANDROID_REPORT=$reportPath"
