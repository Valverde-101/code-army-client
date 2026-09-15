param(
  [Parameter(Mandatory=$true)][string]$EvidenceRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$ExpectedApkSha256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$internal=Join-Path $PSScriptRoot 'Analyze-AndroidRuntimeDiagnostics.Internal.ps1'
$targeted=Join-Path $PSScriptRoot 'Test-AndroidTargetedRegressions.ps1'
$graph=Join-Path $PSScriptRoot 'Build-SwfResourceGraph.ps1'
$correlate=Join-Path $PSScriptRoot 'Correlate-AndroidRuntimeDiagnostics.ps1'
foreach($required in @($internal,$targeted,$graph,$correlate)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "RUNTIME_DIAGNOSTICS=FAIL helper_missing=$required"}}
if([string]::IsNullOrWhiteSpace($env:ANDROIDBUILD_ROOT)){throw 'RUNTIME_DIAGNOSTICS=FAIL androidbuild_root_missing'}

# Run the regressions that motivated the current source fixes through the
# DEBUG/TEST ADB command console. Doing this before analysis keeps the exact
# Snow/Home/Snow traces and screenshots in the same physical evidence set.
& $targeted -EvidenceRoot $EvidenceRoot -ExpectedSha $ExpectedSha -ExpectedApkSha256 $ExpectedApkSha256 -AndroidBuildRoot $env:ANDROIDBUILD_ROOT

& $internal -EvidenceRoot $EvidenceRoot -ExpectedSha $ExpectedSha -ExpectedApkSha256 $ExpectedApkSha256

$repoRoot=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$staticRoot=Join-Path $EvidenceRoot 'static-analysis'
& $graph -RepoRoot $repoRoot -ExpectedSha $ExpectedSha -OutputRoot $staticRoot
$graphPath=Join-Path $staticRoot 'SWF-RESOURCE-GRAPH.json'
& $correlate -EvidenceRoot $EvidenceRoot -ExpectedSha $ExpectedSha -ExpectedApkSha256 $ExpectedApkSha256 -GraphPath $graphPath
Write-Host "RUNTIME_DIAGNOSTICS_WRAPPER=PASS targeted_regression=true snow_home_snow=true territory_restore=true correlated=true resource_graph=true graph=$graphPath"
