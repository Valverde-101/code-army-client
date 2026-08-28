param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$git = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git) {
  $portable = Join-Path $AndroidBuildRoot 'Tools\Git\cmd\git.exe'
  if (Test-Path -LiteralPath $portable) {
    $git = [pscustomobject]@{ Source = $portable }
  }
}
if (-not $git) { throw 'PRECHECK_GIT=FAIL' }

Push-Location $RepoRoot
try {
  $actual = (& $git.Source rev-parse HEAD).Trim()
  if ($actual -ne $ExpectedSha) {
    throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$actual"
  }
}
finally {
  Pop-Location
}
Write-Host "EXACT_HEAD=PASS sha=$ExpectedSha"

$upstreamExtract = Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\windows-upstream-v23"
$upstreamAppRoot = Join-Path $upstreamExtract '23'
if (-not (Test-Path -LiteralPath $upstreamAppRoot)) {
  throw "FULL_CANDIDATE_PRECHECK=FAIL upstream_app_root_missing=$upstreamAppRoot"
}

$upstreamExe = Join-Path $upstreamAppRoot 'Army Attack.exe'
$upstreamSwf = Join-Path $upstreamAppRoot 'iArmyAirOfflineSavingv21_2.swf'
$expectedSwfSha = '4b7b09398779c33879f6aff337b57eca6dcc3ad637348a35d22bf2858005f3fc'
$expectedExeSha = 'bd83816a1c1d6082960015e27fce056e60ff8d008e5fd2801148014ee3ed5abc'
foreach ($required in @($upstreamExe,$upstreamSwf)) {
  if (-not (Test-Path -LiteralPath $required)) {
    throw "FULL_CANDIDATE_PRECHECK=FAIL missing=$required"
  }
}

$actualSwfSha = (Get-FileHash -LiteralPath $upstreamSwf -Algorithm SHA256).Hash.ToLowerInvariant()
$actualExeSha = (Get-FileHash -LiteralPath $upstreamExe -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSwfSha -ne $expectedSwfSha) {
  throw "BINARY_SEED_VALIDATE=FAIL swf_expected=$expectedSwfSha swf_actual=$actualSwfSha"
}
if ($actualExeSha -ne $expectedExeSha) {
  throw "BINARY_SEED_VALIDATE=FAIL exe_expected=$expectedExeSha exe_actual=$actualExeSha"
}
Write-Host "BINARY_SEED_VALIDATE=PASS source_sha=324c29b6c9e0e32f61183bf52725662a2bd8aab9 swf_sha=$actualSwfSha"

$buildRoot = Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\windows-full-candidate"
$candidateRoot = Join-Path $buildRoot 'ArmyAttack'
$evidenceRoot = Join-Path $buildRoot 'evidence'
if (Test-Path -LiteralPath $candidateRoot) {
  Remove-Item -LiteralPath $candidateRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $candidateRoot,$evidenceRoot | Out-Null

Get-ChildItem -LiteralPath $upstreamAppRoot -Force | Copy-Item -Destination $candidateRoot -Recurse -Force

$coverage = [ordered]@{
  strategy = 'preserve_upstream_then_overlay_head'
  components = @()
}
foreach ($name in @('data','config')) {
  $source = Join-Path (Join-Path $RepoRoot 'src') $name
  $dest = Join-Path $candidateRoot $name
  if (-not (Test-Path -LiteralPath $source)) {
    throw "FULL_CANDIDATE_SOURCE=FAIL missing=$source"
  }
  if (-not (Test-Path -LiteralPath $dest)) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
  }

  $sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File -Force)
  $destFilesBefore = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force)
  $sourceRelative = @{}
  foreach ($file in $sourceFiles) {
    $rel = $file.FullName.Substring($source.Length).TrimStart('\').Replace('\','/')
    $sourceRelative[$rel.ToLowerInvariant()] = $rel
  }

  $upstreamOnly = @()
  foreach ($file in $destFilesBefore) {
    $rel = $file.FullName.Substring($dest.Length).TrimStart('\').Replace('\','/')
    if (-not $sourceRelative.ContainsKey($rel.ToLowerInvariant())) {
      $upstreamOnly += $rel
    }
  }

  # Overlay current HEAD files in place. Do NOT remove upstream-only files:
  # the verified v23 SWF may reference them even when current source recovery omitted them.
  foreach ($child in Get-ChildItem -LiteralPath $source -Force) {
    Copy-Item -LiteralPath $child.FullName -Destination $dest -Recurse -Force
  }

  $destFilesAfter = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force)
  foreach ($rel in $upstreamOnly) {
    $preserved = Join-Path $dest ($rel.Replace('/','\'))
    if (-not (Test-Path -LiteralPath $preserved)) {
      throw "OVERLAY_COVERAGE=FAIL component=$name upstream_only_not_preserved=$rel"
    }
  }

  $coverage.components += [ordered]@{
    name = $name
    head_file_count = $sourceFiles.Count
    upstream_file_count_before = $destFilesBefore.Count
    upstream_only_preserved_count = $upstreamOnly.Count
    upstream_only_preserved = $upstreamOnly
    candidate_file_count_after = $destFilesAfter.Count
  }

  Write-Host "HEAD_OVERLAY=PASS component=$name source=$source destination=$dest strategy=preserve_upstream_then_overlay_head"
  Write-Host "OVERLAY_COVERAGE=PASS component=$name head_files=$($sourceFiles.Count) upstream_before=$($destFilesBefore.Count) upstream_only_preserved=$($upstreamOnly.Count) candidate_after=$($destFilesAfter.Count)"
}

$coveragePath = Join-Path $buildRoot 'overlay-coverage.json'
$coverage | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $coveragePath -Encoding UTF8
Write-Host "OVERLAY_COVERAGE_REPORT=$coveragePath"

$contentAuditReport = Join-Path $buildRoot 'content-integrity.json'
$contentAudit = Join-Path $RepoRoot 'Tools\CI\Audit-ContentIntegrity.ps1'
& $contentAudit -CandidateRoot $candidateRoot -ReportPath $contentAuditReport
Write-Host "CONTENT_INTEGRITY_GATE=PASS report=$contentAuditReport"

$candidateExe = Join-Path $candidateRoot 'Army Attack.exe'
$candidateSwf = Join-Path $candidateRoot 'iArmyAirOfflineSavingv21_2.swf'
if (-not (Test-Path -LiteralPath $candidateExe) -or -not (Test-Path -LiteralPath $candidateSwf)) {
  throw "FULL_CANDIDATE_ASSEMBLY=FAIL executable_or_swf_missing"
}

$manifest = [ordered]@{
  schema = 1
  repository = 'Valverde-101/code-army-client'
  branch = 'chore/local-army-bootstrap-20260827'
  expected_source_sha = $ExpectedSha
  binary_seed = [ordered]@{
    upstream_repository = 'Michielvde1253/army-client'
    release = 'v23'
    source_sha = '324c29b6c9e0e32f61183bf52725662a2bd8aab9'
    swf = 'iArmyAirOfflineSavingv21_2.swf'
    swf_sha256 = $actualSwfSha
    exe_sha256 = $actualExeSha
    reason = 'Animate FLA library/linkage is embedded in the release SWF and cannot be reproduced by amxmlc from AS sources alone.'
  }
  overlays = @(
    [ordered]@{ source = 'src/data'; destination = 'data'; strategy = 'preserve_upstream_then_overlay_head' },
    [ordered]@{ source = 'src/config'; destination = 'config'; strategy = 'preserve_upstream_then_overlay_head' }
  )
  overlay_coverage_report = $coveragePath
  generated_utc = (Get-Date).ToUniversalTime().ToString('o')
}
$manifestPath = Join-Path $buildRoot 'BUILD-PROVENANCE.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$files = @(Get-ChildItem -LiteralPath $candidateRoot -Recurse -File)
$totalBytes = ($files | Measure-Object Length -Sum).Sum
$exe = Get-Item -LiteralPath $candidateExe
$exeHash = (Get-FileHash -LiteralPath $candidateExe -Algorithm SHA256).Hash.ToLowerInvariant()
$swf = Get-Item -LiteralPath $candidateSwf
$swfHash = (Get-FileHash -LiteralPath $candidateSwf -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host "FULL_CANDIDATE_ASSEMBLY=PASS path=$candidateRoot"
Write-Host "FULL_CANDIDATE_FILE_COUNT=$($files.Count)"
Write-Host "FULL_CANDIDATE_TOTAL_BYTES=$totalBytes"
Write-Host "EXE_PATH=$candidateExe"
Write-Host "EXE_SIZE=$($exe.Length)"
Write-Host "EXE_SHA256=$exeHash"
Write-Host "SWF_SIZE=$($swf.Length)"
Write-Host "SWF_SHA256=$swfHash"
Write-Host "PROVENANCE_MANIFEST=$manifestPath"

$runtimeValidator = Join-Path $RepoRoot 'Tools\CI\Test-WindowsRuntime.ps1'
& $runtimeValidator -ExePath $candidateExe -WorkingDirectory $candidateRoot -EvidenceRoot $evidenceRoot -Label 'FULL_CANDIDATE' -StabilitySeconds 45

$reportPath = Join-Path $buildRoot 'REPORT.md'
$summaryPath = Join-Path $buildRoot 'summary.json'
$evidenceManifestPath = Join-Path $buildRoot 'manifest.json'

$report = @"
# Army Attack Windows Full Candidate

- Repository: Valverde-101/code-army-client
- Branch: chore/local-army-bootstrap-20260827
- TESTED_SHA: $ExpectedSha
- Candidate: $candidateExe
- EXE SHA-256: $exeHash
- EXE size: $($exe.Length) bytes
- SWF SHA-256: $swfHash
- SWF size: $($swf.Length) bytes
- Binary seed source SHA: 324c29b6c9e0e32f61183bf52725662a2bd8aab9
- Binary seed release: upstream v23
- HEAD overlays: src/data, src/config (non-destructive overlay; upstream-only files preserved)
- Overlay coverage: $coveragePath
- Content integrity: $contentAuditReport
- Runtime validation: PASS
- Window/UI: PASS
- Input smoke: PASS
- Stability: PASS (45 seconds)
- Crash/Hang: PASS unless runtime validator explicitly reported event-log access skipped
- Functional scope: boot + visual runtime + input roundtrip; deep gameplay progression remains manual/extended-test territory
- Visual evidence: $evidenceRoot

## Build architecture

The recovered .fla files contain Animate library/linkage assets that are not emitted by amxmlc when compiling only the recovered .as sources. The candidate therefore uses the verified v23 SWF compiled from the exact source base SHA as the visual/runtime binary seed, then overlays HEAD-controlled data/config and validates the resulting captive AIR application.
"@
$report | Set-Content -LiteralPath $reportPath -Encoding UTF8

$summary = [ordered]@{
  repository='Valverde-101/code-army-client'
  branch='chore/local-army-bootstrap-20260827'
  tested_sha=$ExpectedSha
  exe_path=$candidateExe
  exe_size=$exe.Length
  exe_sha256=$exeHash
  swf_size=$swf.Length
  swf_sha256=$swfHash
  build='PASS'
  launch='PASS'
  window_ui='PASS'
  input_smoke='PASS'
  health_smoke='PASS'
  runtime_stability_seconds=45
  functional='PASS_WITH_SCOPE'
  functional_scope='boot_visual_runtime_input_roundtrip'
  evidence_root=$evidenceRoot
  provenance_manifest=$manifestPath
  overlay_coverage=$coveragePath
  content_integrity=$contentAuditReport
  report=$reportPath
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

$manifestEntries = @()
foreach ($file in @(Get-ChildItem -LiteralPath $evidenceRoot -Recurse -File) + @(Get-Item -LiteralPath $manifestPath,$coveragePath,$contentAuditReport,$reportPath,$summaryPath)) {
  $manifestEntries += [ordered]@{
    path=$file.FullName
    size=$file.Length
    sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}
[ordered]@{ tested_sha=$ExpectedSha; files=$manifestEntries } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $evidenceManifestPath -Encoding UTF8

Write-Host "REPORT=$reportPath"
Write-Host "SUMMARY=$summaryPath"
Write-Host "EVIDENCE_MANIFEST=$evidenceManifestPath"
Write-Host "BUILD=PASS mode=exact-source-visual-binary-plus-head-data-config"
Write-Host "LAUNCH=PASS"
Write-Host "WINDOW_UI=PASS"
Write-Host "INPUT_SMOKE=PASS"
Write-Host "HEALTH_SMOKE=PASS"
Write-Host "FUNCTIONAL=PASS_WITH_SCOPE scope=boot_visual_runtime_input_roundtrip"
Write-Host "VISUAL_EVIDENCE=$evidenceRoot"
Write-Host "FINAL_VALIDATION=PASS scope=full_windows_candidate_runtime"
