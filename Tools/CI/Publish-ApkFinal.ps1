param(
  [Parameter(Mandatory=$true)][string]$SourceApk,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$RelativePath,
  [Parameter(Mandatory=$true)][string]$Kind,
  [switch]$PhysicalValidated
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$configPath=Join-Path $repoRoot '.androidbuild.json'
if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){throw "APK_FINAL_COPY=FAIL config_missing=$configPath"}
$config=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
$ownedName=[string]$config.delivery.final_apk_name
if([string]::IsNullOrWhiteSpace($ownedName)){throw 'APK_FINAL_COPY=FAIL owned_name_missing'}
if([IO.Path]::GetFileName($RelativePath) -ne $RelativePath){throw "APK_FINAL_COPY=FAIL invalid_relative_path=$RelativePath"}
if($RelativePath -ne $ownedName){throw "APK_FINAL_COPY=FAIL ownership expected=$ownedName actual=$RelativePath"}

if(-not $PhysicalValidated){
  Write-Host "APK_FINAL_PHYSICAL_REPUBLICATION=SKIPPED physical_validation=NOT_ACTIVATED tested_sha=$ExpectedSha kind=$Kind owned_name=$ownedName candidate_delivery=core"
  return
}

if(-not(Test-Path -LiteralPath $SourceApk -PathType Leaf)){throw "APK_FINAL_COPY=FAIL source_missing=$SourceApk"}
$sourceSha=(Get-FileHash -LiteralPath $SourceApk -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest=Join-Path $AndroidBuildRoot 'Core\Current\AndroidBuild.psd1'
if(-not(Test-Path -LiteralPath $manifest -PathType Leaf)){throw "APK_FINAL_COPY=FAIL core_manifest_missing=$manifest"}
Import-Module $manifest -DisableNameChecking -Force
$core=[version](Get-AndroidBuildCoreVersion)
if($core -lt [version]'3.0.11'){throw "APK_FINAL_COPY=FAIL core=$core minimum=3.0.11"}
if(-not(Get-Command Publish-AndroidBuildFinalApk -ErrorAction SilentlyContinue)){throw 'APK_FINAL_COPY=FAIL core_publisher_missing'}

$published=Publish-AndroidBuildFinalApk -AndroidBuildRoot $AndroidBuildRoot -Repository 'Valverde-101/code-army-client' -ApkPath $SourceApk -FinalFileName $ownedName -TestedSha $ExpectedSha
if([string]$published.status -ne 'PASS'){throw "APK_FINAL_COPY=FAIL core_status=$($published.status)"}
$expectedDest=Join-Path $AndroidBuildRoot ("APK-FINAL\"+$ownedName)
$actualDest=[IO.Path]::GetFullPath([string]$published.path)
if($actualDest -ne [IO.Path]::GetFullPath($expectedDest)){throw "APK_FINAL_COPY=FAIL destination expected=$expectedDest actual=$actualDest"}
if(-not(Test-Path -LiteralPath $actualDest -PathType Leaf)){throw "APK_FINAL_COPY=FAIL destination_missing=$actualDest"}
$publishedSha=(Get-FileHash -LiteralPath $actualDest -Algorithm SHA256).Hash.ToLowerInvariant()
if($publishedSha -ne $sourceSha -or ([string]$published.sha256).ToLowerInvariant() -ne $sourceSha){throw "APK_FINAL_COPY=FAIL hash source=$sourceSha result=$($published.sha256) disk=$publishedSha"}

# The Core stores publication metadata under State\apk-final. Remove only the old
# sidecar for this repository-owned filename if a previous legacy flow left one.
$legacySidecar=$actualDest+'.json'
if(Test-Path -LiteralPath $legacySidecar -PathType Leaf){
  Remove-Item -LiteralPath $legacySidecar -Force
  Write-Host "APK_FINAL_LEGACY_SIDECAR_CLEANUP=PASS path=$legacySidecar"
}

Write-Host "APK_FINAL_LATEST=PASS path=$actualDest sha256=$publishedSha physical_validation=PASS validation_scope=physical_reconfirmation"
Write-Host "APK_FINAL_COPY=PASS kind=$Kind physical_validation=PASS owned_name=$ownedName publisher=androidbuild-core metadata=State/apk-final"
