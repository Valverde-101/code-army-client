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

# V15 owns the actual runtime changes. V16 fixes one brittle V15 semantic anchor
# without duplicating the large overlay. RenderHotpath is allowed to insert
# helper methods after commitOwnershipVisualNow(), so the target is bounded by
# the AS3 method's own six-space closing brace rather than by the next method.
$v15=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV15.ps1'
if(-not(Test-Path -LiteralPath $v15 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL predecessor_missing=$v15"}

$runtimeScript=Join-Path $PSScriptRoot '.Invoke-AndroidEvidenceRootFixOverlayV15.v16.runtime.ps1'
$old=@'
  $commitPattern='(?ms)      public function commitOwnershipVisualNow\(\)\s*:\s*Boolean\s*\{.*?\n      \}\s*(?=\n      public function updateCameraViewport)'
'@
$new=@'
  $commitPattern='(?ms)^      public function commitOwnershipVisualNow\(\)\s*:\s*Boolean\s*\{.*?^      \}[ \t]*$'
'@

try {
  $text=[IO.File]::ReadAllText($v15).Replace("`r`n","`n").Replace("`r","`n")
  $needle=$old.TrimEnd()
  $first=$text.IndexOf($needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V16=FAIL anchor=legacy_v15_commit_pattern reason=missing'}
  $second=$text.IndexOf($needle,$first+$needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V16=FAIL anchor=legacy_v15_commit_pattern reason=ambiguous'}
  $patched=$text.Substring(0,$first)+$new.TrimEnd()+$text.Substring($first+$needle.Length)
  if(-not $patched.Contains($new.TrimEnd())){throw 'ANDROID_EVIDENCE_ROOTFIX_V16=FAIL semantic_anchor_not_installed'}
  [IO.File]::WriteAllText($runtimeScript,$patched,(New-Object System.Text.UTF8Encoding($true)))
  Write-Host 'EVIDENCE_ROOTFIX_V16_COMPAT=PASS anchor=commitOwnershipVisualNow method_indent_close=true following_helpers_allowed=true duplicate_overlay_logic=false'
  & $runtimeScript -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL predecessor_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V16=PASS mode=$Mode sha=$ExpectedSha predecessor=v15 semantic_anchor=method_indent_close"
}
finally {
  if(Test-Path -LiteralPath $runtimeScript -PathType Leaf){Remove-Item -LiteralPath $runtimeScript -Force -ErrorAction SilentlyContinue}
}
