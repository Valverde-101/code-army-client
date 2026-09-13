param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL exact_head expected=$ExpectedSha actual=$actual"}

# V15 owns the runtime changes. V16 replaces only V15's brittle ownership
# method locator. The V3 predecessor always ends this method with
# `return committed;`, so use that semantic terminal instead of indentation or
# assumptions about which helper method follows it.
$v15=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV15.ps1'
if(-not(Test-Path -LiteralPath $v15 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL predecessor_missing=$v15"}

$runtimeScript=Join-Path $PSScriptRoot '.Invoke-AndroidEvidenceRootFixOverlayV15.v16.runtime.ps1'
$old=@'
  $commitPattern='(?ms)      public function commitOwnershipVisualNow\(\)\s*:\s*Boolean\s*\{.*?\n      \}\s*(?=\n      public function updateCameraViewport)'
'@
$new=@'
  $commitPattern='(?ms)[ \t]*public function commitOwnershipVisualNow\(\)\s*:\s*Boolean\s*\{.*?return committed;\s*\}'
'@

try {
  $text=[IO.File]::ReadAllText($v15).Replace("`r`n","`n").Replace("`r","`n")
  $needle=$old.TrimEnd()
  $replacement=$new.TrimEnd()
  $first=$text.IndexOf($needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V16=FAIL anchor=legacy_v15_commit_pattern reason=missing'}
  $second=$text.IndexOf($needle,$first+$needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V16=FAIL anchor=legacy_v15_commit_pattern reason=ambiguous'}
  $patched=$text.Substring(0,$first)+$replacement+$text.Substring($first+$needle.Length)
  if($patched.IndexOf($replacement,[StringComparison]::Ordinal) -lt 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V16=FAIL semantic_anchor_not_installed'}
  [IO.File]::WriteAllText($runtimeScript,$patched,(New-Object System.Text.UTF8Encoding($true)))
  Write-Host 'EVIDENCE_ROOTFIX_V16_COMPAT=PASS anchor=commitOwnershipVisualNow semantic_terminal=return_committed following_helpers_allowed=true indentation_agnostic=true'
  & $runtimeScript -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL predecessor_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V16=PASS mode=$Mode sha=$ExpectedSha predecessor=v15 semantic_anchor=return_committed"
}
finally {
  if(Test-Path -LiteralPath $runtimeScript -PathType Leaf){Remove-Item -LiteralPath $runtimeScript -Force -ErrorAction SilentlyContinue}
}
