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
if($core -lt [version]'3.0.11'){throw "ARMY_PROJECT_PRECHECK=FAIL core=$core minimum=3.0.11"}
foreach($command in @(
  'Resolve-AndroidBuildFlashToolchain','Ensure-AndroidBuildFFDec','Ensure-AndroidBuildHarmanAirSdk','Ensure-AndroidBuildPortableJdk17','Ensure-AndroidBuildPinnedAndroidSdkView',
  'Sync-AndroidBuildRepositoryExactHead','Invoke-AndroidBuildProcess','Reduce-AndroidBuildEvidence','Protect-AndroidBuildEvidence','Publish-AndroidBuildEvidence','Publish-AndroidBuildEvidenceCommit','Publish-AndroidBuildFinalApk'
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
if([string]$cfg.delivery.mode -ne 'candidate-build-to-apk-final-plus-manual-physical-validation'){throw "ARMY_PROJECT_PRECHECK=FAIL delivery_mode=$($cfg.delivery.mode)"}
if([string]$cfg.core.minimum_version -ne '3.0.11'){throw "ARMY_PROJECT_PRECHECK=FAIL core_contract=$($cfg.core.minimum_version)"}
if([string]$cfg.core.tested_installed_version -ne '3.0.11'){throw "ARMY_PROJECT_PRECHECK=FAIL tested_core_contract=$($cfg.core.tested_installed_version)"}
if([string]$cfg.migration.mode -ne 'complete-core-orchestrated' -or [string]$cfg.migration.status -ne 'COMPLETE'){throw "ARMY_PROJECT_PRECHECK=FAIL migration_mode=$($cfg.migration.mode) status=$($cfg.migration.status)"}
if([bool]$cfg.migration.preserve_legacy_until_equivalence){throw 'ARMY_PROJECT_PRECHECK=FAIL migration_still_progressive'}
if(-not [bool]$cfg.migration.global_core_candidate_orchestration -or -not [bool]$cfg.migration.global_repository_sync -or -not [bool]$cfg.migration.global_flash_toolchain -or -not [bool]$cfg.migration.global_broker_ownership -or -not [bool]$cfg.migration.global_apk_final_gate -or -not [bool]$cfg.migration.global_evidence_publisher){throw 'ARMY_PROJECT_PRECHECK=FAIL global_ownership_contract'}
if([string]$cfg.migration.windows_candidate_workflow -ne '.github/workflows/windows-candidate.yml'){throw "ARMY_PROJECT_PRECHECK=FAIL windows_candidate_workflow=$($cfg.migration.windows_candidate_workflow)"}
if([string]$cfg.migration.workspace_adapter -ne '.github/scripts/armyattack-workspace.ps1'){throw "ARMY_PROJECT_PRECHECK=FAIL workspace_adapter=$($cfg.migration.workspace_adapter)"}
if([string]$cfg.migration.project_state_canonical_root -ne '.work' -or -not [bool]$cfg.migration.external_builds_inputs_scratch_retired){throw 'ARMY_PROJECT_PRECHECK=FAIL project_state_migration_contract'}
if([bool]$cfg.broker.repository_owned_broker_mutation){throw 'ARMY_PROJECT_PRECHECK=FAIL repository_owned_broker_mutation'}
if([string]$cfg.physical.activation -ne 'manual_workflow_dispatch'){throw "ARMY_PROJECT_PRECHECK=FAIL physical_activation=$($cfg.physical.activation)"}
if(-not [bool]$cfg.physical.required){throw 'ARMY_PROJECT_PRECHECK=FAIL physical_required_must_remain_true'}
if([bool]$cfg.physical.final_apk_requires_physical_pass){throw 'ARMY_PROJECT_PRECHECK=FAIL candidate_apk_delivery_still_physical_gated'}
if([string]$cfg.validation.publish_final_apk_after -ne 'CANDIDATE_VALIDATION'){throw "ARMY_PROJECT_PRECHECK=FAIL final_apk_gate=$($cfg.validation.publish_final_apk_after)"}
if([string]$cfg.validation.final_without_physical -ne 'FINAL_VALIDATION=VALIDATION_INCOMPLETE'){throw "ARMY_PROJECT_PRECHECK=FAIL final_truth_without_physical=$($cfg.validation.final_without_physical)"}

$workspaceContract=[ordered]@{
  directory='.work'
  build_directory='.work/build'
  input_cache_directory='.work/cache/inputs'
  scratch_directory='.work/scratch'
  runtime_directory='.work/runtime/AndroidBuild'
  artifacts_directory='.work/artifacts'
}
foreach($entry in $workspaceContract.GetEnumerator()){
  $actual=[string]$cfg.workspace.($entry.Key)
  if($actual -ne [string]$entry.Value){throw "ARMY_PROJECT_PRECHECK=FAIL workspace_$($entry.Key) expected=$($entry.Value) actual=$actual"}
}
if([int]$cfg.workspace.retention_generations -ne 3){throw "ARMY_PROJECT_PRECHECK=FAIL build_retention=$($cfg.workspace.retention_generations)"}
if([bool]$cfg.workspace.project_state_outside_work_allowed){throw 'ARMY_PROJECT_PRECHECK=FAIL external_project_state_allowed'}
if([string]$cfg.cache.input_cache_reuse -ne 'version-and-sha256'){throw "ARMY_PROJECT_PRECHECK=FAIL input_cache_reuse=$($cfg.cache.input_cache_reuse)"}
if([string]$cfg.cache.build_retention -ne 'latest-3-tested-shas'){throw "ARMY_PROJECT_PRECHECK=FAIL cache_build_retention=$($cfg.cache.build_retention)"}
if([string]$cfg.cache.scratch_retention -ne 'ephemeral-current-build'){throw "ARMY_PROJECT_PRECHECK=FAIL scratch_retention=$($cfg.cache.scratch_retention)"}

if([int]$cfg.evidence.keep_runs_global -ne 3){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_keep_runs=$($cfg.evidence.keep_runs_global)"}
if([int]$cfg.evidence.max_files_per_run -ne 200){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_max_files=$($cfg.evidence.max_files_per_run)"}
if([int64]$cfg.evidence.max_total_bytes_per_run -ne 26214400){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_max_total_bytes=$($cfg.evidence.max_total_bytes_per_run)"}
if([int64]$cfg.evidence.max_file_bytes -ne 8388608){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_max_file_bytes=$($cfg.evidence.max_file_bytes)"}
if([int]$cfg.evidence.max_screenshots -ne 8){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_max_screenshots=$($cfg.evidence.max_screenshots)"}

$required=@(
  'Tools\CI\Build-Android.ps1','Tools\CI\Validate-AndroidApk.ps1','Tools\CI\Publish-ApkFinal.ps1','Tools\CI\Audit-PublishedContent.ps1','Tools\CI\Validate-UpstreamAndroidRelease.ps1',
  'Tools\CI\Patch-AndroidPerformanceSwf.ps1','Tools\CI\Build-AndroidDiagnosticsAne.ps1','Tools\CI\Test-AndroidRuntimePatch.ps1','Tools\CI\Test-AndroidDevice.ps1','Tools\CI\Analyze-AndroidRuntimeDiagnostics.ps1','Tools\SWF\Ensure-FFDec.ps1',
  'Tools\CI\Ensure-HarmanAir502.ps1','Tools\CI\Ensure-PortableJdk17.ps1','Tools\CI\Ensure-PinnedAndroidSdkRoot.ps1',
  '.github\scripts\armyattack-workspace.ps1','.github\scripts\publish-armyattack-project-source.ps1',
  '.github\workflows\android-candidate.yml','.github\workflows\android-physical.yml','.github\workflows\evidence-only.yml','.github\workflows\windows-candidate.yml','.github\workflows\swf-extract.yml','.github\workflows\publish-project-source.yml',
  'Logs\physical-adb\RETENTION.md','src','.gitmodules'
)
foreach($relative in $required){if(-not(Test-Path -LiteralPath (Join-Path $repoRoot $relative))){throw "ARMY_PROJECT_PRECHECK=FAIL missing=$relative"}}
$retired=@(
  'Tools\CI\Bootstrap-PhysicalClone.ps1','Tools\CI\Enable-AutoRepoPool4.ps1','Tools\CI\Start-AutoRepoPool4.runtime.ps1','Tools\CI\Publish-AndroidEvidence.ps1',
  '.github\workflows\bootstrap-physical-clone.yml','.github\workflows\enable-autorepo-pool4.yml','.github\workflows\cancel-stale-android.yml','.github\workflows\runner-pool-diagnostic.yml',
  'Logs\physical-adb\validations\RETENTION.md'
)
foreach($relative in $retired){if(Test-Path -LiteralPath (Join-Path $repoRoot $relative)){throw "ARMY_PROJECT_PRECHECK=FAIL retired_infrastructure_present=$relative"}}
$gitmodules=Get-Content -LiteralPath (Join-Path $repoRoot '.gitmodules') -Raw
if($gitmodules -notmatch 'vendor/Test_army_attack'){throw 'ARMY_PROJECT_PRECHECK=FAIL published_submodule_contract_missing'}

$workspaceScript=Get-Content -LiteralPath (Join-Path $repoRoot '.github\scripts\armyattack-workspace.ps1') -Raw
foreach($needle in @("'.work'","'build'","'cache\inputs'","'scratch'","'runtime\AndroidBuild'",'ARMY_BUILD_RETENTION=PASS','ARMY_WORKSPACE_MIGRATION=PASS','ARMY_WORKSPACE_LAYOUT=PASS')){
  if(-not $workspaceScript.Contains($needle)){throw "ARMY_PROJECT_PRECHECK=FAIL workspace_helper_missing=$needle"}
}

$candidateWorkflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\android-candidate.yml') -Raw
foreach($legacy in @('Enable-AutoRepoPool4.ps1','Start-AutoRepoPool4.runtime.ps1','Bootstrap-PhysicalClone.ps1','Publish-AndroidEvidence.ps1')){
  if($candidateWorkflow.Contains($legacy)){throw "ARMY_PROJECT_PRECHECK=FAIL legacy_infrastructure_still_invoked=$legacy"}
}
if(-not $candidateWorkflow.Contains("paths-ignore:") -or -not $candidateWorkflow.Contains("'Logs/**'")){throw 'ARMY_PROJECT_PRECHECK=FAIL candidate_does_not_ignore_evidence_only_commits'}
foreach($needle in @('minimum=3.0.11','APK_FINAL_PUBLICATION=PASS','validation_scope=candidate','PHYSICAL_VALIDATION=NOT_ACTIVATED','FINAL_VALIDATION=VALIDATION_INCOMPLETE')){
  if(-not $candidateWorkflow.Contains($needle)){throw "ARMY_PROJECT_PRECHECK=FAIL candidate_delivery_contract_missing=$needle"}
}

$windowsWorkflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\windows-candidate.yml') -Raw
foreach($needle in @('Resolve-AndroidBuildFlashToolchain','Initialize-ArmyAttackWorkspace','ARMY_RUNTIME_ROOT','WINDOWS_WORKSPACE_ISOLATION=PASS')){
  if(-not $windowsWorkflow.Contains($needle)){throw "ARMY_PROJECT_PRECHECK=FAIL windows_workspace_contract_missing=$needle"}
}
$windowsStateCommands=@('Validate-UpstreamWindowsRelease.ps1','Build-Windows.ps1','Build-WindowsFullCandidate.ps1','Measure-WindowsPerformance.ps1')
foreach($command in $windowsStateCommands){
  $escaped=[regex]::Escape($command)
  if($windowsWorkflow -match ($escaped+'.*?-AndroidBuildRoot\s+\$env:ANDROIDBUILD_ROOT')){throw "ARMY_PROJECT_PRECHECK=FAIL windows_command_uses_global_state_root=$command"}
  if($windowsWorkflow -notmatch ($escaped+'.*?-AndroidBuildRoot\s+\$env:ARMY_RUNTIME_ROOT')){throw "ARMY_PROJECT_PRECHECK=FAIL windows_command_missing_repo_runtime=$command"}
}

$swfWorkflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\swf-extract.yml') -Raw
foreach($needle in @('Sync-AndroidBuildRepositoryExactHead','CORE_REPOSITORY_SYNC=PASS','.work\swf-extracted\23.2','Ensure-AndroidBuildFFDec')){
  if(-not $swfWorkflow.Contains($needle)){throw "ARMY_PROJECT_PRECHECK=FAIL swf_extract_contract_missing=$needle"}
}
foreach($legacy in @('Bootstrap-PhysicalClone.ps1','chore/local-army-bootstrap-20260827')){
  if($swfWorkflow.Contains($legacy)){throw "ARMY_PROJECT_PRECHECK=FAIL swf_extract_legacy_reference=$legacy"}
}

$physicalWorkflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\android-physical.yml') -Raw
if($physicalWorkflow -match '(?m)^\s*push\s*:'){throw 'ARMY_PROJECT_PRECHECK=FAIL physical_workflow_not_manual_only'}
foreach($needle in @(
  'contents: write','same_pr_evidence_requires_feature_branch','.work\evidence-staging','Reduce-AndroidBuildEvidence','Publish-AndroidBuildEvidence','Publish-AndroidBuildEvidenceCommit',
  'TESTED_SHA=','EVIDENCE_COMMIT_SHA=','PHYSICAL_TRUTH=','-PhysicalValidated','delivery.final_apk_name','FINAL_VALIDATION=PASS physical_validation=PASS evidence=PASS apk_final=PASS'
)){
  if(-not $physicalWorkflow.Contains($needle)){throw "ARMY_PROJECT_PRECHECK=FAIL physical_contract_missing=$needle"}
}

$evidenceWorkflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\evidence-only.yml') -Raw
if($evidenceWorkflow.Contains('chore/local-army-bootstrap-20260827')){throw 'ARMY_PROJECT_PRECHECK=FAIL evidence_workflow_hardcoded_legacy_branch'}
foreach($needle in @('Logs/physical-adb','EVIDENCE_RETENTION=FAIL','EVIDENCE_MANIFEST=PASS','androidbuild-evidence/v1','legacy_retained_runs','maximum=200','maximum=26214400','maximum=8388608','maximum=8')){
  if(-not $evidenceWorkflow.Contains($needle)){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_verifier_missing=$needle"}
}

$retentionText=Get-Content -LiteralPath (Join-Path $repoRoot 'Logs\physical-adb\RETENTION.md') -Raw
foreach($needle in @('3 physical runs total','200 files','25 MiB','8 MiB','TESTED_SHA','EVIDENCE_COMMIT_SHA','AndroidBuild Core 3.0.11','APK-FINAL','FINAL_VALIDATION=VALIDATION_INCOMPLETE')){
  if(-not $retentionText.Contains($needle)){throw "ARMY_PROJECT_PRECHECK=FAIL retention_document_missing=$needle"}
}
$physicalRuns=@()
foreach($class in @('validations','failures')){
  $classRoot=Join-Path $repoRoot ("Logs\physical-adb\"+$class)
  if(-not(Test-Path -LiteralPath $classRoot)){continue}
  foreach($shaDir in @(Get-ChildItem -LiteralPath $classRoot -Directory -ErrorAction SilentlyContinue)){
    foreach($runDir in @(Get-ChildItem -LiteralPath $shaDir.FullName -Directory -ErrorAction SilentlyContinue)){$physicalRuns+=$runDir}
  }
}
if($physicalRuns.Count -gt 3){throw "ARMY_PROJECT_PRECHECK=FAIL evidence_retention_existing_runs=$($physicalRuns.Count) maximum=3"}
Write-Host "ARMY_EVIDENCE_RETENTION_PRECHECK=PASS runs=$($physicalRuns.Count) maximum=3"

$publisher=Get-Content -LiteralPath (Join-Path $repoRoot 'Tools\CI\Publish-ApkFinal.ps1') -Raw
foreach($needle in @('[switch]$PhysicalValidated','Publish-AndroidBuildFinalApk','delivery.final_apk_name','metadata=State/apk-final')){
  if(-not $publisher.Contains($needle)){throw "ARMY_PROJECT_PRECHECK=FAIL physical_apk_republisher_contract_missing=$needle"}
}
foreach($forbidden in @('APK-FINAL\archive','Set-Content -LiteralPath ($latestDest+.json)','Remove-PrematureMigrationFinal')){
  if($publisher.Contains($forbidden)){throw "ARMY_PROJECT_PRECHECK=FAIL apk_final_non_apk_payload_or_legacy_cleanup=$forbidden"}
}

Write-Host "ARMY_PROJECT_PRECHECK=PASS repository=Valverde-101/code-army-client core_min=3.0.11 tested_core=$core adapter=repo-hooks flash_toolchain=androidbuild-global migration=COMPLETE project_state=repo-work build_retention=3 input_cache=sha256 scratch=ephemeral windows=repo-work swf_extract=core-synced physical_activation=manual physical_required=true evidence_publisher=androidbuild-core evidence_contract=canonical apk_final_delivery=candidate_validated apk_final_payload=apk_only final_without_physical=VALIDATION_INCOMPLETE legacy_evidence_publisher=ABSENT"
