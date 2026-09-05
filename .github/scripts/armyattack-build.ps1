param([Parameter(Mandatory=$true)][string]$ContextPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$ctx=Get-Content -LiteralPath $ContextPath -Raw|ConvertFrom-Json
$repoRoot=[string]$ctx.repo_root
$root=[string]$ctx.androidbuild_root
$expected=[string]$ctx.expected_sha
if(-not $repoRoot -or -not $root -or $expected -notmatch '^[a-f0-9]{40}$'){throw 'ARMY_BUILD_HOOK=FAIL invalid_context'}
$repoRoot=(Resolve-Path -LiteralPath $repoRoot).Path
$root=(Resolve-Path -LiteralPath $root).Path
Import-Module (Join-Path $root 'Core\Current\AndroidBuild.psd1') -DisableNameChecking -Force
$core=[version](Get-AndroidBuildCoreVersion)
if($core -lt [version]'3.0.9'){throw "ARMY_BUILD_HOOK=FAIL core=$core minimum=3.0.9"}
$identity=Test-AndroidBuildExactHead -RepoRoot $repoRoot -ExpectedSha $expected -AndroidBuildRoot $root
if([string]$identity.status -ne 'PASS' -or [string]$identity.actual -ne $expected){throw "ARMY_BUILD_HOOK=FAIL repo_head expected=$expected actual=$($identity.actual)"}
Write-Host 'ARMY_REPO_EXACT_HEAD=PASS'
Initialize-AndroidBuildProjectWork $repoRoot|Out-Null
$git=Get-AndroidBuildGitPath $root

# Materialize the published v23.2 source dependency at the exact gitlink revision.
$submoduleSync=Invoke-AndroidBuildProcess -FilePath $git -ArgumentList @('-C',$repoRoot,'submodule','sync','--','vendor/Test_army_attack') -WorkingDirectory $repoRoot -TimeoutSeconds 60 -AllowNonZeroExit -StreamOutput
if($submoduleSync.exit_code -ne 0){throw "ARMY_PUBLISHED_SOURCE=FAIL submodule_sync exit=$($submoduleSync.exit_code)"}
$submoduleUpdate=Invoke-AndroidBuildProcess -FilePath $git -ArgumentList @('-C',$repoRoot,'submodule','update','--init','--recursive','--','vendor/Test_army_attack') -WorkingDirectory $repoRoot -TimeoutSeconds 900 -AllowNonZeroExit -StreamOutput
if($submoduleUpdate.exit_code -ne 0){throw "ARMY_PUBLISHED_SOURCE=FAIL submodule_update exit=$($submoduleUpdate.exit_code)"}
$publishedRoot=Join-Path $repoRoot 'vendor\Test_army_attack'
$publishedSha=(& $git -C $publishedRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $publishedSha -ne '306bccc7db5b1ce34dd68a3bc80093648c9224bd'){throw "ARMY_PUBLISHED_SOURCE=FAIL expected=306bccc7db5b1ce34dd68a3bc80093648c9224bd actual=$publishedSha"}
Write-Host "ARMY_PUBLISHED_SOURCE=PASS sha=$publishedSha"

# Resolve shared AndroidBuild-owned Flash/AIR tooling. No binary tool is owned by Army Attack.
$tc=Resolve-AndroidBuildFlashToolchain -AndroidBuildRoot $root -AirVersion '50.2.3.6' -FfdecVersion '26.2.1' -TargetApi '33' -BuildTools '33.0.2' -PinnedToolchainId 'AIR50-API33-BT33.0.2'
if([string]$tc.status -ne 'PASS'){throw 'ARMY_FLASH_TOOLCHAIN=FAIL resolver'}
$env:JAVA_HOME=[string]$tc.java_home
$env:AIR_HOME=[string]$tc.air_home
$env:PATH=(Join-Path $env:JAVA_HOME 'bin')+';'+$env:PATH
Write-Host "ARMY_FLASH_TOOLCHAIN=PASS core=$core java=$($tc.java_major) air=$($tc.air_version) ffdec=$($tc.ffdec_version) api=$($tc.target_api) build_tools=$($tc.build_tools) ownership=androidbuild-global"

function Remove-JunctionSafe([string]$Path){
  if(-not(Test-Path -LiteralPath $Path)){return}
  $item=Get-Item -LiteralPath $Path -Force
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){
    $cmd=(Get-Command cmd.exe -ErrorAction Stop).Source
    & $cmd /d /c ('rmdir "{0}"' -f $Path)|Out-Null
    if($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $Path)){throw "ARMY_COMPAT_ALIAS=FAIL rmdir=$Path exit=$LASTEXITCODE"}
  }else{Remove-Item -LiteralPath $Path -Recurse -Force}
}
function Ensure-Junction([string]$Path,[string]$Target){
  $targetFull=[IO.Path]::GetFullPath($Target).TrimEnd('\')
  if(Test-Path -LiteralPath $Path){
    $item=Get-Item -LiteralPath $Path -Force
    $current=$null;try{$current=$item.Target;if($current -is [array]){$current=$current|Select-Object -First 1}}catch{}
    if($current -and ([IO.Path]::GetFullPath([string]$current).TrimEnd('\') -ieq $targetFull)){return}
    Remove-JunctionSafe $Path
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)|Out-Null
  New-Item -ItemType Junction -Path $Path -Target $targetFull|Out-Null
}

# Compatibility alias for Army's project-specific SWF patcher. Bytes remain globally Core-owned.
$ffdecGlobal=Join-Path $root 'Tools\FFDec\26.2.1'
$ffdecCompat=Join-Path $repoRoot '.work\tools\ffdec'
Ensure-Junction $ffdecCompat $ffdecGlobal
$ffdecCompatExe=Get-ChildItem -LiteralPath $ffdecCompat -File -ErrorAction Stop|Where-Object{$_.Name -in @('ffdec-cli.exe','ffdec.bat','ffdec.jar')}|Select-Object -First 1
if(-not $ffdecCompatExe){throw "ARMY_FFDEC_COMPAT=FAIL unreadable_alias=$ffdecCompat"}
Write-Host "ARMY_FFDEC_COMPAT=PASS alias=$ffdecCompat target=$ffdecGlobal executable=$($ffdecCompatExe.Name) duplicated_bytes=false"

# Keep Army build bytes inside the repository .work pool while retaining a compatibility path for project scripts.
$repoBuildRoot=Join-Path $repoRoot '.work\Builds\code-army-client'
$legacyBuildRoot=Join-Path $root 'Builds\code-army-client'
New-Item -ItemType Directory -Force -Path $repoBuildRoot|Out-Null
if(Test-Path -LiteralPath $legacyBuildRoot){
  $legacyItem=Get-Item -LiteralPath $legacyBuildRoot -Force
  if(-not($legacyItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){
    $dirs=@(Get-ChildItem -LiteralPath $legacyBuildRoot -Directory -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 3)
    foreach($dir in $dirs){$dest=Join-Path $repoBuildRoot $dir.Name;if(-not(Test-Path -LiteralPath $dest)){Move-Item -LiteralPath $dir.FullName -Destination $dest}}
  }
}
Ensure-Junction $legacyBuildRoot $repoBuildRoot
Write-Host "ARMY_BUILD_WORKSPACE=PASS canonical=$repoBuildRoot compatibility_alias=$legacyBuildRoot"

# HARMAN AIR 50 needs this view; point it at Core's pinned SDK instead of copying SDK bytes.
$air50Compat=Join-Path $root 'Tools\AndroidSDK-AIR50-api33'
Ensure-Junction $air50Compat ([string]$tc.android_sdk)
$platformJar=Join-Path ([string]$tc.android_sdk) 'platforms\android-33\android.jar'
$aapt2=Join-Path ([string]$tc.android_sdk) 'build-tools\33.0.2\aapt2.exe'
$marker=[ordered]@{api=33;build_tools='33.0.2';source_sdk=(Join-Path $root 'AndroidSDK');platform_jar_sha256=(Get-FileHash $platformJar -Algorithm SHA256).Hash.ToLowerInvariant();aapt2_sha256=(Get-FileHash $aapt2 -Algorithm SHA256).Hash.ToLowerInvariant();purpose='AndroidBuild Core 3.0.9 shared HARMAN AIR50 pinned SDK view'}
$marker|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $air50Compat 'AIR50-SDK-MANIFEST.json') -Encoding UTF8
Write-Host "ARMY_AIR50_SDK_COMPAT=PASS alias=$air50Compat target=$($tc.android_sdk) duplicated_bytes=false"

# Preserve Army-specific audits and application semantics; infrastructure is Core-owned.
& (Join-Path $repoRoot 'Tools\CI\Audit-PublishedContent.ps1') -RepoRoot $repoRoot -AndroidBuildRoot $root -ExpectedSha $expected -BaseOnly
& (Join-Path $repoRoot 'Tools\CI\Validate-UpstreamAndroidRelease.ps1') -AndroidBuildRoot $root -ExpectedSha $expected

$projectBuilder=Join-Path $repoRoot 'Tools\CI\Build-Android.ps1'
Write-Host "ARMY_APPLICATION_BUILD=START adapter=army-project-builder infrastructure=core-3.0.9 render=gpu"
& $projectBuilder -RepoRoot $repoRoot -ExpectedSha $expected -AndroidBuildRoot ([string]$tc.pinned_android_build_root) -RenderMode gpu
Write-Host 'ARMY_APPLICATION_BUILD=PASS'

$buildRoot=Join-Path $repoBuildRoot (Join-Path $expected 'android')
$builtApk=Join-Path $buildRoot 'ArmyAttack-android-arm64-gpu.apk'
if(-not(Test-Path -LiteralPath $builtApk -PathType Leaf)){throw "ARMY_BUILD_HOOK=FAIL apk_missing=$builtApk"}
& (Join-Path $repoRoot 'Tools\CI\Validate-AndroidApk.ps1') -ApkPath $builtApk -AndroidBuildRoot $root -ExpectedSha $expected -ExpectedRenderMode gpu
Write-Host 'ARMY_DEEP_APK_VALIDATION=PASS'

$artifactRoot=Join-Path $repoRoot '.work\artifacts\android'
New-Item -ItemType Directory -Force -Path $artifactRoot|Out-Null
$candidate=Join-Path $artifactRoot 'ArmyAttack.apk'
Copy-Item -LiteralPath $builtApk -Destination $candidate -Force
$sourceHash=(Get-FileHash -LiteralPath $builtApk -Algorithm SHA256).Hash.ToUpperInvariant()
$candidateHash=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToUpperInvariant()
if($sourceHash -ne $candidateHash){throw "ARMY_BUILD_HOOK=FAIL candidate_hash expected=$sourceHash actual=$candidateHash"}

$manual=[ordered]@{schema='armyattack-manual-physical/v3';repository='Valverde-101/code-army-client';tested_sha=$expected;candidate_apk=$candidate;apk_sha256=$candidateHash;status='PENDING_USER_VALIDATION';adb_used=$false;required=$true;flows=@('cold_launch','home_map_navigation','unit_placement_confirm_cancel','right_hud_open_close','supply_aircraft','world_map_open_close','desert_map','pvp_match_start','pvp_cancel_action','pvp_firemission','pvp_paratrooper','pvp_loot_debrief','diagnostics_perf','diagnostics_mark_lag','diagnostics_zip','crash_anr_check')}
$manualPath=Join-Path $artifactRoot 'manual-physical-validation.json'
$manual|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manualPath -Encoding UTF8
$metadata=[ordered]@{schema='armyattack-build-hook/v2';source_sha=$expected;core_version=[string]$core;toolchain_ownership='androidbuild-global';air_version=[string]$tc.air_version;ffdec_version=[string]$tc.ffdec_version;java_major=[string]$tc.java_major;android_api=[string]$tc.target_api;android_build_tools=[string]$tc.build_tools;application_builder='Tools/CI/Build-Android.ps1';migration_mode='complete-core-orchestrated';candidate_apk=$candidate;apk_sha256=$candidateHash;published_source_sha=$publishedSha;physical_validation='NOT_ACTIVATED';final_validation='VALIDATION_INCOMPLETE'}
$metaPath=Join-Path $artifactRoot 'armyattack-build.json'
$metadata|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $metaPath -Encoding UTF8
Write-Host "ARMY_CANDIDATE_APK=PASS path=$candidate sha256=$candidateHash"
Write-Host "ARMY_BUILD_METADATA=PASS path=$metaPath"
Write-Host 'ARMY_CORE_MIGRATION=PASS mode=complete-core-orchestrated toolchain=androidbuild-global broker=androidbuild-global repository_sync=androidbuild-core'
Write-Host "PHYSICAL_VALIDATION=NOT_ACTIVATED manual=$manualPath"
Write-Host 'APK_FINAL_PUBLICATION=DEFERRED_UNTIL_PHYSICAL_VALIDATION'
Write-Host 'ARMY_BUILD_HOOK=PASS'
