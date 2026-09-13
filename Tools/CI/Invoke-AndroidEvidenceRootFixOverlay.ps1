param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$impl=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV11.ps1'
if(-not(Test-Path -LiteralPath $impl -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL implementation_missing=$impl"}
$tokens=$null
$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($impl,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0){
  $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V11_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
  throw 'ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL v11_parser_invalid'
}
Write-Host 'ANDROID_EVIDENCE_ROOTFIX_DRIVER=PASS implementation=v11 static=true self_modifying=false parser=true'
& $impl -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
