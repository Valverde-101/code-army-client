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
foreach($command in @('Resolve-AndroidBuildFlashToolchain','Ensure-AndroidBuildFFDec','Ensure-AndroidBuildHarmanAirSdk','Ensure-AndroidBuildPortableJdk17','Ensure-AndroidBuildPinnedAndroidSdkView','Invoke-AndroidBuildProcess')){
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
if([string]$cfg.core.minimum_version -ne '3.0.9'){throw "ARMY_PROJECT_PRECHECK=FAIL core_contract=$($cfg.core.minimum_version)"}
$required=@(
  'Tools\CI\Build-Android.ps1','Tools\CI\Validate-AndroidApk.ps1','Tools\CI\Audit-PublishedContent.ps1','Tools\CI\Validate-UpstreamAndroidRelease.ps1',
  'Tools\CI\Patch-AndroidPerformanceSwf.ps1','Tools\CI\Build-AndroidDiagnosticsAne.ps1','Tools\CI\Test-AndroidRuntimePatch.ps1','Tools\SWF\Ensure-FFDec.ps1',
  'src','.gitmodules'
)
foreach($relative in $required){if(-not(Test-Path -LiteralPath (Join-Path $repoRoot $relative))){throw "ARMY_PROJECT_PRECHECK=FAIL missing=$relative"}}
$gitmodules=Get-Content -LiteralPath (Join-Path $repoRoot '.gitmodules') -Raw
if($gitmodules -notmatch 'vendor/Test_army_attack'){throw 'ARMY_PROJECT_PRECHECK=FAIL published_submodule_contract_missing'}
$workflow=Join-Path $repoRoot '.github\workflows\android-candidate.yml'
if(Test-Path -LiteralPath $workflow){
  $workflowText=Get-Content -LiteralPath $workflow -Raw
  foreach($legacy in @('Enable-AutoRepoPool4.ps1','Start-AutoRepoPool4.runtime.ps1','Bootstrap-PhysicalClone.ps1')){
    if($workflowText.Contains($legacy)){throw "ARMY_PROJECT_PRECHECK=FAIL legacy_infrastructure_still_invoked=$legacy"}
  }
}
Write-Host "ARMY_PROJECT_PRECHECK=PASS repository=Valverde-101/code-army-client core_min=3.0.9 tested_core=$core adapter=repo-hooks flash_toolchain=androidbuild-global physical_required=true"
