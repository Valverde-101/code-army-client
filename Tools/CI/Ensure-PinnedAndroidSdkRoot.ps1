param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [string]$TargetApi='33',
  [string]$BuildTools='33.0.2'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$sourceSdk=Join-Path $AndroidBuildRoot 'AndroidSDK'
if(-not (Test-Path -LiteralPath $sourceSdk)){throw "PINNED_ANDROID_SDK=FAIL source_sdk_missing=$sourceSdk"}
$platform=Join-Path $sourceSdk "platforms\android-$TargetApi"
$buildToolsPath=Join-Path $sourceSdk "build-tools\$BuildTools"
$platformTools=Join-Path $sourceSdk 'platform-tools'
foreach($required in @($platform,$buildToolsPath,$platformTools)){
  if(-not (Test-Path -LiteralPath $required)){throw "PINNED_ANDROID_SDK=FAIL missing=$required"}
}

$shadowRoot=Join-Path $AndroidBuildRoot "Toolchains\AIR50-API$TargetApi-BT$BuildTools"
$pinnedSdk=Join-Path $shadowRoot 'AndroidSDK'
New-Item -ItemType Directory -Force -Path $shadowRoot,$pinnedSdk,(Join-Path $pinnedSdk 'platforms'),(Join-Path $pinnedSdk 'build-tools')|Out-Null

function Ensure-Junction([string]$Link,[string]$Target){
  if(Test-Path -LiteralPath $Link){
    $item=Get-Item -LiteralPath $Link -Force
    $resolved=$null
    try{$resolved=(Get-Item -LiteralPath $Link -Force).Target}catch{}
    if($resolved -and (([string]$resolved).TrimEnd('\') -ieq $Target.TrimEnd('\'))){return}
    Remove-Item -LiteralPath $Link -Force -Recurse
  }
  New-Item -ItemType Junction -Path $Link -Target $Target|Out-Null
}

Ensure-Junction (Join-Path $pinnedSdk "platforms\android-$TargetApi") $platform
Ensure-Junction (Join-Path $pinnedSdk "build-tools\$BuildTools") $buildToolsPath
Ensure-Junction (Join-Path $pinnedSdk 'platform-tools') $platformTools
foreach($name in @('Tools','Inputs','Builds')){
  $target=Join-Path $AndroidBuildRoot $name
  if(-not (Test-Path -LiteralPath $target)){New-Item -ItemType Directory -Force -Path $target|Out-Null}
  Ensure-Junction (Join-Path $shadowRoot $name) $target
}

$visiblePlatforms=@(Get-ChildItem -LiteralPath (Join-Path $pinnedSdk 'platforms') -Directory -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Name)
$visibleBuildTools=@(Get-ChildItem -LiteralPath (Join-Path $pinnedSdk 'build-tools') -Directory -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Name)
if($visiblePlatforms.Count -ne 1 -or $visiblePlatforms[0] -ne "android-$TargetApi"){throw "PINNED_ANDROID_SDK=FAIL platforms=$($visiblePlatforms -join ',')"}
if($visibleBuildTools.Count -ne 1 -or $visibleBuildTools[0] -ne $BuildTools){throw "PINNED_ANDROID_SDK=FAIL build_tools=$($visibleBuildTools -join ',')"}

Write-Host "PINNED_ANDROID_SDK=PASS root=$pinnedSdk api=$TargetApi build_tools=$BuildTools"
Write-Host "PINNED_ANDROID_BUILD_ROOT=$shadowRoot"
if($env:GITHUB_ENV){
  "PINNED_ANDROID_BUILD_ROOT=$shadowRoot"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "PINNED_ANDROID_SDK=$pinnedSdk"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
}
