param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$impl=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV15.ps1'
if(-not(Test-Path -LiteralPath $impl -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V14_COMPAT=FAIL delegate_missing=$impl"}
& $impl -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
Write-Host "ANDROID_EVIDENCE_ROOTFIX_V14_COMPAT=PASS delegated=v15 mode=$Mode sha=$ExpectedSha"
