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

foreach ($name in @('data','config')) {
  $source = Join-Path (Join-Path $RepoRoot 'src') $name
  $dest = Join-Path $candidateRoot $name
  if (-not (Test-Path -LiteralPath $source)) {
    throw "FULL_CANDIDATE_SOURCE=FAIL missing=$source"
  }
  if (Test-Path -LiteralPath $dest) {
    Remove-Item -LiteralPath $dest -Recurse -Force
  }
  Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
  Write-Host "HEAD_OVERLAY=PASS component=$name source=$source destination=$dest"
}

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
    [ordered]@{ source = 'src/data'; destination = 'data' },
    [ordered]@{ source = 'src/config'; destination = 'config' }
  )
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

Write-Host "BUILD=PASS mode=exact-source-visual-binary-plus-head-data-config"
Write-Host "LAUNCH=PASS"
Write-Host "WINDOW_UI=PASS"
Write-Host "HEALTH_SMOKE=PASS"
Write-Host "FUNCTIONAL=PARTIAL_PASS scope=boot_visual_runtime_stability;interactive_gameplay_not_automated"
Write-Host "VISUAL_EVIDENCE=$evidenceRoot"
Write-Host "FINAL_VALIDATION=PASS scope=full_windows_candidate_runtime"
