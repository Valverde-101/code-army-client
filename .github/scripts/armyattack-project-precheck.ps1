param([string]$ContextPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$root=@($env:ANDROIDBUILD_ROOT,'V:\AndroidBuild','D:\AndroidBuild','C:\AndroidBuild')|Where-Object{$_ -and (Test-Path -LiteralPath $_ -PathType Container)}|Select-Object -First 1
if(-not $root){throw 'ARMY_PROJECT_PRECHECK=FAIL androidbuild_root_not_found'}
$root=(Resolve-Path -LiteralPath $root).Path
$manifest=Join-Path $root 'Core\Current\AndroidBuild.psd1'
if(-not(Test-Path -LiteralPath $manifest -PathType Leaf)){throw "ARMY_PROJECT_PRECHECK=FAIL core_manifest_missing=$manifest"}
Import-Module $manifest -DisableNameChecking -Force
$core=[version](Get-AndroidBuildCoreVersion)
if($core -lt [version]'3.0.9'){throw "ARMY_PROJECT_PRECHECK=FAIL core=$core minimum=3.0.9"}
foreach($command in @(
  'Resolve-AndroidBuildFlashToolchain','Ensure-AndroidBuildFFDec','Ensure-AndroidBuildHarmanAirSdk','Ensure-AndroidBuildPortableJdk17','Ensure-AndroidBuildPinnedAndroidSdkView',
  'Sync-AndroidBuildRepositoryExactHead','Invoke-AndroidBuildProcess','Reduce-AndroidBuildEvidence','Protect-AndroidBuildEvidence','Publish-AndroidBuildEvidence','Publish-AndroidBuildEvidenceCommit'
)){
  if(-not(Get-Command $command -ErrorAction SilentlyContinue)){throw "ARMY_PROJECT_PRECHECK=FAIL core_capability_missing=$command"}
}
$configPath=Join-Path $repoRoot '.androidbuild.json'
if(-not(Test-Path -LiteralPath $configPath)){throw 'ARMY_PROJECT_PRECHECK=FAIL config_missing'}
$cfg=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
if([string]$cfg.schema -ne 'androidbuild-project/v3'){throw "ARMY_PROJECT_PRECHECK=FAIL schema=$($cfg.schema)"}
if([string]$cfg.project.id -ne 'army-attack' -or [string]$cfg.project.repository -ne 'Valverde-101/code-army-client'){throw 'ARMY_PROJECT_PRECHECK=FAIL project_identity'}
if([string]$cfg.hooks.build -ne '.github/scripts/armyattack-build.ps1'){throw "ARMY_PROJECT_PRECHECK=FAIL build_hook=$($cfg.hooks.build)"}
if([string]$cfg.apk.package_name -ne 'air.army.attack'){throw "ARMY_PROJECT_PRECHECK=FAIL package=$($cfg.apk.package_name)"}
if([string]$cfg.apk.explicit_output -ne '.work/artifacts/android/ArmyAttack.apk'){throw "ARMY_PROJECT_PRECHECK=FAIL apk_output=$($cfg.apk.explicit_output)"}
if([string]$cfg.delivery.final_apk_name -ne 'ArmyAttack-23.2.apk'){throw "ARMY_PROJECT_PRECHECK=FAIL final_apk_name=$($cfg.delivery.final_apk_name)"}
if([string]$cfg.core.minimum_version -ne '3.0.9'){throw "ARMY_PROJECT_PRECHECK=FAIL core_contract=$($cfg.core.minimum_version)"}
if([string]$cfg.migration.mode -ne 'complete-core-orchestrated' -or [string]$cfg.migration.status -ne 'COMPLETE'){throw "ARMY_PROJECT_PRECHECK=FAIL migration_mode=$($cfg.migration.mode) status=$($cfg.migration.status)"}
if([bool]$cfg.migration.preserve_legacy_until_equivalence){throw 'ARMY_PROJECT_PRECHECK=FAIL migration_still_progressive'}
if(-not [bool]$cfg.migration.global_core_candidate_orchestration -or -not [bool]$cfg.migration.global_repository_sync -or -not [bool]$cfg.migration.global_flash_toolchain -or -not [bool]$cfg.migration.global_broker_ownership -or -not [bool]$cfg.migration.global_apk_final_gate){throw 'ARMY_PROJECT_PRECHECK=FAIL global_ownership_contract'}
if([bool]$cfg.broker.repository_owned_broker_mutation){throw 'ARMY_PROJECT_PRECHECK=FAIL repository_owned_broker_mutation'}
if([string]$cfg.physical.activation -ne 'manual_workflow_dispatch'){throw "ARMY_PROJECT_PRECHECK=FAIL physical_activation=$($cfg.physical.activation)"}
if([string]$cfg.validation.publish_final_apk_after -ne 'PHYSICALLY_VALIDATED'){throw "ARMY_PROJECT_PRECHECK=FAIL final_apk_gate=$($cfg.validation.publish_final_apk_after)"}
if([int]$cfg.evidence.keep_runs_global -ne 3){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_keep_runs=$($cfg.evidence.keep_runs_global)"}
if([int]$cfg.evidence.max_files_per_run -ne 200){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_max_files=$($cfg.evidence.max_files_per_run)"}
if([int64]$cfg.evidence.max_total_bytes_per_run -ne 26214400){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_max_total_bytes=$($cfg.evidence.max_total_bytes_per_run)"}
if([int64]$cfg.evidence.max_file_bytes -ne 8388608){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_max_file_bytes=$($cfg.evidence.max_file_bytes)"}
if([int]$cfg.evidence.max_screenshots -ne 8){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_max_screenshots=$($cfg.evidence.max_screenshots)"}
$required=@(
  'Tools\CI\Build-Android.ps1','Tools\CI\Validate-AndroidApk.ps1','Tools\CI\Publish-ApkFinal.ps1','Tools\CI\Audit-PublishedContent.ps1','Tools\CI\Validate-UpstreamAndroidRelease.ps1',
  'Tools\CI\Patch-AndroidPerformanceSwf.ps1','Tools\CI\Build-AndroidDiagnosticsAne.ps1','Tools\CI\Test-AndroidRuntimePatch.ps1','Tools\CI\Test-AndroidDevice.ps1','Tools\CI\Analyze-AndroidRuntimeDiagnostics.ps1','Tools\SWF\Ensure-FFDec.ps1',
  'Tools\CI\Ensure-HarmanAir502.ps1','Tools\CI\Ensure-PortableJdk17.ps1','Tools\CI\Ensure-PinnedAndroidSdkRoot.ps1',
  '.github\workflows\android-candidate.yml','.github\workflows\android-physical.yml','.github\workflows\evidence-only.yml','src','.gitmodules'
)
foreach($relative in $required){if(-not(Test-Path -LiteralPath (Join-Path $repoRoot $relative))){throw "ARMY_PROJECT_PRECHECK=FAIL missing=$relative"}}
$retired=@(
  'Tools\CI\Bootstrap-PhysicalClone.ps1','Tools\CI\Enable-AutoRepoPool4.ps1','Tools\CI\Start-AutoRepoPool4.runtime.ps1',
  '.github\workflows\enable-autorepo-pool4.yml','.github\workflows\cancel-stale-android.yml','.github\workflows\runner-pool-diagnostic.yml'
)
foreach($relative in $retired){if(Test-Path -LiteralPath (Join-Path $repoRoot $relative)){throw "ARMY_PROJECT_PRECHECK=FAIL retired_infrastructure_present=$relative"}}
$gitmodules=Get-Content -LiteralPath (Join-Path $repoRoot '.gitmodules') -Raw
if($gitmodules -notmatch 'vendor/Test_army_attack'){throw 'ARMY_PROJECT_PRECHECK=FAIL published_submodule_contract_missing'}

$candidateWorkflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\android-candidate.yml') -Raw
foreach($legacy in @('Enable-AutoRepoPool4.ps1','Start-AutoRepoPool4.runtime.ps1','Bootstrap-PhysicalClone.ps1')){
  if($candidateWorkflow.Contains($legacy)){throw "ARMY_PROJECT_PRECHECK=FAIL legacy_infrastructure_still_invoked=$legacy"}
}
if(-not $candidateWorkflow.Contains("paths-ignore:") -or -not $candidateWorkflow.Contains("'Logs/**'")){throw 'ARMY_PROJECT_PRECHECK=FAIL candidate_does_not_ignore_evidence_only_commits'}

$physicalWorkflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\android-physical.yml') -Raw
if($physicalWorkflow -match '(?m)^\s*push\s*:'){throw 'ARMY_PROJECT_PRECHECK=FAIL physical_workflow_not_manual_only'}
foreach($needle in @(
  'contents: write','same_pr_evidence_requires_feature_branch','.work\evidence-staging','Reduce-AndroidBuildEvidence','Publish-AndroidBuildEvidence','Publish-AndroidBuildEvidenceCommit',
  'TESTED_SHA=','EVIDENCE_COMMIT_SHA=','PHYSICAL_TRUTH=','-PhysicalValidated','delivery.final_apk_name','FINAL_VALIDATION=PASS physical_validation=PASS evidence=PASS apk_final=PASS'
)){
  if(-not $physicalWorkflow.Contains($needle)){throw "ARMY_PROJECT_PRECHECK=FAIL physical_contract_missing=$needle"}
}
if($physicalWorkflow.Contains('no_authorized_device') -and -not $physicalWorkflow.Contains('PHYSICAL_TRUTH')){throw 'ARMY_PROJECT_PRECHECK=FAIL physical_skip_can_bypass_truth_gate'}

$evidenceWorkflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\evidence-only.yml') -Raw
if($evidenceWorkflow.Contains('chore/local-army-bootstrap-20260827')){throw 'ARMY_PROJECT_PRECHECK=FAIL evidence_workflow_hardcoded_legacy_branch'}
foreach($needle in @('Logs/physical-adb','EVIDENCE_RETENTION=FAIL','EVIDENCE_MANIFEST=PASS','maximum=200','maximum=26214400','maximum=8388608','maximum=8')){
  if(-not $evidenceWorkflow.Contains($needle)){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_verifier_missing=$needle"}
}

$publisher=Get-Content -LiteralPath (Join-Path $repoRoot 'Tools\CI\Publish-ApkFinal.ps1') -Raw
if(-not $publisher.Contains('[switch]$PhysicalValidated') -or -not $publisher.Contains('APK_FINAL_PUBLICATION=DEFERRED_UNTIL_PHYSICAL_VALIDATION')){throw 'ARMY_PROJECT_PRECHECK=FAIL apk_final_publisher_gate_missing'}
if(-not $publisher.Contains('delivery.final_apk_name')){throw 'ARMY_PROJECT_PRECHECK=FAIL apk_final_ownership_not_config_driven'}
if($publisher.Contains('c3ec09fff4c06da08aeebdd070bf570534cd4fbe') -or $publisher.Contains('Remove-PrematureMigrationFinal')){throw 'ARMY_PROJECT_PRECHECK=FAIL one_shot_migration_cleanup_still_present'}

Write-Host "ARMY_PROJECT_PRECHECK=PASS repository=Valverde-101/code-army-client core_min=3.0.9 tested_core=$core adapter=repo-hooks flash_toolchain=androidbuild-global migration=COMPLETE physical_activation=manual evidence_publisher=androidbuild-core evidence_contract=canonical apk_final_gate=physical_pass_only"
