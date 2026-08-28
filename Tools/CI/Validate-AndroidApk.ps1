param(
  [Parameter(Mandatory=$true)][string]$ApkPath,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$reportRoot=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android"
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
if(-not (Test-Path -LiteralPath $ApkPath)){throw "APK_VALIDATE=FAIL missing=$ApkPath"}

$apk=Get-Item -LiteralPath $ApkPath
$apkSha=(Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$referencePath=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android-upstream-v21.1\reference.json"
if(-not (Test-Path -LiteralPath $referencePath)){throw "APK_VALIDATE=FAIL reference_missing=$referencePath"}
$reference=Get-Content -LiteralPath $referencePath -Raw | ConvertFrom-Json

$buildTools=Join-Path $AndroidBuildRoot 'AndroidSDK\build-tools'
$aapt=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'aapt.exe' -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
$apksigner=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'apksigner.bat' -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
$zipalign=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'zipalign.exe' -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
if(-not $aapt){throw 'APK_VALIDATE=FAIL aapt_missing'}

$badgingLines=@(& $aapt.FullName dump badging $ApkPath 2>&1 | ForEach-Object {$_.ToString()})
$aaptExit=$LASTEXITCODE
$badging=($badgingLines -join [Environment]::NewLine)
$badging | Set-Content -LiteralPath (Join-Path $reportRoot 'apk-badging.txt') -Encoding UTF8
if($aaptExit -ne 0){throw "APK_VALIDATE=FAIL aapt_exit=$aaptExit"}

$permissionsLines=@(& $aapt.FullName dump permissions $ApkPath 2>&1 | ForEach-Object {$_.ToString()})
$permissionsExit=$LASTEXITCODE
$permissions=($permissionsLines -join [Environment]::NewLine)
$permissions | Set-Content -LiteralPath (Join-Path $reportRoot 'apk-permissions.txt') -Encoding UTF8
if($permissionsExit -ne 0){throw "APK_VALIDATE=FAIL permissions_aapt_exit=$permissionsExit"}

$package='';$versionCode='';$versionName='';$minSdk='';$targetSdk='';$launch=''
if($badging -match "package: name='([^']+)' versionCode='([^']*)' versionName='([^']*)'"){
  $package=$matches[1];$versionCode=$matches[2];$versionName=$matches[3]
}
if($badging -match "sdkVersion:'([^']+)'"){$minSdk=$matches[1]}
if($badging -match "targetSdkVersion:'([^']+)'"){$targetSdk=$matches[1]}
if($badging -match "launchable-activity: name='([^']+)'"){$launch=$matches[1]}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[System.IO.Compression.ZipFile]::OpenRead($ApkPath)
$seedFound=$false;$seedSize=0;$seedHash=''
try{
  $entries=@($zip.Entries)
  $abis=@($entries | Where-Object {$_.FullName -match '^lib/([^/]+)/'} | ForEach-Object {
    if($_.FullName -match '^lib/([^/]+)/'){$matches[1]}
  } | Sort-Object -Unique)
  $seed=$entries | Where-Object {$_.FullName -ieq 'assets/iArmyAirOfflineSavingv21_2.swf'} | Select-Object -First 1
  if($seed){
    $seedFound=$true
    $seedSize=$seed.Length
    $stream=$seed.Open()
    $hasher=[System.Security.Cryptography.SHA256]::Create()
    try{$seedHash=([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
    finally{$stream.Dispose();$hasher.Dispose()}
  }
  $dataCount=@($entries | Where-Object {$_.FullName -like 'assets/data/*' -and $_.Length -gt 0}).Count
  $configCount=@($entries | Where-Object {$_.FullName -like 'assets/config/*' -and $_.Length -gt 0}).Count
} finally {$zip.Dispose()}

$failures=New-Object System.Collections.Generic.List[string]
if(-not $package){$failures.Add('package_unparseable')}
$referencePackage=[string]$reference.package_name
if(-not $referencePackage){$failures.Add('reference_package_missing')}
elseif($package -ne $referencePackage){$failures.Add("package expected=$referencePackage actual=$package")}

if(-not $launch){$failures.Add('launchable_activity_missing')}
if($permissions -match 'MANAGE_EXTERNAL_STORAGE'){$failures.Add('forbidden_permission=MANAGE_EXTERNAL_STORAGE')}
if($permissions -match 'WRITE_EXTERNAL_STORAGE'){$failures.Add('forbidden_permission=WRITE_EXTERNAL_STORAGE')}

$referenceAbis=@($reference.abis)
foreach($requiredAbi in $referenceAbis){
  if($requiredAbi -and $abis -notcontains [string]$requiredAbi){$failures.Add("abi_missing=$requiredAbi actual=$($abis -join ',')")}
}
if($referenceAbis.Count -eq 0){$failures.Add('reference_abi_missing')}

$referenceTarget=[string]$reference.target_sdk
if($referenceTarget -match '^\d+$' -and $targetSdk -match '^\d+$'){
  if([int]$targetSdk -lt [int]$referenceTarget){$failures.Add("target_sdk_regression reference=$referenceTarget actual=$targetSdk")}
} elseif(-not $targetSdk){
  $failures.Add('target_sdk_unparseable')
}

$expectedSwfSha='4b7b09398779c33879f6aff337b57eca6dcc3ad637348a35d22bf2858005f3fc'
if(-not $seedFound){$failures.Add('seed_swf_missing')}
else{
  if($seedSize -ne 24614521){$failures.Add("seed_swf_size expected=24614521 actual=$seedSize")}
  if($seedHash -ne $expectedSwfSha){$failures.Add("seed_swf_sha256 expected=$expectedSwfSha actual=$seedHash")}
}
if($dataCount -lt 500){$failures.Add("data_entries=$dataCount")}
if($configCount -lt 10){$failures.Add("config_entries=$configCount")}

$signature='SKIPPED'
if($apksigner){
  $sigLines=@(& $apksigner.FullName verify --verbose --print-certs $ApkPath 2>&1 | ForEach-Object {$_.ToString()})
  $sigExit=$LASTEXITCODE
  ($sigLines -join [Environment]::NewLine) | Set-Content -LiteralPath (Join-Path $reportRoot 'apk-signature.txt') -Encoding UTF8
  if($sigExit -ne 0){$signature="FAIL($sigExit)";$failures.Add("signature_exit=$sigExit")}else{$signature='PASS'}
}

$alignment='SKIPPED'
if($zipalign){
  & $zipalign.FullName -c -P 16 4 $ApkPath | Out-Null
  $alignExit=$LASTEXITCODE
  if($alignExit -ne 0){$alignment="FAIL($alignExit)";$failures.Add("zipalign_exit=$alignExit")}else{$alignment='PASS'}
}

$provenancePath=Join-Path $reportRoot 'BUILD-PROVENANCE.json'
$buildTier='UNKNOWN'
if(-not (Test-Path -LiteralPath $provenancePath)){
  $failures.Add('provenance_missing')
} else {
  $prov=Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
  $buildTier=[string]$prov.build_tier
  if([string]$prov.tested_sha -ne $ExpectedSha){$failures.Add("provenance_sha expected=$ExpectedSha actual=$($prov.tested_sha)")}
  if(([string]$prov.apk_sha256).ToLowerInvariant() -ne $apkSha){$failures.Add("provenance_apk_sha expected=$apkSha actual=$($prov.apk_sha256)")}
  if(([string]$prov.swf_sha256).ToLowerInvariant() -ne $expectedSwfSha){$failures.Add("provenance_swf_sha expected=$expectedSwfSha actual=$($prov.swf_sha256)")}
}
if($buildTier -eq 'LEGACY_AIR32_TEST'){$failures.Add('toolchain=LEGACY_AIR32_TEST not_promotable_reference_air=50.2')}

$report=[ordered]@{
  tested_sha=$ExpectedSha
  apk_path=$ApkPath
  apk_size=$apk.Length
  apk_sha256=$apkSha
  package_name=$package
  reference_package_name=$referencePackage
  version_code=$versionCode
  version_name=$versionName
  min_sdk=$minSdk
  target_sdk=$targetSdk
  reference_target_sdk=$referenceTarget
  launchable_activity=$launch
  abis=$abis
  reference_abis=$referenceAbis
  seed_swf_size=$seedSize
  seed_swf_sha256=$seedHash
  data_entries=$dataCount
  config_entries=$configCount
  signature=$signature
  zipalign=$alignment
  build_tier=$buildTier
  reference_json=$referencePath
  provenance_json=$provenancePath
  failures=@($failures)
}
$reportPath=Join-Path $reportRoot 'apk-info.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
$summary=[ordered]@{
  repository='Valverde-101/code-army-client'
  tested_sha=$ExpectedSha
  apk_sha256=$apkSha
  apk_validated=($failures.Count -eq 0)
  build_tier=$buildTier
  failures=@($failures)
}
$summaryPath=Join-Path $reportRoot 'summary.json'
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

$reportMd=Join-Path $reportRoot 'REPORT.md'
@(
  "# Army Attack Android validation"
  ""
  "- TESTED_SHA: $ExpectedSha"
  "- APK: $ApkPath"
  "- APK_SHA256: $apkSha"
  "- package: $package"
  "- reference package: $referencePackage"
  "- ABI: $($abis -join ',')"
  "- reference ABI: $($referenceAbis -join ',')"
  "- targetSdk: $targetSdk"
  "- reference targetSdk: $referenceTarget"
  "- SWF_SHA256: $seedHash"
  "- build tier: $buildTier"
  "- signature: $signature"
  "- zipalign: $alignment"
  "- validation failures: $($failures.Count)"
  $(if($failures.Count -gt 0){"- failures: $($failures -join '; ')"}else{"- failures: none"})
) | Set-Content -LiteralPath $reportMd -Encoding UTF8

Write-Host "APK_PATH=$ApkPath"
Write-Host "APK_SIZE=$($apk.Length)"
Write-Host "APK_SHA256=$apkSha"
Write-Host "PACKAGE_NAME=$package"
Write-Host "REFERENCE_PACKAGE_NAME=$referencePackage"
Write-Host "VERSION_CODE=$versionCode"
Write-Host "VERSION_NAME=$versionName"
Write-Host "MIN_SDK=$minSdk"
Write-Host "TARGET_SDK=$targetSdk"
Write-Host "REFERENCE_TARGET_SDK=$referenceTarget"
Write-Host "LAUNCHABLE_ACTIVITY=$launch"
Write-Host "ABI=$($abis -join ',')"
Write-Host "REFERENCE_ABI=$($referenceAbis -join ',')"
Write-Host "SWF_SHA256=$seedHash"
Write-Host "SIGNATURE=$signature"
Write-Host "ZIPALIGN=$alignment"
Write-Host "BUILD_TIER=$buildTier"
Write-Host "APK_INFO=$reportPath"
Write-Host "REPORT=$reportMd"

if($failures.Count -gt 0){
  foreach($failure in $failures){Write-Host "APK_VALIDATE_FINDING=$failure"}
  throw "APK_VALIDATE=FAIL first=$($failures[0]) count=$($failures.Count)"
}

$candidateDir=Join-Path $reportRoot 'candidate'
New-Item -ItemType Directory -Force -Path $candidateDir | Out-Null
$promoted=Join-Path $candidateDir "ArmyAttack-$ExpectedSha.apk"
Copy-Item -LiteralPath $ApkPath -Destination $promoted -Force
$promotedSha=(Get-FileHash -LiteralPath $promoted -Algorithm SHA256).Hash.ToLowerInvariant()
if($promotedSha -ne $apkSha){throw "APK_PROMOTION=FAIL expected=$apkSha actual=$promotedSha"}
$meta=[ordered]@{tested_sha=$ExpectedSha;apk_path=$promoted;apk_size=(Get-Item $promoted).Length;apk_sha256=$promotedSha;package_name=$package;build_tier=$buildTier}
$metaPath="$promoted.json"
$meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metaPath -Encoding UTF8
if($env:GITHUB_ENV){"PROMOTED_CANDIDATE_PATH=$promoted" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append}

Write-Host "APK_VALIDATE=PASS"
Write-Host "APK_PROMOTION=PASS path=$promoted sha256=$promotedSha"
Write-Host "LISTA_PARA_PRUEBA_MANUAL=PASS"
