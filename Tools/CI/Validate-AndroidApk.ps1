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
$provenancePath=Join-Path $reportRoot 'BUILD-PROVENANCE.json'
$publishedReportPath=Join-Path $reportRoot 'published\PUBLISHED-CONTENT.json'
$performanceReportPath=Join-Path $reportRoot 'PERFORMANCE-PATCH.json'
if(-not (Test-Path -LiteralPath $referencePath)){throw "APK_VALIDATE=FAIL reference_missing=$referencePath"}
if(-not (Test-Path -LiteralPath $provenancePath)){throw "APK_VALIDATE=FAIL provenance_missing=$provenancePath"}
if(-not (Test-Path -LiteralPath $publishedReportPath)){throw "APK_VALIDATE=FAIL published_report_missing=$publishedReportPath"}
if(-not (Test-Path -LiteralPath $performanceReportPath)){throw "APK_VALIDATE=FAIL performance_report_missing=$performanceReportPath"}
$reference=Get-Content -LiteralPath $referencePath -Raw|ConvertFrom-Json
$prov=Get-Content -LiteralPath $provenancePath -Raw|ConvertFrom-Json
$published=Get-Content -LiteralPath $publishedReportPath -Raw|ConvertFrom-Json
$performance=Get-Content -LiteralPath $performanceReportPath -Raw|ConvertFrom-Json

$expectedSwfSha=([string]$prov.swf_sha256).ToLowerInvariant()
$expectedSwfSize=[int64]$prov.swf_size
$appContentSwf=[string]$prov.app_content_swf
if(-not $expectedSwfSha -or -not $appContentSwf){throw 'APK_VALIDATE=FAIL provenance_seed_incomplete'}
$seedEntryPath='assets/'+$appContentSwf

$buildTools=Join-Path $AndroidBuildRoot 'AndroidSDK\build-tools'
$aapt=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'aapt.exe' -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1
$apksigner=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'apksigner.bat' -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1
$zipalign=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'zipalign.exe' -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1
if(-not $aapt){throw 'APK_VALIDATE=FAIL aapt_missing'}

$badgingLines=@(& $aapt.FullName dump badging $ApkPath 2>&1|ForEach-Object{$_.ToString()})
$aaptExit=$LASTEXITCODE
$badging=($badgingLines -join [Environment]::NewLine)
$badging|Set-Content -LiteralPath (Join-Path $reportRoot 'apk-badging.txt') -Encoding UTF8
if($aaptExit -ne 0){throw "APK_VALIDATE=FAIL aapt_exit=$aaptExit"}

$permissionsLines=@(& $aapt.FullName dump permissions $ApkPath 2>&1|ForEach-Object{$_.ToString()})
$permissionsExit=$LASTEXITCODE
$permissions=($permissionsLines -join [Environment]::NewLine)
$permissions|Set-Content -LiteralPath (Join-Path $reportRoot 'apk-permissions.txt') -Encoding UTF8
if($permissionsExit -ne 0){throw "APK_VALIDATE=FAIL permissions_aapt_exit=$permissionsExit"}

$package='';$versionCode='';$versionName='';$minSdk='';$targetSdk='';$launch=''
if($badging -match "package: name='([^']+)' versionCode='([^']*)' versionName='([^']*)'"){$package=$matches[1];$versionCode=$matches[2];$versionName=$matches[3]}
if($badging -match "sdkVersion:'([^']+)'"){$minSdk=$matches[1]}
if($badging -match "targetSdkVersion:'([^']+)'"){$targetSdk=$matches[1]}
if($badging -match "launchable-activity: name='([^']+)'"){$launch=$matches[1]}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[System.IO.Compression.ZipFile]::OpenRead($ApkPath)
$seedFound=$false;$seedSize=0L;$seedHash=''
try{
  $entries=@($zip.Entries)
  $abis=@($entries|Where-Object{$_.FullName -match '^lib/([^/]+)/'}|ForEach-Object{if($_.FullName -match '^lib/([^/]+)/'){$matches[1]}}|Sort-Object -Unique)
  $seed=$entries|Where-Object{$_.FullName -ieq $seedEntryPath}|Select-Object -First 1
  if($seed){
    $seedFound=$true;$seedSize=$seed.Length
    $stream=$seed.Open();$hasher=[System.Security.Cryptography.SHA256]::Create()
    try{$seedHash=([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
    finally{$stream.Dispose();$hasher.Dispose()}
  }
  $dataCount=@($entries|Where-Object{$_.FullName -like 'assets/data/*' -and $_.Length -gt 0}).Count
  $configCount=@($entries|Where-Object{$_.FullName -like 'assets/config/*' -and $_.Length -gt 0}).Count
  $profileEntries=@($entries|Where-Object{$_.FullName -like 'assets/profiles/*'})
  $selectorEntries=@($entries|Where-Object{$_.FullName -match '(?i)ArmyAttackLauncher|ArmyAttackDiagnostics|armyattackdiagnostics|com/valverde/armyattack/diagnostics'})
  $rootSwfEntries=@($entries|Where-Object{$_.FullName -match '^assets/[^/]+\.swf$'})
}finally{$zip.Dispose()}

$failures=New-Object System.Collections.Generic.List[string]
$referencePackage=[string]$reference.package_name
if(-not $package){$failures.Add('package_unparseable')}
elseif($package -ne $referencePackage){$failures.Add("package expected=$referencePackage actual=$package")}
if(-not $launch){$failures.Add('launchable_activity_missing')}
if($permissions -match 'MANAGE_EXTERNAL_STORAGE'){$failures.Add('forbidden_permission=MANAGE_EXTERNAL_STORAGE')}
if($permissions -match 'WRITE_EXTERNAL_STORAGE'){$failures.Add('forbidden_permission=WRITE_EXTERNAL_STORAGE')}

$referenceAbis=@($reference.abis)
foreach($requiredAbi in $referenceAbis){if($requiredAbi -and $abis -notcontains [string]$requiredAbi){$failures.Add("abi_missing=$requiredAbi actual=$($abis -join ',')")}}
if($referenceAbis.Count -eq 0){$failures.Add('reference_abi_missing')}

$referenceTarget=[string]$reference.target_sdk
if($referenceTarget -match '^\d+$' -and $targetSdk -match '^\d+$'){
  if([int]$targetSdk -lt [int]$referenceTarget){$failures.Add("target_sdk_regression reference=$referenceTarget actual=$targetSdk")}
}else{$failures.Add('target_sdk_unparseable')}

if(-not $seedFound){$failures.Add("seed_swf_missing path=$seedEntryPath")}
else{
  if($seedSize -ne $expectedSwfSize){$failures.Add("seed_swf_size expected=$expectedSwfSize actual=$seedSize")}
  if($seedHash -ne $expectedSwfSha){$failures.Add("seed_swf_sha256 expected=$expectedSwfSha actual=$seedHash")}
}
if($dataCount -lt 500){$failures.Add("data_entries=$dataCount")}
if($configCount -lt 10){$failures.Add("config_entries=$configCount")}
if($profileEntries.Count -ne 0){$failures.Add("base_only_profiles_present=$($profileEntries.Count)")}
if($selectorEntries.Count -ne 0){$failures.Add("base_only_selector_or_diagnostics_present=$($selectorEntries.Count)")}
if($rootSwfEntries.Count -ne 1){$failures.Add("base_only_root_swf_count=$($rootSwfEntries.Count)")}
elseif($rootSwfEntries[0].FullName -ine $seedEntryPath){$failures.Add("base_only_root_swf expected=$seedEntryPath actual=$($rootSwfEntries[0].FullName)")}

$buildTier=[string]$prov.build_tier
if([string]$prov.tested_sha -ne $ExpectedSha){$failures.Add("provenance_sha expected=$ExpectedSha actual=$($prov.tested_sha)")}
if(([string]$prov.apk_sha256).ToLowerInvariant() -ne $apkSha){$failures.Add("provenance_apk_sha expected=$apkSha actual=$($prov.apk_sha256)")}
if(([string]$prov.binary_seed_source_repository) -ne 'Valverde-101/Test_army_attack'){$failures.Add("binary_seed_source_repository=$($prov.binary_seed_source_repository)")}
if(([string]$prov.binary_seed_source_sha) -ne '306bccc7db5b1ce34dd68a3bc80093648c9224bd'){$failures.Add("binary_seed_source_sha=$($prov.binary_seed_source_sha)")}
if(([string]$prov.game_version) -ne '23.2'){$failures.Add("game_version=$($prov.game_version)")}
if(([string]$published.published_source_sha) -ne '306bccc7db5b1ce34dd68a3bc80093648c9224bd'){$failures.Add("published_report_sha=$($published.published_source_sha)")}
if(([string]$published.published_version) -ne '23.2'){$failures.Add("published_report_version=$($published.published_version)")}
if([string]$prov.performance_patch_version -ne 'android-perf-v1'){$failures.Add("performance_patch_version=$($prov.performance_patch_version)")}
if(-not [bool]$prov.swf_performance_patched){$failures.Add('performance_patch_disabled')}
if([string]$performance.patch_version -ne 'android-perf-v1'){$failures.Add("performance_report_version=$($performance.patch_version)")}
$canonicalSourceSha='99a7e8c219610eabbe97aee74228d52ded1532b4c2d4310432d15082b2ff11c4'
$provenanceSourceSha=([string]$prov.swf_source_sha256).ToLowerInvariant()
$performanceSourceSha=([string]$performance.source_sha256).ToLowerInvariant()
$performanceOutputSha=([string]$performance.output_sha256).ToLowerInvariant()
if($provenanceSourceSha -ne $canonicalSourceSha){$failures.Add("performance_source_sha expected=$canonicalSourceSha actual=$provenanceSourceSha")}
if($performanceSourceSha -ne $canonicalSourceSha){$failures.Add("performance_report_source_sha expected=$canonicalSourceSha actual=$performanceSourceSha")}
if($performanceOutputSha -ne $expectedSwfSha){$failures.Add("performance_output_sha expected=$expectedSwfSha actual=$performanceOutputSha")}
if($expectedSwfSha -eq $canonicalSourceSha){$failures.Add('performance_patch_hash_unchanged')}
$perfClasses=@($performance.classes)
foreach($requiredClass in @('game.isometric.IsometricScene','game.characters.EnemyUnit','game.particles.SmokeEmitter')){
  if($perfClasses -notcontains $requiredClass){$failures.Add("performance_class_missing=$requiredClass")}
}
if([int]$performance.policy.static_logic_tick_ms -ne 50){$failures.Add("performance_static_tick=$($performance.policy.static_logic_tick_ms)")}
if([int]$performance.policy.enemy_reaction_tick_ms -ne 50){$failures.Add("performance_enemy_tick=$($performance.policy.enemy_reaction_tick_ms)")}
if([int]$performance.policy.smoke_max_concurrent_particles -ne 18){$failures.Add("performance_smoke_max=$($performance.policy.smoke_max_concurrent_particles)")}
if($buildTier -eq 'LEGACY_AIR32_TEST'){$failures.Add('toolchain=LEGACY_AIR32_TEST')}

$signature='SKIPPED'
if($apksigner){
  $sigLines=@(& $apksigner.FullName verify --verbose --print-certs $ApkPath 2>&1|ForEach-Object{$_.ToString()})
  $sigExit=$LASTEXITCODE
  ($sigLines -join [Environment]::NewLine)|Set-Content -LiteralPath (Join-Path $reportRoot 'apk-signature.txt') -Encoding UTF8
  if($sigExit -ne 0){$signature="FAIL($sigExit)";$failures.Add("signature_exit=$sigExit")}else{$signature='PASS'}
}
$alignment='SKIPPED'
if($zipalign){
  & $zipalign.FullName -c -P 16 4 $ApkPath|Out-Null
  $alignExit=$LASTEXITCODE
  if($alignExit -ne 0){$alignment="FAIL($alignExit)";$failures.Add("zipalign_exit=$alignExit")}else{$alignment='PASS'}
}

$report=[ordered]@{
  tested_sha=$ExpectedSha;apk_path=$ApkPath;apk_size=$apk.Length;apk_sha256=$apkSha
  package_name=$package;reference_package_name=$referencePackage
  version_code=$versionCode;version_name=$versionName;min_sdk=$minSdk;target_sdk=$targetSdk;reference_target_sdk=$referenceTarget
  launchable_activity=$launch;abis=$abis;reference_abis=$referenceAbis
  seed_swf_path=$seedEntryPath;seed_swf_size=$seedSize;seed_swf_sha256=$seedHash
  expected_seed_swf_size=$expectedSwfSize;expected_seed_swf_sha256=$expectedSwfSha
  data_entries=$dataCount;config_entries=$configCount
  base_only=$true
  profiles_entries=$profileEntries.Count
  selector_or_diagnostics_entries=$selectorEntries.Count
  root_swf_count=$rootSwfEntries.Count
  performance_patch_version=[string]$prov.performance_patch_version
  performance_source_swf_sha256=[string]$prov.swf_source_sha256
  performance_output_swf_sha256=[string]$performance.output_sha256
  performance_classes=@($performance.classes)
  performance_policy=$performance.policy
  signature=$signature;zipalign=$alignment
  build_tier=$buildTier;published_source_sha=[string]$prov.binary_seed_source_sha;game_version=[string]$prov.game_version
  failures=@($failures)
}
$reportPath=Join-Path $reportRoot 'apk-info.json'
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $reportPath -Encoding UTF8
$summaryPath=Join-Path $reportRoot 'summary.json'
[ordered]@{repository='Valverde-101/code-army-client';tested_sha=$ExpectedSha;apk_sha256=$apkSha;apk_validated=($failures.Count -eq 0);build_tier=$buildTier;game_version=[string]$prov.game_version;failures=@($failures)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $summaryPath -Encoding UTF8

$reportMd=Join-Path $reportRoot 'REPORT.md'
@(
  "# Army Attack Android validation","",
  "- TESTED_SHA: $ExpectedSha",
  "- game version: $($prov.game_version)",
  "- published source: $($prov.binary_seed_source_repository)@$($prov.binary_seed_source_sha)",
  "- APK: $ApkPath",
  "- APK_SHA256: $apkSha",
  "- package: $package",
  "- ABI: $($abis -join ',')",
  "- targetSdk: $targetSdk",
  "- SWF: $seedEntryPath",
  "- SWF_SHA256: $seedHash",
  "- performance patch: $($prov.performance_patch_version)",
  "- performance source SWF SHA256: $($prov.swf_source_sha256)",
  "- performance classes: $(@($performance.classes) -join ', ')",
  "- build tier: $buildTier",
  "- signature: $signature",
  "- zipalign: $alignment",
  "- validation failures: $($failures.Count)",
  $(if($failures.Count -gt 0){"- failures: $($failures -join '; ')"}else{"- failures: none"})
)|Set-Content -LiteralPath $reportMd -Encoding UTF8

Write-Host "APK_PATH=$ApkPath"
Write-Host "APK_SIZE=$($apk.Length)"
Write-Host "APK_SHA256=$apkSha"
Write-Host "PACKAGE_NAME=$package"
Write-Host "REFERENCE_PACKAGE_NAME=$referencePackage"
Write-Host "TARGET_SDK=$targetSdk"
Write-Host "REFERENCE_TARGET_SDK=$referenceTarget"
Write-Host "ABI=$($abis -join ',')"
Write-Host "REFERENCE_ABI=$($referenceAbis -join ',')"
Write-Host "SWF_PATH=$seedEntryPath"
Write-Host "SWF_SHA256=$seedHash"
Write-Host "SIGNATURE=$signature"
Write-Host "ZIPALIGN=$alignment"
Write-Host "BUILD_TIER=$buildTier"
Write-Host "GAME_VERSION=$($prov.game_version)"
Write-Host "BASE_ONLY_VALIDATE_STATE profiles=$($profileEntries.Count) selector_or_diagnostics=$($selectorEntries.Count) root_swf_count=$($rootSwfEntries.Count)"
Write-Host "PERFORMANCE_PATCH_VALIDATE_STATE version=$($prov.performance_patch_version) source_sha256=$($prov.swf_source_sha256) output_sha256=$seedHash classes=$(@($performance.classes).Count)"
Write-Host "PUBLISHED_SOURCE_SHA=$($prov.binary_seed_source_sha)"
Write-Host "APK_INFO=$reportPath"
Write-Host "REPORT=$reportMd"

if($failures.Count -gt 0){
  foreach($failure in $failures){Write-Host "APK_VALIDATE_FINDING=$failure"}
  throw "APK_VALIDATE=FAIL first=$($failures[0]) count=$($failures.Count)"
}

$candidateDir=Join-Path $reportRoot 'candidate'
New-Item -ItemType Directory -Force -Path $candidateDir|Out-Null
$promoted=Join-Path $candidateDir "ArmyAttack-23.2-$ExpectedSha.apk"
Copy-Item -LiteralPath $ApkPath -Destination $promoted -Force
$promotedSha=(Get-FileHash -LiteralPath $promoted -Algorithm SHA256).Hash.ToLowerInvariant()
if($promotedSha -ne $apkSha){throw "APK_PROMOTION=FAIL expected=$apkSha actual=$promotedSha"}
$meta=[ordered]@{tested_sha=$ExpectedSha;game_version='23.2';published_source_sha=[string]$prov.binary_seed_source_sha;apk_path=$promoted;apk_size=(Get-Item $promoted).Length;apk_sha256=$promotedSha;package_name=$package;build_tier=$buildTier}
"$promoted.json"|ForEach-Object{$meta|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $_ -Encoding UTF8}
if($env:GITHUB_ENV){"PROMOTED_CANDIDATE_PATH=$promoted"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append}
Write-Host "PERFORMANCE_PATCH_VALIDATE=PASS version=android-perf-v1 static_tick_ms=50 enemy_tick_ms=50 smoke_max=18"
Write-Host "BASE_ONLY_VALIDATE=PASS modern_v23_2=true profiles=0 selector=false diagnostics_ane=false root_swf=$seedEntryPath performance_patch=android-perf-v1"
Write-Host "APK_VALIDATE=PASS"
Write-Host "APK_PROMOTION=PASS path=$promoted sha256=$promotedSha"
& (Join-Path $PSScriptRoot 'Publish-ApkFinal.ps1') -SourceApk $promoted -AndroidBuildRoot $AndroidBuildRoot -ExpectedSha $ExpectedSha -RelativePath 'ArmyAttack-23.2.apk' -Kind 'base-23.2'
Write-Host "LISTA_PARA_PRUEBA_MANUAL=PASS"
