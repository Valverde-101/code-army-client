param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$git=Get-Command git.exe -ErrorAction SilentlyContinue
if(-not $git){
  $portable=Join-Path $AndroidBuildRoot 'Tools\Git\cmd\git.exe'
  if(Test-Path -LiteralPath $portable -PathType Leaf){$git=[pscustomobject]@{Source=$portable}}
}
if(-not $git){throw 'PRECHECK_GIT=FAIL'}
$actual=(& $git.Source -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$actual"}
Write-Host "EXACT_HEAD=PASS sha=$actual"

$upstreamExtract=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\windows-upstream-v23"
$upstreamAppRoot=Join-Path $upstreamExtract '23'
$upstreamExe=Join-Path $upstreamAppRoot 'Army Attack.exe'
$upstreamSwf=Join-Path $upstreamAppRoot 'iArmyAirOfflineSavingv21_2.swf'
$expectedSeedSwf='4b7b09398779c33879f6aff337b57eca6dcc3ad637348a35d22bf2858005f3fc'
$expectedExe='bd83816a1c1d6082960015e27fce056e60ff8d008e5fd2801148014ee3ed5abc'
foreach($required in @($upstreamExe,$upstreamSwf)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "WINDOWS_SEED=FAIL missing=$required"}}
$seedSwfHash=(Get-FileHash $upstreamSwf -Algorithm SHA256).Hash.ToLowerInvariant()
$seedExeHash=(Get-FileHash $upstreamExe -Algorithm SHA256).Hash.ToLowerInvariant()
if($seedSwfHash -ne $expectedSeedSwf){throw "WINDOWS_SEED=FAIL swf expected=$expectedSeedSwf actual=$seedSwfHash"}
if($seedExeHash -ne $expectedExe){throw "WINDOWS_SEED=FAIL exe expected=$expectedExe actual=$seedExeHash"}
Write-Host "WINDOWS_SEED=PASS swf_sha256=$seedSwfHash exe_sha256=$seedExeHash"

$buildRoot=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\windows-full-candidate"
$candidateRoot=Join-Path $buildRoot 'ArmyAttack'
$evidenceRoot=Join-Path $buildRoot 'evidence'
if(Test-Path -LiteralPath $candidateRoot){Remove-Item -LiteralPath $candidateRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $candidateRoot,$evidenceRoot|Out-Null
Get-ChildItem -LiteralPath $upstreamAppRoot -Force|Copy-Item -Destination $candidateRoot -Recurse -Force

$coverage=[ordered]@{strategy='preserve_upstream_then_overlay_head';components=@()}
foreach($name in @('data','config')){
  $source=Join-Path (Join-Path $RepoRoot 'src') $name
  $dest=Join-Path $candidateRoot $name
  if(-not(Test-Path -LiteralPath $source -PathType Container)){throw "HEAD_OVERLAY=FAIL missing=$source"}
  if(-not(Test-Path -LiteralPath $dest)){New-Item -ItemType Directory -Force -Path $dest|Out-Null}
  $before=@(Get-ChildItem -LiteralPath $dest -Recurse -File -Force)
  foreach($child in Get-ChildItem -LiteralPath $source -Force){Copy-Item -LiteralPath $child.FullName -Destination $dest -Recurse -Force}
  $after=@(Get-ChildItem -LiteralPath $dest -Recurse -File -Force)
  $coverage.components += [ordered]@{name=$name;before=$before.Count;after=$after.Count;head=@(Get-ChildItem -LiteralPath $source -Recurse -File -Force).Count}
  Write-Host "HEAD_OVERLAY=PASS component=$name before=$($before.Count) after=$($after.Count)"
}
$coveragePath=Join-Path $buildRoot 'overlay-coverage.json'
$coverage|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $coveragePath -Encoding UTF8

# Validate non-SWF assets against the verified Windows seed before intentionally replacing the SWF.
$contentAuditReport=Join-Path $buildRoot 'content-integrity-before-swf-patch.json'
& (Join-Path $RepoRoot 'Tools\CI\Audit-ContentIntegrity.ps1') -CandidateRoot $candidateRoot -BaselineRoot $upstreamAppRoot -ReportPath $contentAuditReport
Write-Host "CONTENT_INTEGRITY_GATE=PASS report=$contentAuditReport stage=before_intentional_swf_patch"

$candidateExe=Join-Path $candidateRoot 'Army Attack.exe'
$candidateSwf=Join-Path $candidateRoot 'iArmyAirOfflineSavingv21_2.swf'
$patchedSwf=Join-Path $buildRoot 'iArmyAirOfflineSavingv21_2.windows-head-patched.swf'
$patchManifest=Join-Path $buildRoot 'SWF-WINDOWS-SHARED-PATCH.json'
$patcher=Join-Path $RepoRoot 'Tools\CI\Patch-WindowsSharedSwf.ps1'
if(-not(Test-Path -LiteralPath $patcher -PathType Leaf)){throw "WINDOWS_SWF_PARITY=FAIL patcher_missing=$patcher"}
& $patcher -RepoRoot $RepoRoot -InputSwf $upstreamSwf -OutputSwf $patchedSwf -ExpectedSha $ExpectedSha -GitPath $git.Source -ManifestPath $patchManifest
if(-not(Test-Path -LiteralPath $patchedSwf -PathType Leaf)){throw 'WINDOWS_SWF_PARITY=FAIL patched_swf_missing'}
$patchedHash=(Get-FileHash $patchedSwf -Algorithm SHA256).Hash.ToLowerInvariant()
if($patchedHash -eq $seedSwfHash){throw 'WINDOWS_SWF_PARITY=FAIL patched_equals_seed'}
Copy-Item -LiteralPath $patchedSwf -Destination $candidateSwf -Force
$candidateSwfHash=(Get-FileHash $candidateSwf -Algorithm SHA256).Hash.ToLowerInvariant()
if($candidateSwfHash -ne $patchedHash){throw "WINDOWS_SWF_PARITY=FAIL copy_hash expected=$patchedHash actual=$candidateSwfHash"}
Write-Host "WINDOWS_SWF_PARITY=PASS source_sha=$ExpectedSha seed_sha256=$seedSwfHash patched_sha256=$patchedHash candidate_sha256=$candidateSwfHash"

$runtimeValidator=Join-Path $RepoRoot 'Tools\CI\Test-WindowsRuntime.ps1'
& $runtimeValidator -ExePath $candidateExe -WorkingDirectory $candidateRoot -EvidenceRoot $evidenceRoot -Label 'FULL_CANDIDATE_SHARED_SWF' -StabilitySeconds 45

$exe=Get-Item $candidateExe
$swf=Get-Item $candidateSwf
$exeHash=(Get-FileHash $candidateExe -Algorithm SHA256).Hash.ToLowerInvariant()
$swfHash=(Get-FileHash $candidateSwf -Algorithm SHA256).Hash.ToLowerInvariant()
$files=@(Get-ChildItem -LiteralPath $candidateRoot -Recurse -File)
$totalBytes=($files|Measure-Object Length -Sum).Sum
$branch=if($env:SOURCE_BRANCH){$env:SOURCE_BRANCH}else{'detached'}

$provenance=[ordered]@{
  schema=2
  repository='Valverde-101/code-army-client'
  branch=$branch
  tested_sha=$ExpectedSha
  platform='windows-air-desktop'
  exe_seed_sha256=$seedExeHash
  swf_seed_sha256=$seedSwfHash
  swf_patched_sha256=$swfHash
  swf_patch_manifest=$patchManifest
  shared_head_swf=$true
  overlays=@('src/data','src/config')
  generated_utc=(Get-Date).ToUniversalTime().ToString('o')
}
$provenancePath=Join-Path $buildRoot 'BUILD-PROVENANCE.json'
$provenance|ConvertTo-Json -Depth 8|Set-Content $provenancePath -Encoding UTF8

$reportPath=Join-Path $buildRoot 'REPORT.md'
$summaryPath=Join-Path $buildRoot 'summary.json'
$evidenceManifestPath=Join-Path $buildRoot 'manifest.json'
@"
# Army Attack Windows Full Candidate

- Repository: Valverde-101/code-army-client
- Branch: $branch
- TESTED_SHA: $ExpectedSha
- Candidate: $candidateExe
- EXE SHA-256: $exeHash
- SWF seed SHA-256: $seedSwfHash
- SWF patched SHA-256: $swfHash
- SWF integration: HEAD shared AS3/FFDec patch set, Windows AIR profile
- Runtime validation: PASS
- Stability: PASS (45 seconds)
- Evidence: $evidenceRoot
- Patch manifest: $patchManifest

This Windows candidate preserves the verified upstream Windows AIR executable/runtime but replaces the gameplay SWF with a Windows-profile build of the same HEAD-controlled FFDec patch set used by Android. Android-only CONFIG blocks are excluded; shared gameplay, PvP, power-up, FireMission, resource, animation and performance fixes are included.
"@|Set-Content $reportPath -Encoding UTF8

$summary=[ordered]@{
  repository='Valverde-101/code-army-client';branch=$branch;tested_sha=$ExpectedSha
  candidate_root=$candidateRoot;exe_path=$candidateExe;exe_size=$exe.Length;exe_sha256=$exeHash
  swf_size=$swf.Length;swf_sha256=$swfHash;swf_seed_sha256=$seedSwfHash
  swf_shared_head_patch='PASS';build='PASS';launch='PASS';health_smoke='PASS';runtime_stability_seconds=45
  evidence_root=$evidenceRoot;patch_manifest=$patchManifest;report=$reportPath
}
$summary|ConvertTo-Json -Depth 6|Set-Content $summaryPath -Encoding UTF8

$manifestEntries=@()
foreach($file in @(Get-ChildItem -LiteralPath $evidenceRoot -Recurse -File)+@(Get-Item $provenancePath,$coveragePath,$contentAuditReport,$patchManifest,$reportPath,$summaryPath)){
  $manifestEntries += [ordered]@{path=$file.FullName;size=$file.Length;sha256=(Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
}
[ordered]@{tested_sha=$ExpectedSha;files=$manifestEntries}|ConvertTo-Json -Depth 6|Set-Content $evidenceManifestPath -Encoding UTF8

Write-Host "PC_CANDIDATE_PATH=$candidateRoot"
Write-Host "PC_EXE_PATH=$candidateExe"
Write-Host "PC_EXE_SHA256=$exeHash"
Write-Host "PC_SWF_SHA256=$swfHash"
Write-Host "PC_SWF_SEED_SHA256=$seedSwfHash"
Write-Host "PC_SWF_SHARED_HEAD=PASS tested_sha=$ExpectedSha"
Write-Host "FULL_CANDIDATE_FILE_COUNT=$($files.Count)"
Write-Host "FULL_CANDIDATE_TOTAL_BYTES=$totalBytes"
Write-Host "REPORT=$reportPath"
Write-Host "SUMMARY=$summaryPath"
Write-Host "EVIDENCE_MANIFEST=$evidenceManifestPath"
Write-Host 'BUILD=PASS mode=windows-runtime-plus-head-shared-swf'
Write-Host 'LAUNCH=PASS'
Write-Host 'HEALTH_SMOKE=PASS'
Write-Host 'FINAL_VALIDATION=PASS scope=windows_full_candidate_shared_swf'
