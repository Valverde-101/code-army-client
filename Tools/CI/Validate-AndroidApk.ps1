param(
  [Parameter(Mandatory=$true)][string]$ApkPath,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not (Test-Path -LiteralPath $ApkPath)){throw "APK_VALIDATE=FAIL missing=$ApkPath"}
$apk=Get-Item $ApkPath;$sha=(Get-FileHash $ApkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$buildTools=Join-Path $AndroidBuildRoot 'AndroidSDK\build-tools'
$aapt=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'aapt.exe' -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1
$apksigner=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'apksigner.bat' -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1
$zipalign=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'zipalign.exe' -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1
if(-not $aapt){throw 'APK_VALIDATE=FAIL aapt_missing'}
$badging=(& $aapt.FullName dump badging $ApkPath 2>&1|Out-String)
if($LASTEXITCODE -ne 0){throw "APK_VALIDATE=FAIL aapt_exit=$LASTEXITCODE"}
$package='';$versionCode='';$versionName='';$minSdk='';$targetSdk='';$launch=''
if($badging -match "package: name='([^']+)' versionCode='([^']*)' versionName='([^']*)'"){$package=$matches[1];$versionCode=$matches[2];$versionName=$matches[3]}
if($badging -match "sdkVersion:'([^']+)'"){$minSdk=$matches[1]}
if($badging -match "targetSdkVersion:'([^']+)'"){$targetSdk=$matches[1]}
if($badging -match "launchable-activity: name='([^']+)'"){$launch=$matches[1]}
if($package -ne 'army.attack'){throw "APK_VALIDATE=FAIL package expected=army.attack actual=$package"}
$permissions=(& $aapt.FullName dump permissions $ApkPath 2>&1|Out-String)
if($permissions -match 'MANAGE_EXTERNAL_STORAGE'){throw 'APK_VALIDATE=FAIL forbidden_permission=MANAGE_EXTERNAL_STORAGE'}
if($permissions -match 'WRITE_EXTERNAL_STORAGE'){throw 'APK_VALIDATE=FAIL forbidden_permission=WRITE_EXTERNAL_STORAGE'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[System.IO.Compression.ZipFile]::OpenRead($ApkPath)
try{
  $entries=@($zip.Entries)
  $abis=@($entries|Where-Object{$_.FullName -match '^lib/([^/]+)/'}|ForEach-Object{if($_.FullName -match '^lib/([^/]+)/'){$matches[1]}}|Sort-Object -Unique)
  $seed=$entries|Where-Object{$_.FullName -ieq 'assets/iArmyAirOfflineSavingv21_2.swf'}|Select-Object -First 1
  $dataCount=@($entries|Where-Object{$_.FullName -like 'assets/data/*' -and $_.Length -gt 0}).Count
  $configCount=@($entries|Where-Object{$_.FullName -like 'assets/config/*' -and $_.Length -gt 0}).Count
} finally {$zip.Dispose()}
if(-not $seed){throw 'APK_VALIDATE=FAIL seed_swf_missing'}
if($seed.Length -ne 24614521){throw "APK_VALIDATE=FAIL seed_swf_size expected=24614521 actual=$($seed.Length)"}
if($dataCount -lt 500){throw "APK_VALIDATE=FAIL data_entries=$dataCount"}
if($configCount -lt 10){throw "APK_VALIDATE=FAIL config_entries=$configCount"}
$signature='SKIPPED'
if($apksigner){& $apksigner.FullName verify --verbose --print-certs $ApkPath;if($LASTEXITCODE -ne 0){throw "APK_VALIDATE=FAIL signature_exit=$LASTEXITCODE"};$signature='PASS'}
$alignment='SKIPPED'
if($zipalign){& $zipalign.FullName -c -P 16 4 $ApkPath;if($LASTEXITCODE -ne 0){throw "APK_VALIDATE=FAIL zipalign_exit=$LASTEXITCODE"};$alignment='PASS'}
$reportRoot=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android"
$badging|Set-Content -LiteralPath (Join-Path $reportRoot 'apk-badging.txt') -Encoding UTF8
$permissions|Set-Content -LiteralPath (Join-Path $reportRoot 'apk-permissions.txt') -Encoding UTF8
$report=[ordered]@{apk_path=$ApkPath;apk_size=$apk.Length;apk_sha256=$sha;package_name=$package;version_code=$versionCode;version_name=$versionName;min_sdk=$minSdk;target_sdk=$targetSdk;launchable_activity=$launch;abis=$abis;seed_swf_size=$seed.Length;data_entries=$dataCount;config_entries=$configCount;signature=$signature;zipalign=$alignment}
$reportPath=Join-Path $reportRoot 'apk-info.json';$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host "APK_VALIDATE=PASS"
Write-Host "APK_PATH=$ApkPath"
Write-Host "APK_SIZE=$($apk.Length)"
Write-Host "APK_SHA256=$sha"
Write-Host "PACKAGE_NAME=$package"
Write-Host "VERSION_CODE=$versionCode"
Write-Host "VERSION_NAME=$versionName"
Write-Host "MIN_SDK=$minSdk"
Write-Host "TARGET_SDK=$targetSdk"
Write-Host "LAUNCHABLE_ACTIVITY=$launch"
Write-Host "ABI=$($abis -join ',')"
Write-Host "SIGNATURE=$signature"
Write-Host "ZIPALIGN=$alignment"
Write-Host "APK_INFO=$reportPath"
