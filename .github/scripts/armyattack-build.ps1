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
if($core -lt [version]'3.0.11'){throw "ARMY_BUILD_HOOK=FAIL core=$core minimum=3.0.11"}
$identity=Test-AndroidBuildExactHead -RepoRoot $repoRoot -ExpectedSha $expected -AndroidBuildRoot $root
if([string]$identity.status -ne 'PASS' -or [string]$identity.actual -ne $expected){throw "ARMY_BUILD_HOOK=FAIL repo_head expected=$expected actual=$($identity.actual)"}
Write-Host 'ARMY_REPO_EXACT_HEAD=PASS'
Initialize-AndroidBuildProjectWork $repoRoot|Out-Null
$git=Get-AndroidBuildGitPath $root

# Materialize the exact published v23.2 source dependency.
$submoduleSync=Invoke-AndroidBuildProcess -FilePath $git -ArgumentList @('-C',$repoRoot,'submodule','sync','--','vendor/Test_army_attack') -WorkingDirectory $repoRoot -TimeoutSeconds 60 -AllowNonZeroExit -StreamOutput
if($submoduleSync.exit_code -ne 0){throw "ARMY_PUBLISHED_SOURCE=FAIL submodule_sync exit=$($submoduleSync.exit_code)"}
$submoduleUpdate=Invoke-AndroidBuildProcess -FilePath $git -ArgumentList @('-C',$repoRoot,'submodule','update','--init','--recursive','--','vendor/Test_army_attack') -WorkingDirectory $repoRoot -TimeoutSeconds 900 -AllowNonZeroExit -StreamOutput
if($submoduleUpdate.exit_code -ne 0){throw "ARMY_PUBLISHED_SOURCE=FAIL submodule_update exit=$($submoduleUpdate.exit_code)"}
$publishedRoot=Join-Path $repoRoot 'vendor\Test_army_attack'
$publishedSha=(& $git -C $publishedRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $publishedSha -ne '306bccc7db5b1ce34dd68a3bc80093648c9224bd'){throw "ARMY_PUBLISHED_SOURCE=FAIL expected=306bccc7db5b1ce34dd68a3bc80093648c9224bd actual=$publishedSha"}
Write-Host "ARMY_PUBLISHED_SOURCE=PASS sha=$publishedSha"

# Global reusable toolchain remains AndroidBuild-owned.
$tc=Resolve-AndroidBuildFlashToolchain -AndroidBuildRoot $root -AirVersion '50.2.3.6' -FfdecVersion '26.2.1' -TargetApi '33' -BuildTools '33.0.2' -PinnedToolchainId 'AIR50-API33-BT33.0.2'
if([string]$tc.status -ne 'PASS'){throw 'ARMY_FLASH_TOOLCHAIN=FAIL resolver'}
$env:JAVA_HOME=[string]$tc.java_home
$env:AIR_HOME=[string]$tc.air_home
$env:PATH=(Join-Path $env:JAVA_HOME 'bin')+';'+$env:PATH
Write-Host "ARMY_FLASH_TOOLCHAIN=PASS core=$core java=$($tc.java_major) air=$($tc.air_version) ffdec=$($tc.ffdec_version) api=$($tc.target_api) build_tools=$($tc.build_tools) ownership=androidbuild-global"

# Project state is repository-owned under .work. The runtime facade preserves legacy script contracts without external state.
$workspaceScript=Join-Path $repoRoot '.github\scripts\armyattack-workspace.ps1'
if(-not(Test-Path -LiteralPath $workspaceScript)){throw "ARMY_WORKSPACE=FAIL helper_missing=$workspaceScript"}
. $workspaceScript
$workspace=Initialize-ArmyAttackWorkspace -RepoRoot $repoRoot -AndroidBuildRoot $root -PinnedAndroidBuildRoot ([string]$tc.pinned_android_build_root) -ExpectedSha $expected -AirHome ([string]$tc.air_home) -AndroidSdk ([string]$tc.android_sdk) -RetentionGenerations 3
$runtimeRoot=[string]$workspace.runtime_root
$repoBuildRoot=[string]$workspace.build_root

# FFDec executable bytes remain global. Army exposes only a repo-local junction for its SWF patcher.
$ffdecGlobal=Join-Path $root 'Tools\FFDec\26.2.1'
$ffdecCompat=Join-Path $repoRoot '.work\tools\ffdec'
Ensure-ArmyJunction -Path $ffdecCompat -Target $ffdecGlobal
$ffdecCompatExe=Get-ChildItem -LiteralPath $ffdecCompat -File -ErrorAction Stop|Where-Object{$_.Name -in @('ffdec-cli.exe','ffdec.bat','ffdec.jar')}|Select-Object -First 1
if(-not $ffdecCompatExe){throw "ARMY_FFDEC_COMPAT=FAIL unreadable_alias=$ffdecCompat"}
Write-Host "ARMY_FFDEC_COMPAT=PASS alias=$ffdecCompat target=$ffdecGlobal executable=$($ffdecCompatExe.Name) duplicated_bytes=false"

# Army-specific audits/builds run against the repo-local compatibility root.
& (Join-Path $repoRoot 'Tools\CI\Audit-PublishedContent.ps1') -RepoRoot $repoRoot -AndroidBuildRoot $runtimeRoot -ExpectedSha $expected -BaseOnly
& (Join-Path $repoRoot 'Tools\CI\Validate-UpstreamAndroidRelease.ps1') -AndroidBuildRoot $runtimeRoot -ExpectedSha $expected

$projectBuilder=Join-Path $repoRoot 'Tools\CI\Build-Android.ps1'
Write-Host "ARMY_APPLICATION_BUILD=START adapter=army-project-builder infrastructure=core-$core workspace=repo-work render=gpu"
& $projectBuilder -RepoRoot $repoRoot -ExpectedSha $expected -AndroidBuildRoot $runtimeRoot -RenderMode gpu
Write-Host 'ARMY_APPLICATION_BUILD=PASS'

$buildRoot=Join-Path $repoBuildRoot (Join-Path $expected 'android')
$builtApk=Join-Path $buildRoot 'ArmyAttack-android-arm64-gpu.apk'
if(-not(Test-Path -LiteralPath $builtApk -PathType Leaf)){throw "ARMY_BUILD_HOOK=FAIL apk_missing=$builtApk"}
& (Join-Path $repoRoot 'Tools\CI\Validate-AndroidApk.ps1') -ApkPath $builtApk -AndroidBuildRoot $runtimeRoot -ExpectedSha $expected -ExpectedRenderMode gpu
Write-Host 'ARMY_DEEP_APK_VALIDATION=PASS'

$artifactRoot=Join-Path $repoRoot '.work\artifacts\android'
New-Item -ItemType Directory -Force -Path $artifactRoot|Out-Null
$candidate=Join-Path $artifactRoot 'ArmyAttack.apk'
Copy-Item -LiteralPath $builtApk -Destination $candidate -Force
$sourceHash=(Get-FileHash -LiteralPath $builtApk -Algorithm SHA256).Hash.ToUpperInvariant()
$candidateHash=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToUpperInvariant()
if($sourceHash -ne $candidateHash){throw "ARMY_BUILD_HOOK=FAIL candidate_hash expected=$sourceHash actual=$candidateHash"}

Invoke-ArmyAttackBuildRetention -BuildRoot $repoBuildRoot -ExpectedSha $expected -Keep 3
if(Test-Path -LiteralPath ([string]$workspace.scratch_current)){Remove-Item -LiteralPath ([string]$workspace.scratch_current) -Recurse -Force}
New-Item -ItemType Directory -Force -Path ([string]$workspace.scratch_current)|Out-Null
Write-Host "ARMY_SCRATCH_CLEANUP=PASS path=$($workspace.scratch_current) reusable=false"

# External Army-specific state must be absent after migration. Global tools/Core/Project-Sources/APK-FINAL remain outside .work by design.
$forbiddenRoots=@($root,[string]$tc.pinned_android_build_root,(Split-Path -Parent ([string]$tc.pinned_android_build_root)))|Select-Object -Unique
foreach($legacyRoot in $forbiddenRoots){
  foreach($relative in @('Builds\code-army-client','Inputs\code-army-client')){
    $path=Join-Path $legacyRoot $relative
    if(Test-Path -LiteralPath $path){throw "ARMY_WORKSPACE_ISOLATION=FAIL external_project_state=$path"}
  }
}
Write-Host 'ARMY_WORKSPACE_ISOLATION=PASS builds=repo-work inputs=repo-cache scratch=repo-work global_tools_only_outside=true'

$manual=[ordered]@{schema='armyattack-manual-physical/v3';repository='Valverde-101/code-army-client';tested_sha=$expected;candidate_apk=$candidate;apk_sha256=$candidateHash;status='PENDING_USER_VALIDATION';adb_used=$false;required=$true;flows=@('cold_launch','home_map_navigation','unit_placement_confirm_cancel','right_hud_open_close','supply_aircraft','world_map_open_close','desert_map','pvp_match_start','pvp_cancel_action','pvp_firemission','pvp_paratrooper','pvp_loot_debrief','diagnostics_perf','diagnostics_mark_lag','diagnostics_zip','crash_anr_check')}
$manualPath=Join-Path $artifactRoot 'manual-physical-validation.json'
$manual|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manualPath -Encoding UTF8
$metadata=[ordered]@{
  schema='armyattack-build-hook/v3'
  source_sha=$expected
  core_version=[string]$core
  toolchain_ownership='androidbuild-global'
  air_version=[string]$tc.air_version
  ffdec_version=[string]$tc.ffdec_version
  java_major=[string]$tc.java_major
  android_api=[string]$tc.target_api
  android_build_tools=[string]$tc.build_tools
  application_builder='Tools/CI/Build-Android.ps1'
  migration_mode='complete-core-orchestrated'
  workspace=[ordered]@{work_root=[string]$workspace.work_root;build_root=[string]$workspace.build_root;input_cache_root=[string]$workspace.input_cache_root;scratch_root=[string]$workspace.scratch_root;runtime_root=$runtimeRoot;retention_generations=3}
  candidate_apk=$candidate
  apk_sha256=$candidateHash
  published_source_sha=$publishedSha
  physical_validation='NOT_ACTIVATED'
  final_validation='VALIDATION_INCOMPLETE'
}
$metaPath=Join-Path $artifactRoot 'armyattack-build.json'
$metadata|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $metaPath -Encoding UTF8
Write-Host "ARMY_CANDIDATE_APK=PASS path=$candidate sha256=$candidateHash"
Write-Host "ARMY_BUILD_METADATA=PASS path=$metaPath"
Write-Host 'ARMY_CORE_MIGRATION=PASS mode=complete-core-orchestrated toolchain=androidbuild-global broker=androidbuild-global repository_sync=androidbuild-core project_state=repo-work'
Write-Host "PHYSICAL_VALIDATION=NOT_ACTIVATED manual=$manualPath"
Write-Host 'APK_FINAL_DELIVERY=CORE_CANDIDATE_VALIDATION_PENDING'
Write-Host 'ARMY_BUILD_HOOK=PASS'
