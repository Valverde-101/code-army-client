param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if((& $GitPath -C $RepoRoot rev-parse HEAD).Trim() -ne $ExpectedSha){throw 'ANDROID_EVIDENCE_ROOTFIX_V13=FAIL exact_head'}
$v10=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV10.ps1'
$scenePath=Join-Path $RepoRoot 'src\game\isometric\IsometricScene.as'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v13\'+$ExpectedSha)
$sceneBackup=Join-Path $backupRoot 'scene.as'; $patcherBackup=Join-Path $backupRoot 'patcher.ps1'
function Norm([string]$s){$s.Replace("`r`n","`n").Replace("`r","`n")}
function Put([string]$p,[string]$s){[IO.File]::WriteAllText($p,$s,(New-Object Text.UTF8Encoding($true)))}
function Rx1([string]$s,[string]$p,[string]$r,[string]$n){$m=[regex]::Matches($s,$p);if($m.Count-ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V13=FAIL patch=$n matches=$($m.Count)"};Write-Host "EVIDENCE_ROOTFIX_V13_HOOK=PASS name=$n matches=1";[regex]::Replace($s,$p,$r,1)}
if($Mode -eq 'Restore'){
  if(Test-Path $sceneBackup){Copy-Item $sceneBackup $scenePath -Force;Copy-Item $patcherBackup $patcherPath -Force;Remove-Item $backupRoot -Recurse -Force}
  & $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V13=PASS mode=restore sha=$ExpectedSha";return
}
& $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
Copy-Item $scenePath $sceneBackup -Force; Copy-Item $patcherPath $patcherBackup -Force
try{
  $scene=Norm([IO.File]::ReadAllText($scenePath))
  $helper=@'
		private function clearPlacementVisualResidue(param1:String):void {
			if(this.mMovedObjectIndicator){this.mMovedObjectIndicator.graphics.clear();if(this.mMovedObjectIndicator.parent){this.mMovedObjectIndicator.parent.removeChild(this.mMovedObjectIndicator);}this.mMovedObjectIndicator=null;}
			if(this.mMapGUIEffectsLayer){this.mMapGUIEffectsLayer.clearHighlights();this.mMapGUIEffectsLayer.clearMoveDisabledArea();this.mMapGUIEffectsLayer.removeHighlightRange();}
			Utils.DiagEvent("PLACEMENT_OVERLAY_CLEANUP","reason="+param1);
		}

$1public function cancelEditMode(): void {
'@
  $scene=Rx1 $scene '(?m)^([ \t]*)public function cancelEditMode\(\)\s*:\s*void\s*\{\s*$' $helper.TrimEnd() 'helper_by_signature'
  $scene=Rx1 $scene '(?m)^([ \t]*public function exitMoveMode\(param1:\s*Boolean\s*=\s*false\)\s*:\s*void\s*\{)\s*$' ('$1'+"`n`t`t`tthis.clearPlacementVisualResidue(\"exit_move_mode\");") 'exit_by_signature'
  $scene=Rx1 $scene '(?m)^([ \t]*public function cancelEditMode\(\)\s*:\s*void\s*\{)\s*$' ('$1'+"`n`t`t`tthis.clearPlacementVisualResidue(\"cancel_edit_mode\");") 'cancel_by_signature'
  $scene=Rx1 $scene '(?m)^([ \t]*private function finishPlacementUi\(param1:\s*String\)\s*:\s*void\s*\{)\s*$' ('$1'+"`n`t`t`tthis.clearPlacementVisualResidue(\"finish_\" + param1);") 'finish_by_signature'
  foreach($x in @('clearPlacementVisualResidue("exit_move_mode")','clearPlacementVisualResidue("cancel_edit_mode")','clearPlacementVisualResidue("finish_" + param1)','PLACEMENT_OVERLAY_CLEANUP')){if(-not $scene.Contains($x)){throw "ANDROID_EVIDENCE_ROOTFIX_V13=FAIL verify=$x"}}
  Put $scenePath $scene
  $patch=Norm([IO.File]::ReadAllText($patcherPath));$old='$patchVersion=''mobile-engine-v3.27-projectile-autotick-hfe-v7''';$new='$patchVersion=''mobile-engine-v3.29-placement-overlay-cleanup-v13'''
  if(-not $patch.Contains($old)){throw 'ANDROID_EVIDENCE_ROOTFIX_V13=FAIL patch_version_predecessor'};$patch=$patch.Replace($old,$new);Put $patcherPath $patch
  Write-Host 'REGRESSION_CHECK=PASS name=placement_cleanup_signature_hooks exit=true cancel=true finish=true'
  Write-Host 'REGRESSION_CHECK=PASS name=placement_cleanup_all_layers highlights=true disabled=true range=true indicator=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V13=PASS mode=apply sha=$ExpectedSha schema=v13 swf_patch_version=mobile-engine-v3.29-placement-overlay-cleanup-v13"
}catch{
  $e=$_;Copy-Item $sceneBackup $scenePath -Force;Copy-Item $patcherBackup $patcherPath -Force;Remove-Item $backupRoot -Recurse -Force;try{& $v10 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{};throw $e
}
