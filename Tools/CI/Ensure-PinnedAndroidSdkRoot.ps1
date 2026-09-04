# ANDROIDBUILD_CORE_SHIM: pinned Android SDK ownership moved to AndroidBuild Core 3.0.9+
param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [string]$TargetApi='33',
  [string]$BuildTools='33.0.2'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $AndroidBuildRoot 'Core\Current\AndroidBuild.psd1') -DisableNameChecking -Force
if([version](Get-AndroidBuildCoreVersion) -lt [version]'3.0.9'){throw 'PINNED_ANDROID_SDK_CORE_SHIM=FAIL core_minimum=3.0.9'}
$id="AIR50-API$TargetApi-BT$BuildTools"
$r=Ensure-AndroidBuildPinnedAndroidSdkView -AndroidBuildRoot $AndroidBuildRoot -TargetApi $TargetApi -BuildTools $BuildTools -ToolchainId $id
if([string]$r.status -ne 'PASS'){throw 'PINNED_ANDROID_SDK_CORE_SHIM=FAIL resolver'}
if($env:GITHUB_ENV){"PINNED_ANDROID_BUILD_ROOT=$($r.root)"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append;"PINNED_ANDROID_SDK=$($r.sdk)"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append}
Write-Host "PINNED_ANDROID_SDK=PASS provider=androidbuild-core root=$($r.sdk) api=$TargetApi build_tools=$BuildTools"
