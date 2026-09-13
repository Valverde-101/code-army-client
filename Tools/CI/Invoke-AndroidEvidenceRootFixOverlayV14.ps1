param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$impl=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV16.ps1'
$v4=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV4.ps1'
if(-not(Test-Path -LiteralPath $impl -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V14_COMPAT=FAIL delegate_missing=$impl"}
if(-not(Test-Path -LiteralPath $v4 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V14_COMPAT=FAIL v4_missing=$v4"}

# V3 inserts commitOwnershipVisualNow between clearDirtyBitmapRegion and
# updateCameraViewport. The old V4 range used updateCameraViewport as its end
# anchor, so it could span across and consume the V3 ownership method. Repair
# that composition boundary before delegating, then restore the script bytes.
$original=[IO.File]::ReadAllBytes($v4)
try {
  $text=[Text.Encoding]::UTF8.GetString($original)
  $old='(?=\n\s*public function updateCameraViewport)'
  $new='(?=\n\s*public function commitOwnershipVisualNow)'
  $count=([regex]::Matches($text,[regex]::Escape($old))).Count
  if($count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V14_COMPAT=FAIL v4_boundary expected=1 actual=$count"}
  $text=$text.Replace($old,$new)
  [IO.File]::WriteAllText($v4,$text,(New-Object System.Text.UTF8Encoding($true)))
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V14_COMPOSITION=PASS root_cause=v4_cross_method_span boundary=commitOwnershipVisualNow'

  & $impl -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V14_COMPAT=FAIL delegate_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V14_COMPAT=PASS delegated=v16 mode=$Mode sha=$ExpectedSha v4_boundary_fixed=true"
}
finally {
  [IO.File]::WriteAllBytes($v4,$original)
}
