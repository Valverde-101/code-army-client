# ANDROIDBUILD_CORE_SHIM: reusable JDK ownership moved to AndroidBuild Core 3.0.9+
param([Parameter(Mandatory=$true)][string]$AndroidBuildRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $AndroidBuildRoot 'Core\Current\AndroidBuild.psd1') -DisableNameChecking -Force
if([version](Get-AndroidBuildCoreVersion) -lt [version]'3.0.9'){throw 'JDK17_CORE_SHIM=FAIL core_minimum=3.0.9'}
$r=Ensure-AndroidBuildPortableJdk17 -AndroidBuildRoot $AndroidBuildRoot
if([string]$r.status -ne 'PASS'){throw 'JDK17_CORE_SHIM=FAIL resolver'}
$env:JAVA_HOME=[string]$r.home
$env:PATH=(Join-Path $env:JAVA_HOME 'bin')+';'+$env:PATH
if($env:GITHUB_ENV){"JAVA_HOME=$env:JAVA_HOME"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append}
if($env:GITHUB_PATH){(Join-Path $env:JAVA_HOME 'bin')|Out-File $env:GITHUB_PATH -Encoding utf8 -Append}
Write-Host "PORTABLE_JDK17=PASS provider=androidbuild-core version=17 home=$env:JAVA_HOME"
