param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V9=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V9=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v8=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV8.ps1'
if(-not(Test-Path -LiteralPath $v8 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V9=FAIL predecessor_missing=$v8"}
$testPath=Join-Path $RepoRoot 'Tools\CI\Test-AndroidRuntimePatch.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v9\'+$ExpectedSha)
$backupPath=Join-Path $backupRoot 'runtime-test.post-v8'
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V9=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V9_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V9=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V9=FAIL restore_backup_missing=$backupPath"}
    Copy-Item -LiteralPath $backupPath -Destination $testPath -Force
    if((Get-Sha256 $testPath) -ne ([string]$manifest.test_sha256).ToUpperInvariant()){throw 'ANDROID_EVIDENCE_ROOTFIX_V9=FAIL restore_hash runtime_test'}
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v8 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V9=PASS mode=restore baseline_restored=true predecessor=v8 sha=$ExpectedSha"
  return
}

& $v8 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if(-not(Test-Path -LiteralPath $testPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V9=FAIL runtime_test_missing=$testPath"}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
Copy-Item -LiteralPath $testPath -Destination $backupPath -Force
$originalHash=Get-Sha256 $testPath
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v9';source_sha=$ExpectedSha;predecessor='v8';test_sha256=$originalHash}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $test=Normalize-Lf ([IO.File]::ReadAllText($testPath))
  $perfTitlePattern='(?m)^Require-Contains \$perfOverlay .*?''perf_panel_title_matches_patched_runtime''\s*\nRequire-NotContains \$perfOverlay .*?''perf_panel_stale_unpatched_claim_removed''\s*$'
  $perfContract=@'
Require-Contains $perfOverlay 'toggleButton = button("PERF");' 'perf_panel_toggle_is_stable'
Require-Contains $perfOverlay 'recordGameEvent("AUTO_FLIGHT_RECORDER", "started_on_activity_attach");' 'perf_recording_starts_on_activity_attach'
Require-Contains $perfOverlay 'REGISTRO SIEMPRE ACTIVO' 'perf_panel_declares_always_on_recording'
Require-NotContains $perfOverlay 'SWF intacto' 'perf_panel_stale_unpatched_claim_removed'
'@
  $test=Replace-RegexOne $test $perfTitlePattern $perfContract.TrimEnd() 'runtime_test_perf_behavior_contract'

  foreach($required in @('perf_panel_toggle_is_stable','perf_recording_starts_on_activity_attach','perf_panel_declares_always_on_recording','perf_panel_stale_unpatched_claim_removed')){
    if(-not $test.Contains($required)){throw "ANDROID_EVIDENCE_ROOTFIX_V9=FAIL verification_missing=$required"}
  }
  if($test.Contains('perf_panel_title_matches_patched_runtime')){throw 'ANDROID_EVIDENCE_ROOTFIX_V9=FAIL stale_title_gate_remaining'}
  Write-Utf8Bom $testPath $test
  Write-Host 'REGRESSION_CHECK=PASS name=perf_gate_validates_behavior_not_decorative_title controls=PERF,MARCAR_LAG,ZIP recording=always_on'
  Write-Host 'REGRESSION_CHECK=PASS name=perf_provenance_remains_manifest_owned patch_version=true class_list=true tested_sha=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V9=PASS mode=apply sha=$ExpectedSha schema=v9 predecessor=v8"
}catch{
  $failure=$_
  if(Test-Path -LiteralPath $backupPath -PathType Leaf){Copy-Item -LiteralPath $backupPath -Destination $testPath -Force}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v8 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V9_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
