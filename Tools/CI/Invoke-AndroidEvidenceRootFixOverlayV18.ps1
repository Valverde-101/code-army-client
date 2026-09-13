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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V18=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v17=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV17.ps1'
if(-not(Test-Path -LiteralPath $v17 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V18=FAIL predecessor_missing=$v17"}
$patcher=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$test=Join-Path $RepoRoot 'Tools\CI\Test-AndroidRuntimePatch.ps1'
$backup=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v18\'+$ExpectedSha)
$patcherBackup=Join-Path $backup 'patcher.post-v17'
$testBackup=Join-Path $backup 'test.post-v17'
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-One([string]$Text,[string]$Old,[string]$New,[string]$Name){
  $n=([regex]::Matches($Text,[regex]::Escape($Old))).Count
  if($n -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V18=FAIL patch=$Name expected=1 actual=$n"}
  Write-Host "EVIDENCE_ROOTFIX_V18_HOOK=PASS name=$Name matches=1"
  return $Text.Replace($Old,$New)
}
if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $patcherBackup){Copy-Item $patcherBackup $patcher -Force}
  if(Test-Path -LiteralPath $testBackup){Copy-Item $testBackup $test -Force}
  if(Test-Path -LiteralPath $backup){Remove-Item $backup -Recurse -Force}
  & $v17 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V18=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V18=PASS mode=restore baseline_restored=true predecessor=v17 sha=$ExpectedSha"
  return
}
& $v17 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V18=FAIL predecessor_apply_exit=$LASTEXITCODE"}
if(Test-Path -LiteralPath $backup){Remove-Item $backup -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backup|Out-Null
Copy-Item $patcher $patcherBackup -Force
Copy-Item $test $testBackup -Force
try {
  $p=[IO.File]::ReadAllText($patcher).Replace("`r`n","`n")
  $p=Replace-One $p '$patchVersion=''mobile-engine-v3.30-impact-ownership-rootfix-v15''' '$patchVersion=''mobile-engine-v3.31-attack-fx-rootfix-v18''' 'patch_version_v18'
  $anchor='Write-Host "SWF_BOOT_PRODUCT_VALIDATE=PASS patched_classes=AssetManager,GameLoadingFirst,GameLoadingSecond patched_sha256=$outputSha"'
  $block=$anchor+"`n"+'foreach($marker in @(''SHOOT_TRANSIENT_ARMED'',''SHOOT_TRANSIENT_CLEANUP'',''SHOOT_TRANSIENT_RESIDUE'',''HIT_EFFECT_ARMED'',''HIT_EFFECT_WATCHDOG_CLEANUP'',''HIT_EFFECT_WALLCLOCK_CLEANUP'')){if($dumpText -notmatch [regex]::Escape($marker)){throw "SWF_V18_BYTECODE_VERIFY=FAIL marker=$marker"}}'+"`n"+'Write-Host "SWF_V18_BYTECODE_VERIFY=PASS patch_version=mobile-engine-v3.31-attack-fx-rootfix-v18 markers=6 patched_sha256=$outputSha"'
  $p=Replace-One $p $anchor $block 'actual_swf_v18_marker_gate'
  Write-Utf8Bom $patcher $p
  $t=[IO.File]::ReadAllText($test).Replace("`r`n","`n")
  $old='Require-Contains $swfPatch ''mobile-engine-v3.30-impact-ownership-rootfix-v15'' ''swf_patch_version_is_v15'''
  $new='Require-Contains $swfPatch ''mobile-engine-v3.31-attack-fx-rootfix-v18'' ''swf_patch_version_is_v18'''+"`n"+'Require-Contains $swfPatch ''SWF_V18_BYTECODE_VERIFY=PASS'' ''swf_patch_verifies_actual_v18_bytecode'''+"`n"+'Require-Contains $animation ''SHOOT_TRANSIENT_CLEANUP'' ''shoot_transient_cleanup_is_compiled'''+"`n"+'Require-Contains $hitV15 ''HIT_EFFECT_WATCHDOG_CLEANUP'' ''hit_watchdog_is_compiled'''
  $t=Replace-One $t $old $new 'runtime_test_v18_contract'
  Write-Utf8Bom $test $t
  Write-Host 'REGRESSION_CHECK=PASS name=latest_attack_fx_cannot_be_silently_overwritten actual_swf_dump_gate=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V18=PASS mode=apply sha=$ExpectedSha predecessor=v17 swf_patch_version=mobile-engine-v3.31-attack-fx-rootfix-v18 actual_bytecode_verify=true"
}
catch {
  $failure=$_
  if(Test-Path -LiteralPath $patcherBackup){Copy-Item $patcherBackup $patcher -Force}
  if(Test-Path -LiteralPath $testBackup){Copy-Item $testBackup $test -Force}
  if(Test-Path -LiteralPath $backup){Remove-Item $backup -Recurse -Force}
  try{& $v17 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{}
  throw $failure
}
