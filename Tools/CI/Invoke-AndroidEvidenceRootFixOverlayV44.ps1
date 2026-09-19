param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V44=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v43=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV43.ps1'
if(-not(Test-Path -LiteralPath $v43 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V44=FAIL predecessor_missing=$v43"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}

# Android applies VisualCombat before the evidence-rootfix chain. VisualCombat
# correctly strengthens FireMissionObject's timeout condition to:
#   if(!this.mFallbackFinished && fallbackElapsed >= FALLBACK_TOTAL_TIMEOUT_MS)
# V43 searched the complete baseline line and therefore failed before it could
# preserve that guard and substitute the mission-specific timeout. Patch only
# V43's matcher, never the gameplay source, then restore V43 byte-for-byte.
$original=[IO.File]::ReadAllBytes($v43)
$originalHash=Get-Sha256 $v43
try {
  $text=[IO.File]::ReadAllText($v43)
  $oldLine=@'
  $fire=Replace-One $fire '            if(fallbackElapsed >= FALLBACK_TOTAL_TIMEOUT_MS)' '            if(fallbackElapsed >= this.mFallbackTotalTimeoutMs)' 'firemission_profile_timeout'
'@.TrimEnd()
  $newLine=@'
  $fire=Replace-One $fire 'fallbackElapsed >= FALLBACK_TOTAL_TIMEOUT_MS' 'fallbackElapsed >= this.mFallbackTotalTimeoutMs' 'firemission_profile_timeout'
'@.TrimEnd()
  $count=([regex]::Matches($text,[regex]::Escape($oldLine))).Count
  if($count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V44=FAIL v43_timeout_matcher expected=1 actual=$count"}
  $text=$text.Replace($oldLine,$newLine)
  [IO.File]::WriteAllText($v43,$text,(New-Object System.Text.UTF8Encoding($true)))

  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($v43,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V44_V43_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V44=FAIL patched_v43_parser_invalid'
  }
  $patched=[IO.File]::ReadAllText($v43)
  if(-not $patched.Contains("'fallbackElapsed >= FALLBACK_TOTAL_TIMEOUT_MS' 'fallbackElapsed >= this.mFallbackTotalTimeoutMs'")){throw 'ANDROID_EVIDENCE_ROOTFIX_V44=FAIL patched_matcher_verification'}
  Write-Host 'EVIDENCE_ROOTFIX_V44_COMPOSITION=PASS target=FireMissionObject timeout_match=subexpression visual_combat_guard=preserved parser=true'

  & $v43 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode

  Write-Host 'REGRESSION_CHECK=PASS name=firemission_timeout_overlay_composition baseline=true visual_combat_guard=true mission_specific_timeout=true gameplay_semantics_unchanged=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V44=PASS mode=$Mode predecessor=v43 sha=$ExpectedSha composition=firemission_timeout"
}
finally {
  [IO.File]::WriteAllBytes($v43,$original)
  $restoredHash=Get-Sha256 $v43
  if($restoredHash -ne $originalHash){throw "ANDROID_EVIDENCE_ROOTFIX_V44=FAIL predecessor_restore_hash expected=$originalHash actual=$restoredHash"}
  Write-Host 'EVIDENCE_ROOTFIX_V44_PREDECESSOR_RESTORE=PASS file=Invoke-AndroidEvidenceRootFixOverlayV43.ps1 byte_exact=true'
}
