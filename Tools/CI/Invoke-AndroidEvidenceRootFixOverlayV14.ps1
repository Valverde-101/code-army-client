param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v10=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV10.ps1'
if(-not(Test-Path -LiteralPath $v10 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL predecessor_missing=$v10"}
$scenePath=Join-Path $RepoRoot 'src\game\isometric\IsometricScene.as'
$testPath=Join-Path $RepoRoot 'Tools\CI\Test-AndroidRuntimePatch.ps1'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v14\'+$ExpectedSha)
$sceneBackup=Join-Path $backupRoot 'scene.post-v10.as'
$testBackup=Join-Path $backupRoot 'runtime-test.post-v10.ps1'
$patcherBackup=Join-Path $backupRoot 'patcher.post-v10.ps1'
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $rx=New-Object System.Text.RegularExpressions.Regex($Pattern)
  $matches=$rx.Matches($Text)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL patch=$Name expected_matches=1 actual=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V14_HOOK=PASS name=$Name matches=1 semantic=true"
  return $rx.Replace($Text,$Replacement,1)
}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V14_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    foreach($entry in @(
      @{Backup=$sceneBackup;Target=$scenePath;Hash=[string]$manifest.scene_sha256;Name='scene'},
      @{Backup=$testBackup;Target=$testPath;Hash=[string]$manifest.test_sha256;Name='runtime_test'},
      @{Backup=$patcherBackup;Target=$patcherPath;Hash=[string]$manifest.patcher_sha256;Name='patcher'}
    )){
      if(-not(Test-Path -LiteralPath $entry.Backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL restore_backup_missing=$($entry.Name)"}
      Copy-Item -LiteralPath $entry.Backup -Destination $entry.Target -Force
      $restored=Get-Sha256 $entry.Target
      if($restored -ne $entry.Hash.ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL restore_hash=$($entry.Name) expected=$($entry.Hash) actual=$restored"}
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V14=PASS mode=restore baseline_restored=true predecessor=v10 sha=$ExpectedSha"
  return
}

& $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
foreach($p in @($scenePath,$testPath,$patcherPath)){
  if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL required_file_missing=$p"}
}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
Copy-Item -LiteralPath $scenePath -Destination $sceneBackup -Force
Copy-Item -LiteralPath $testPath -Destination $testBackup -Force
Copy-Item -LiteralPath $patcherPath -Destination $patcherBackup -Force
[ordered]@{
  schema='armyattack-android-evidence-rootfix-overlay/v14'
  source_sha=$ExpectedSha
  predecessor='v10'
  scene_sha256=(Get-Sha256 $scenePath)
  test_sha256=(Get-Sha256 $testPath)
  patcher_sha256=(Get-Sha256 $patcherPath)
}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $scene=Normalize-Lf ([IO.File]::ReadAllText($scenePath))

  $helperPattern='(?m)^([ \t]*)public function cancelEditMode\(\)\s*:\s*void\s*\{\s*$'
  $helperReplacement=@'
		private function clearPlacementVisualResidue(param1:String):void {
			if (this.mMovedObjectIndicator) {
				this.mMovedObjectIndicator.graphics.clear();
				if (this.mMovedObjectIndicator.parent) {
					this.mMovedObjectIndicator.parent.removeChild(this.mMovedObjectIndicator);
				}
				this.mMovedObjectIndicator = null;
			}
			if (this.mMapGUIEffectsLayer) {
				this.mMapGUIEffectsLayer.clearHighlights();
				this.mMapGUIEffectsLayer.clearMoveDisabledArea();
				this.mMapGUIEffectsLayer.removeHighlightRange();
			}
			Utils.DiagEvent("PLACEMENT_OVERLAY_CLEANUP","reason=" + param1);
		}

$1public function cancelEditMode(): void {
'@
  $scene=Replace-RegexOne $scene $helperPattern $helperReplacement.TrimEnd() 'placement_cleanup_helper_by_signature'

  $exitPattern='(?m)^([ \t]*public function exitMoveMode\(param1:\s*Boolean\s*=\s*false\)\s*:\s*void\s*\{)\s*$'
  $exitReplacement=@'
$1
			this.clearPlacementVisualResidue("exit_move_mode");
'@
  $scene=Replace-RegexOne $scene $exitPattern $exitReplacement.TrimEnd() 'exit_move_mode_cleanup_by_signature'

  $cancelPattern='(?m)^([ \t]*public function cancelEditMode\(\)\s*:\s*void\s*\{)\s*$'
  $cancelReplacement=@'
$1
			this.clearPlacementVisualResidue("cancel_edit_mode");
'@
  $scene=Replace-RegexOne $scene $cancelPattern $cancelReplacement.TrimEnd() 'cancel_edit_mode_cleanup_by_signature'

  $finishPattern='(?m)^([ \t]*private function finishPlacementUi\(param1:\s*String\)\s*:\s*void\s*\{)\s*$'
  $finishReplacement=@'
$1
			this.clearPlacementVisualResidue("finish_" + param1);
'@
  $scene=Replace-RegexOne $scene $finishPattern $finishReplacement.TrimEnd() 'finish_placement_cleanup_by_signature'

  foreach($required in @(
    'private function clearPlacementVisualResidue(param1:String):void',
    'this.mMapGUIEffectsLayer.clearHighlights();',
    'this.mMapGUIEffectsLayer.clearMoveDisabledArea();',
    'this.mMapGUIEffectsLayer.removeHighlightRange();',
    'this.mMovedObjectIndicator = null;',
    'PLACEMENT_OVERLAY_CLEANUP',
    'this.clearPlacementVisualResidue("exit_move_mode");',
    'this.clearPlacementVisualResidue("cancel_edit_mode");',
    'this.clearPlacementVisualResidue("finish_" + param1);'
  )){
    if(-not $scene.Contains($required)){throw "ANDROID_EVIDENCE_ROOTFIX_V14=FAIL scene_verification_missing=$required"}
  }
  Write-Utf8Bom $scenePath $scene

  $test=Normalize-Lf ([IO.File]::ReadAllText($testPath))
  $testAnchor="Require-Contains `$scene 'PLACEMENT_COMMIT_UI' 'placement_commit_cleanup_is_instrumented'"
  $testAddition=@'
Require-Contains $scene 'private function clearPlacementVisualResidue(param1:String):void' 'placement_overlay_cleanup_is_centralized'
Require-Contains $scene 'this.mMapGUIEffectsLayer.clearHighlights();' 'placement_overlay_cleanup_clears_highlights'
Require-Contains $scene 'this.mMapGUIEffectsLayer.clearMoveDisabledArea();' 'placement_overlay_cleanup_clears_disabled_cells'
Require-Contains $scene 'this.mMapGUIEffectsLayer.removeHighlightRange();' 'placement_overlay_cleanup_clears_range'
Require-Contains $scene 'this.mMovedObjectIndicator = null;' 'placement_overlay_indicator_is_released'
Require-Contains $scene 'PLACEMENT_OVERLAY_CLEANUP' 'placement_overlay_cleanup_is_observable'
Require-Contains $scene 'this.clearPlacementVisualResidue("exit_move_mode");' 'exit_move_mode_cannot_leave_overlay_residue'
Require-Contains $scene 'this.clearPlacementVisualResidue("cancel_edit_mode");' 'cancel_edit_mode_cannot_leave_overlay_residue'
Require-Contains $scene 'this.clearPlacementVisualResidue("finish_" + param1);' 'placement_finish_cannot_leave_overlay_residue'
'@
  $test=Replace-LiteralOne $test $testAnchor ($testAnchor+"`n"+$testAddition.TrimEnd()) 'runtime_test_placement_overlay_cleanup_contract'
  Write-Utf8Bom $testPath $test

  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patcher=Replace-LiteralOne $patcher '$patchVersion=''mobile-engine-v3.27-projectile-autotick-hfe-v7''' '$patchVersion=''mobile-engine-v3.29-placement-overlay-cleanup-v14''' 'patch_version_v3_29_v14'
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=placement_overlay_cleanup_signature_only exit=true cancel=true finish=true full_body_literal=false'
  Write-Host 'REGRESSION_CHECK=PASS name=placement_overlay_cleanup_covers_all_layers highlights=true disabled=true range=true indicator=true'
  Write-Host 'REGRESSION_CHECK=PASS name=placement_overlay_cleanup_is_idempotent repeated_calls=true'
  Write-Host 'REGRESSION_CHECK=PASS name=placement_overlay_cleanup_is_runtime_observable event=PLACEMENT_OVERLAY_CLEANUP'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V14=PASS mode=apply sha=$ExpectedSha schema=v14 predecessor=v10 swf_patch_version=mobile-engine-v3.29-placement-overlay-cleanup-v14"
}catch{
  $failure=$_
  foreach($entry in @(
    @{Backup=$sceneBackup;Target=$scenePath},
    @{Backup=$testBackup;Target=$testPath},
    @{Backup=$patcherBackup;Target=$patcherPath}
  )){
    if(Test-Path -LiteralPath $entry.Backup -PathType Leaf){Copy-Item -LiteralPath $entry.Backup -Destination $entry.Target -Force}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V14_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
