param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V8=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V8=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v7=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV7.ps1'
if(-not(Test-Path -LiteralPath $v7 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V8=FAIL predecessor_missing=$v7"}
$testPath=Join-Path $RepoRoot 'Tools\CI\Test-AndroidRuntimePatch.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v8\'+$ExpectedSha)
$backupPath=Join-Path $backupRoot 'runtime-test.post-v7'
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V8=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V8=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V8_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V8=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V8=FAIL restore_backup_missing=$backupPath"}
    Copy-Item -LiteralPath $backupPath -Destination $testPath -Force
    if((Get-Sha256 $testPath) -ne ([string]$manifest.test_sha256).ToUpperInvariant()){throw 'ANDROID_EVIDENCE_ROOTFIX_V8=FAIL restore_hash runtime_test'}
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v7 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V8=PASS mode=restore baseline_restored=true predecessor=v7 sha=$ExpectedSha"
  return
}

& $v7 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if(-not(Test-Path -LiteralPath $testPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V8=FAIL runtime_test_missing=$testPath"}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
Copy-Item -LiteralPath $testPath -Destination $backupPath -Force
$originalHash=Get-Sha256 $testPath
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v8';source_sha=$ExpectedSha;predecessor='v7';test_sha256=$originalHash}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $test=Normalize-Lf ([IO.File]::ReadAllText($testPath))
  $test=Replace-LiteralOne $test '$hfe=Read-Source ''src\game\gameElements\HFEObject.as''' @'
$hfe=Read-Source 'src\game\gameElements\HFEObject.as'
$projectile=Read-Source 'src\game\gameElements\Projectile.as'
'@ 'runtime_test_reads_projectile'

  $old="Require-Contains `$hfe 'HARVEST_TARGET_FPS:Number = 30' 'hfe_harvest_target_rate_is_explicit'"
  $new=@'
Require-Contains $hfe 'HARVEST_TARGET_DURATION_MS:int = 5500' 'hfe_harvest_target_duration_is_explicit'
Require-Contains $hfe 'mode=wallclock_target' 'hfe_harvest_uses_wallclock_target_mode'
Require-Contains $hfe 'Math.max(1,_loc2_.totalFrames - 1) / HARVEST_TARGET_DURATION_MS' 'hfe_harvest_expected_frame_uses_duration'
Require-NotContains $hfe 'HARVEST_TARGET_FPS:Number = 30' 'hfe_harvest_obsolete_target_rate_removed'
'@
  $test=Replace-LiteralOne $test $old $new.TrimEnd() 'runtime_test_hfe_wallclock_contract'

  $anchor="Require-Contains `$hfe 'HFE_HARVEST_PROGRESS' 'hfe_harvest_progress_is_instrumented'"
  $projectileChecks=@'
Require-Contains $hfe 'HFE_HARVEST_PROGRESS' 'hfe_harvest_progress_is_instrumented'
Require-Contains $projectile 'this.addEventListener(Event.ENTER_FRAME,this.autoTick' 'projectile_visual_tick_is_owner_independent'
Require-Contains $projectile 'this.removeEventListener(Event.ENTER_FRAME,this.autoTick)' 'projectile_autotick_is_cleaned_on_destroy'
Require-Contains $projectile 'PROJECTILE_AUTO_TICK_ERROR' 'projectile_autotick_failure_is_observable'
Require-Contains $character 'PROJECTILE_OWNER_OVERLAP' 'rapid_fire_overlap_is_observable'
Require-NotContains $character 'this.mProjectile.update(param1)' 'character_no_longer_drives_projectile_tick'
Require-NotContains $character 'this.mProjectile.parent.removeChild(this.mProjectile)' 'rapid_fire_no_longer_evicts_previous_projectile'
Require-Contains $swfPatch "Class='game.gameElements.Projectile'" 'swf_patch_includes_projectile_base_class'
'@
  $test=Replace-LiteralOne $test $anchor $projectileChecks.TrimEnd() 'runtime_test_projectile_lifecycle_contract'

  foreach($required in @('hfe_harvest_target_duration_is_explicit','projectile_visual_tick_is_owner_independent','rapid_fire_no_longer_evicts_previous_projectile','swf_patch_includes_projectile_base_class')){
    if(-not $test.Contains($required)){throw "ANDROID_EVIDENCE_ROOTFIX_V8=FAIL verification_missing=$required"}
  }
  Write-Utf8Bom $testPath $test
  Write-Host 'REGRESSION_CHECK=PASS name=runtime_test_contract_migrated_from_hfe_fps_to_wallclock_duration old=30fps new=5500ms'
  Write-Host 'REGRESSION_CHECK=PASS name=runtime_test_requires_projectile_owner_independence auto_tick=true no_owner_update=true no_eviction=true swf_injection=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V8=PASS mode=apply sha=$ExpectedSha schema=v8 predecessor=v7"
}catch{
  $failure=$_
  if(Test-Path -LiteralPath $backupPath -PathType Leaf){Copy-Item -LiteralPath $backupPath -Destination $testPath -Force}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v7 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V8_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
