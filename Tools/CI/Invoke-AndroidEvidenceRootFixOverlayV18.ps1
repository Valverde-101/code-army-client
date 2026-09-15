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

  # Root cause of d7208ddb failure: FFDec -dumpAS3 only lists AS3 script/class names.
  # Searching that list for method string constants can never prove that V17 bytecode
  # survived the sequential -replace chain. Verify the FINAL SWF by decompiling the
  # exact patched classes after every replacement and inspecting those exported sources.
  $anchor='Write-Host "SWF_BOOT_PRODUCT_VALIDATE=PASS patched_classes=AssetManager,GameLoadingFirst,GameLoadingSecond patched_sha256=$outputSha"'
  $verifyBlock=@'
$verifyDir=Join-Path $outDir 'v18-final-swf-verify'
if(Test-Path -LiteralPath $verifyDir){Remove-Item -LiteralPath $verifyDir -Recurse -Force}
New-Item -ItemType Directory -Force -Path $verifyDir|Out-Null
$verifyClassNames='game.characters.AnimationController,game.utils.HitEffect'
$verifyArgs=@('-cli','-selectclass',$verifyClassNames,'-export','script',$verifyDir,$OutputSwf)
$verifyLog=Join-Path $logRoot 'ffdec-v18-final-source-verify.log'
$previousErrorActionPreference=$ErrorActionPreference
try {
  $ErrorActionPreference='Continue'
  if($java){$verifyLines=@(& $java.Source '-jar' $ffdec.FullName @verifyArgs 2>&1|ForEach-Object{$_.ToString()})}
  else{$verifyLines=@(& $ffdec.FullName @verifyArgs 2>&1|ForEach-Object{$_.ToString()})}
  $verifyExit=$LASTEXITCODE
} finally {
  $ErrorActionPreference=$previousErrorActionPreference
}
$verifyLines|Set-Content -LiteralPath $verifyLog -Encoding UTF8
if($verifyExit -ne 0){
  $verifyLines|Select-Object -Last 120|ForEach-Object{Write-Host $_}
  throw "SWF_V18_BYTECODE_VERIFY=FAIL operation=export_final_classes exit=$verifyExit log=$verifyLog"
}
$animationCandidates=@(Get-ChildItem -LiteralPath $verifyDir -Recurse -File -Filter 'AnimationController.as' -ErrorAction SilentlyContinue)
$hitCandidates=@(Get-ChildItem -LiteralPath $verifyDir -Recurse -File -Filter 'HitEffect.as' -ErrorAction SilentlyContinue)
if($animationCandidates.Count -ne 1){throw "SWF_V18_BYTECODE_VERIFY=FAIL class=game.characters.AnimationController exported=$($animationCandidates.Count) dir=$verifyDir"}
if($hitCandidates.Count -ne 1){throw "SWF_V18_BYTECODE_VERIFY=FAIL class=game.utils.HitEffect exported=$($hitCandidates.Count) dir=$verifyDir"}
$animationExport=$animationCandidates[0]
$hitExport=$hitCandidates[0]
$animationFinal=[IO.File]::ReadAllText($animationExport.FullName)
$hitFinal=[IO.File]::ReadAllText($hitExport.FullName)
$animationMarkers=@('SHOOT_TRANSIENT_ARMED','SHOOT_TRANSIENT_CLEANUP','SHOOT_TRANSIENT_RESIDUE','armTransientShoot','cleanupTransientShoot','shootTransientFrame')
$hitMarkers=@('HIT_EFFECT_ARMED','HIT_EFFECT_WATCHDOG_CLEANUP','HIT_EFFECT_WALLCLOCK_CLEANUP','handleCleanupTimeout','HIT_EFFECT_WATCHDOG_MS')
foreach($marker in $animationMarkers){if($animationFinal -notmatch [regex]::Escape($marker)){throw "SWF_V18_BYTECODE_VERIFY=FAIL class=game.characters.AnimationController marker=$marker source=$($animationExport.FullName)"}}
foreach($marker in $hitMarkers){if($hitFinal -notmatch [regex]::Escape($marker)){throw "SWF_V18_BYTECODE_VERIFY=FAIL class=game.utils.HitEffect marker=$marker source=$($hitExport.FullName)"}}
$verifyManifest=[ordered]@{
  schema='armyattack-final-swf-v18-verify/v1'
  tested_sha=$ExpectedSha
  patch_version=$patchVersion
  output_swf=[ordered]@{path=$OutputSwf;size=$outputInfo.Length;sha256=$outputSha}
  method='ffdec-selectclass-export-script'
  classes=@(
    [ordered]@{name='game.characters.AnimationController';export=$animationExport.FullName;sha256=(Get-FileHash -LiteralPath $animationExport.FullName -Algorithm SHA256).Hash.ToLowerInvariant();markers=$animationMarkers},
    [ordered]@{name='game.utils.HitEffect';export=$hitExport.FullName;sha256=(Get-FileHash -LiteralPath $hitExport.FullName -Algorithm SHA256).Hash.ToLowerInvariant();markers=$hitMarkers}
  )
  generated_utc=[DateTime]::UtcNow.ToString('o')
}
$verifyManifestPath=Join-Path $logRoot 'SWF-V18-FINAL-VERIFY.json'
$verifyManifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $verifyManifestPath -Encoding UTF8
Write-Host "SWF_V18_BYTECODE_VERIFY=PASS method=decompiled_final_swf classes=AnimationController,HitEffect markers=$($animationMarkers.Count+$hitMarkers.Count) patch_version=$patchVersion patched_sha256=$outputSha manifest=$verifyManifestPath log=$verifyLog"
'@
  $block=$anchor+"`n"+$verifyBlock.TrimEnd()
  $p=Replace-One $p $anchor $block 'actual_swf_v18_decompiled_class_gate'
  Write-Utf8Bom $patcher $p

  $t=[IO.File]::ReadAllText($test).Replace("`r`n","`n")
  $old='Require-Contains $swfPatch ''mobile-engine-v3.30-impact-ownership-rootfix-v15'' ''swf_patch_version_is_v15'''
  $new='Require-Contains $swfPatch ''mobile-engine-v3.31-attack-fx-rootfix-v18'' ''swf_patch_version_is_v18'''+"`n"+'Require-Contains $swfPatch ''SWF_V18_BYTECODE_VERIFY=PASS method=decompiled_final_swf'' ''swf_patch_verifies_decompiled_final_v18_classes'''+"`n"+'Require-Contains $swfPatch ''-selectclass'' ''swf_patch_uses_ffdec_class_export_not_dump_list'''+"`n"+'Require-Contains $animation ''SHOOT_TRANSIENT_CLEANUP'' ''shoot_transient_cleanup_is_compiled'''+"`n"+'Require-Contains $hitV15 ''HIT_EFFECT_WATCHDOG_CLEANUP'' ''hit_watchdog_is_compiled'''
  $t=Replace-One $t $old $new 'runtime_test_v18_contract'
  Write-Utf8Bom $test $t
  Write-Host 'REGRESSION_CHECK=PASS name=latest_attack_fx_cannot_be_silently_overwritten verification=decompile_final_swf selected_classes=AnimationController,HitEffect dumpas3_class_list_not_misused=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V18=PASS mode=apply sha=$ExpectedSha predecessor=v17 swf_patch_version=mobile-engine-v3.31-attack-fx-rootfix-v18 actual_bytecode_verify=decompiled_final_swf"
}
catch {
  $failure=$_
  if(Test-Path -LiteralPath $patcherBackup){Copy-Item $patcherBackup $patcher -Force}
  if(Test-Path -LiteralPath $testBackup){Copy-Item $testBackup $test -Force}
  if(Test-Path -LiteralPath $backup){Remove-Item $backup -Recurse -Force}
  try{& $v17 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{}
  throw $failure
}
