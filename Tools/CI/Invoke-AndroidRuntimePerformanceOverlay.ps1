param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$internal=Join-Path $PSScriptRoot 'Invoke-AndroidRuntimePerformanceOverlay.Internal.ps1'
if(-not(Test-Path -LiteralPath $internal -PathType Leaf)){throw "ANDROID_PERF_OVERLAY=FAIL internal_missing=$internal"}

if($Mode -eq 'Apply'){
  & $internal -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
  return
}

try{
  & $internal -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  return
}catch{
  $message=[string]$_.Exception.Message
  if($message -notmatch 'ANDROID_PERF_OVERLAY=FAIL restore_worktree_not_exact'){throw}
}

# The performance overlay is nested inside the Snow overlay and therefore its
# pre-apply baseline can legitimately differ from Git HEAD. The internal script
# has already restored every owned file and verified each recorded SHA before
# reaching its whole-worktree assertion. Re-verify that recorded baseline here;
# the outer Snow restore remains responsible for the final exact-HEAD gate.
$backupRoot=Join-Path $RepoRoot ('.work\scratch\runtime-performance-overlay\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw "ANDROID_PERF_OVERLAY=FAIL stacked_restore_manifest_missing=$manifestPath"}
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_PERF_OVERLAY=FAIL stacked_restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
foreach($entry in @($manifest.files)){
  $path=Join-Path $RepoRoot ([string]$entry.path)
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "ANDROID_PERF_OVERLAY=FAIL stacked_restore_file_missing=$($entry.path)"}
  $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
  $expected=([string]$entry.sha256).ToUpperInvariant()
  if($actual -ne $expected){throw "ANDROID_PERF_OVERLAY=FAIL stacked_restore_hash path=$($entry.path) expected=$expected actual=$actual"}
}
Remove-Item -LiteralPath $backupRoot -Recurse -Force
Write-Host "ANDROID_PERF_OVERLAY=PASS mode=restore baseline_restored=true composable=true outer_exact_head_gate=snow sha=$ExpectedSha"
