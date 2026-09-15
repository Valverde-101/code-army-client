param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$ExpectedSha,
  [string]$OutputRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$internal=Join-Path $PSScriptRoot 'Audit-SwfCore.Internal.ps1'
$graph=Join-Path $PSScriptRoot 'Build-SwfResourceGraph.ps1'
$boot=Join-Path $PSScriptRoot 'Test-AndroidBootContract.ps1'
if(-not(Test-Path -LiteralPath $internal -PathType Leaf)){throw "SWF_CORE_AUDIT=FAIL internal_missing=$internal"}
if(-not(Test-Path -LiteralPath $graph -PathType Leaf)){throw "SWF_CORE_AUDIT=FAIL graph_missing=$graph"}
if(-not(Test-Path -LiteralPath $boot -PathType Leaf)){throw "SWF_CORE_AUDIT=FAIL boot_contract_missing=$boot"}
& $internal -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -OutputRoot $OutputRoot
& $boot -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha
$resolved=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not $OutputRoot){
  $head=$ExpectedSha
  if(-not $head){
    $git=$null
    foreach($name in @('git.exe','git')){$cmd=Get-Command $name -ErrorAction SilentlyContinue;if($cmd){$git=$cmd.Source;break}}
    if(-not $git){throw 'SWF_CORE_AUDIT=FAIL wrapper_git_not_found'}
    $head=(& $git -C $resolved rev-parse HEAD).Trim()
  }
  $OutputRoot=Join-Path $resolved ".work\reports\core-audit\$head"
}
& $graph -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -OutputRoot $OutputRoot
Write-Host 'SWF_CORE_AUDIT_WRAPPER=PASS resource_graph=true trace_contract=true boot_contract=true'
