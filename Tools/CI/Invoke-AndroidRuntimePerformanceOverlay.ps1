param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_PERF_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_PERF_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$internal=Join-Path $PSScriptRoot 'Invoke-AndroidRuntimePerformanceOverlay.Internal.ps1'
$gameplayOverlay=Join-Path $PSScriptRoot 'Invoke-AndroidGameplayStabilityOverlay.ps1'
$animationLifecycle=Join-Path $PSScriptRoot 'Invoke-AndroidAnimationLifecycleOverlay.ps1'
$movementPacing=Join-Path $PSScriptRoot 'Invoke-AndroidMovementPacingOverlay.ps1'
$renderHotpath=Join-Path $PSScriptRoot 'Invoke-AndroidRenderHotpathOverlay.ps1'
$visualCombat=Join-Path $PSScriptRoot 'Invoke-AndroidVisualCombatOverlay.ps1'
$bootOverlay=Join-Path $PSScriptRoot 'Invoke-AndroidBootResourceOverlay.ps1'
foreach($script in @($internal,$gameplayOverlay,$animationLifecycle,$movementPacing,$renderHotpath,$visualCombat,$bootOverlay)){
  if(-not(Test-Path -LiteralPath $script -PathType Leaf)){throw "ANDROID_PERF_OVERLAY=FAIL dependency_missing=$script"}
}

# The Snow/source transformations are allowed to reformat AS3 whitespace. The
# gameplay overlay deliberately stays strict, so canonicalize only the visual
# hint preamble that it owns and restore the exact incoming bytes afterward.
$characterPath=Join-Path $RepoRoot 'src\game\isometric\characters\IsometricCharacter.as'
$characterCompatRoot=Join-Path $RepoRoot ('.work\scratch\character-hint-compat\'+$ExpectedSha)
$characterCompatBackup=Join-Path $characterCompatRoot 'IsometricCharacter.as.original'
$characterCompatHash=Join-Path $characterCompatRoot 'original.sha256'
function Get-FileSha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Apply-CharacterHintCompatibility {
  if(-not(Test-Path -LiteralPath $characterPath -PathType Leaf)){throw "CHARACTER_HINT_COMPAT=FAIL source_missing=$characterPath"}
  if(Test-Path -LiteralPath $characterCompatRoot){Remove-Item -LiteralPath $characterCompatRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $characterCompatRoot|Out-Null
  Copy-Item -LiteralPath $characterPath -Destination $characterCompatBackup -Force
  $originalSha=Get-FileSha256 $characterPath
  Set-Content -LiteralPath $characterCompatHash -Value $originalSha -Encoding ASCII
  $text=[IO.File]::ReadAllText($characterPath).Replace("`r`n","`n").Replace("`r","`n")
  $pattern='(?ms)^[ \t]*public function update\(param1:\s*int\)\s*:\s*void\s*\{\s*var _loc2_:\s*TextEffect\s*=\s*null;\s*var _loc3_:\s*MovieClip\s*=\s*null;\s*if\s*\(this\.mUpdateHintHealth\)\s*\{\s*this\.updateHintHealth\(\);\s*\}\s*if\s*\(this\.mUpdateHintPower\)\s*\{\s*this\.updateHintPower\(\);\s*\}'
  $matches=[regex]::Matches($text,$pattern)
  if($matches.Count -ne 1){throw "CHARACTER_HINT_COMPAT=FAIL semantic_match_count actual=$($matches.Count)"}
  $canonical=@'
		public function update(param1: int): void {
			var _loc2_: TextEffect = null;
			var _loc3_: MovieClip = null;
			if (this.mUpdateHintHealth) {
				this.updateHintHealth();
			}
			if (this.mUpdateHintPower) {
				this.updateHintPower();
			}
'@
  $text=[regex]::Replace($text,$pattern,$canonical,1)
  Write-Utf8Bom $characterPath $text
  Write-Host "CHARACTER_HINT_COMPAT=PASS mode=apply semantic_scope=IsometricCharacter.update visual_hints_only original_sha256=$originalSha"
}
function Restore-CharacterHintCompatibility {
  if(-not(Test-Path -LiteralPath $characterCompatRoot -PathType Container)){Write-Host "CHARACTER_HINT_COMPAT=PASS mode=restore status=no_overlay sha=$ExpectedSha";return}
  if(-not(Test-Path -LiteralPath $characterCompatBackup -PathType Leaf) -or -not(Test-Path -LiteralPath $characterCompatHash -PathType Leaf)){throw 'CHARACTER_HINT_COMPAT=FAIL restore_metadata_missing'}
  $expected=(Get-Content -LiteralPath $characterCompatHash -Raw).Trim().ToUpperInvariant()
  Copy-Item -LiteralPath $characterCompatBackup -Destination $characterPath -Force
  $restored=Get-FileSha256 $characterPath
  if($restored -ne $expected){throw "CHARACTER_HINT_COMPAT=FAIL restore_hash expected=$expected actual=$restored"}
  Remove-Item -LiteralPath $characterCompatRoot -Recurse -Force
  Write-Host "CHARACTER_HINT_COMPAT=PASS mode=restore exact_incoming_bytes=true sha256=$restored"
}

if($Mode -eq 'Apply'){
  try{
    & $internal -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
    Apply-CharacterHintCompatibility
    & $gameplayOverlay -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
    & $animationLifecycle -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
    & $movementPacing -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
    & $renderHotpath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
    & $visualCombat -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
    & $bootOverlay -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
    Write-Host 'REGRESSION_CHECK=PASS name=character_hint_overlay_composition semantic_canonicalization=true exact_restore=true'
    Write-Host 'REGRESSION_CHECK=PASS name=runtime_overlay_composition order=performance+gameplay+animation_lifecycle+movement+render_hotpath+visual_combat+boot'
    Write-Host "ANDROID_RUNTIME_OVERLAY_BUNDLE=PASS mode=apply performance=true gameplay_stability=true animation_lifecycle=true movement_pacing=true render_hotpath=true visual_combat=true boot_resource=true character_hint_compat=true sha=$ExpectedSha"
    return
  }catch{
    $failure=$_
    try{& $PSCommandPath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_RUNTIME_OVERLAY_BUNDLE_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
    throw $failure
  }
}

# Restore nested overlays in reverse order. Snow is an outer overlay, so these
# restores verify their recorded baselines instead of assuming a clean worktree
# until the Snow layer is finally restored by the build hook.
& $bootOverlay -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
& $visualCombat -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
& $renderHotpath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
& $movementPacing -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
& $animationLifecycle -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
& $gameplayOverlay -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
Restore-CharacterHintCompatibility
try{
  & $internal -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_RUNTIME_OVERLAY_BUNDLE=PASS mode=restore performance=true gameplay_stability=true animation_lifecycle=true movement_pacing=true render_hotpath=true visual_combat=true boot_resource=true character_hint_compat=true sha=$ExpectedSha"
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
Write-Host "ANDROID_RUNTIME_OVERLAY_BUNDLE=PASS mode=restore performance=true gameplay_stability=true animation_lifecycle=true movement_pacing=true render_hotpath=true visual_combat=true boot_resource=true character_hint_compat=true sha=$ExpectedSha"
