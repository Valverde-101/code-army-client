# ANDROIDBUILD_CORE_SHIM: reusable HARMAN AIR ownership moved to AndroidBuild Core 3.0.9+
param([Parameter(Mandatory=$true)][string]$AndroidBuildRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $AndroidBuildRoot 'Core\Current\AndroidBuild.psd1') -DisableNameChecking -Force
if([version](Get-AndroidBuildCoreVersion) -lt [version]'3.0.9'){throw 'HARMAN_AIR_CORE_SHIM=FAIL core_minimum=3.0.9'}
$r=Ensure-AndroidBuildHarmanAirSdk -AndroidBuildRoot $AndroidBuildRoot -Version '50.2.3.6'
if([string]$r.status -ne 'PASS'){throw 'HARMAN_AIR_CORE_SHIM=FAIL resolver'}
$env:AIR_HOME=[string]$r.home
$env:JAVA_HOME=[string]$r.java_home
$env:PATH=(Join-Path $env:JAVA_HOME 'bin')+';'+$env:PATH
if($env:GITHUB_ENV){"AIR_HOME=$env:AIR_HOME"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append;"JAVA_HOME=$env:JAVA_HOME"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append}
Write-Host "HARMAN_AIR_502=PASS provider=androidbuild-core version=$($r.version) root=$($r.home)"
