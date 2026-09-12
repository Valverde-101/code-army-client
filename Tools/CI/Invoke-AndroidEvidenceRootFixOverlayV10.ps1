param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V10=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V10=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v9=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV9.ps1'
if(-not(Test-Path -LiteralPath $v9 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V10=FAIL predecessor_missing=$v9"}
$testPath=Join-Path $RepoRoot 'Tools\CI\Test-AndroidRuntimePatch.ps1'
$perfPath=Join-Path $RepoRoot 'android\native\diagnostics\java\com\valverde\armyattack\diagnostics\PerformanceOverlay.java'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v10\'+$ExpectedSha)
$testBackup=Join-Path $backupRoot 'runtime-test.post-v9'
$perfBackup=Join-Path $backupRoot 'PerformanceOverlay.java.baseline'
$manifestPath=Join-Path $backupRoot 'manifest.json'
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V10=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V10=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V10_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V10=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    foreach($entry in @(
      @{Backup=$testBackup;Target=$testPath;Hash=[string]$manifest.test_sha256;Name='runtime_test'},
      @{Backup=$perfBackup;Target=$perfPath;Hash=[string]$manifest.perf_sha256;Name='performance_overlay'}
    )){
      if(-not(Test-Path -LiteralPath $entry.Backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V10=FAIL restore_backup_missing=$($entry.Name)"}
      Copy-Item -LiteralPath $entry.Backup -Destination $entry.Target -Force
      if((Get-Sha256 $entry.Target) -ne $entry.Hash.ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V10=FAIL restore_hash $($entry.Name)"}
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v9 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V10=PASS mode=restore baseline_restored=true predecessor=v9 sha=$ExpectedSha"
  return
}

& $v9 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
foreach($p in @($testPath,$perfPath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V10=FAIL required_file_missing=$p"}}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
Copy-Item -LiteralPath $testPath -Destination $testBackup -Force
Copy-Item -LiteralPath $perfPath -Destination $perfBackup -Force
[ordered]@{
  schema='armyattack-android-evidence-rootfix-overlay/v10'
  source_sha=$ExpectedSha
  predecessor='v9'
  test_sha256=(Get-Sha256 $testPath)
  perf_sha256=(Get-Sha256 $perfPath)
}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $perf=Normalize-Lf ([IO.File]::ReadAllText($perfPath))
  $perf=Replace-LiteralOne $perf 'toggleButton = button("PERF");' 'toggleButton = button("PERF\n" + shortBuildId());' 'perf_button_shows_build_id'
  $perf=Replace-LiteralOne $perf 'new FrameLayout.LayoutParams(dp(76), dp(44), Gravity.TOP | Gravity.END);' 'new FrameLayout.LayoutParams(dp(96), dp(54), Gravity.TOP | Gravity.END);' 'perf_button_size_for_build_id'
  $perf=Replace-LiteralOne $perf 'TextView title = text("Army Perf · runtime instrumentado", 16f, Color.WHITE);' 'TextView title = text("Army Perf · build " + shortBuildId(), 16f, Color.WHITE);' 'perf_panel_title_shows_build_id'
  $perf=Replace-LiteralOne $perf 'toggleButton.setText(panelVisible ? "CERRAR" : "PERF");' 'toggleButton.setText((panelVisible ? "CERRAR" : "PERF") + "\n" + shortBuildId());' 'perf_toggle_keeps_build_id'
  $identityEvent=@'
recordGameEvent("AUTO_FLIGHT_RECORDER", "started_on_activity_attach");
        recordGameEvent("BUILD_IDENTITY", "tested_sha=" + testedSha + ";short_sha=" + shortBuildId() + ";render_mode=" + renderMode);
'@
  $perf=Replace-LiteralOne $perf 'recordGameEvent("AUTO_FLIGHT_RECORDER", "started_on_activity_attach");' $identityEvent.TrimEnd() 'runtime_build_identity_event'
  $helper=@'
    private String shortBuildId() {
        if (testedSha == null || testedSha.length() < 8) return "UNKNOWN";
        return testedSha.substring(0, 8);
    }

    private void readBuildMetadata() {
'@
  $perf=Replace-LiteralOne $perf '    private void readBuildMetadata() {' $helper.TrimEnd() 'short_build_id_helper'
  Write-Utf8Bom $perfPath $perf

  $test=Normalize-Lf ([IO.File]::ReadAllText($testPath))
  $old="Require-Contains `$perfOverlay 'toggleButton = button(`"PERF`"\);' 'perf_panel_toggle_is_stable'"
  if(-not $test.Contains($old)){
    $old="Require-Contains `$perfOverlay 'toggleButton = button(`"PERF`");' 'perf_panel_toggle_is_stable'"
  }
  $new=@'
Require-Contains $perfOverlay 'toggleButton = button("PERF\n" + shortBuildId());' 'perf_button_displays_build_id'
Require-Contains $perfOverlay 'TextView title = text("Army Perf · build " + shortBuildId()' 'perf_panel_displays_build_id'
Require-Contains $perfOverlay 'toggleButton.setText((panelVisible ? "CERRAR" : "PERF") + "\n" + shortBuildId());' 'perf_toggle_preserves_build_id'
Require-Contains $perfOverlay 'recordGameEvent("BUILD_IDENTITY", "tested_sha=" + testedSha + ";short_sha=" + shortBuildId()' 'perf_runtime_records_build_identity'
Require-Contains $perfOverlay 'return testedSha.substring(0, 8);' 'perf_build_identity_uses_manifest_tested_sha'
'@
  $test=Replace-LiteralOne $test $old $new.TrimEnd() 'runtime_test_visible_build_identity_contract'
  foreach($required in @('perf_button_displays_build_id','perf_panel_displays_build_id','perf_toggle_preserves_build_id','perf_runtime_records_build_identity','perf_build_identity_uses_manifest_tested_sha')){
    if(-not $test.Contains($required)){throw "ANDROID_EVIDENCE_ROOTFIX_V10=FAIL verification_missing=$required"}
  }
  if($test.Contains("'perf_panel_toggle_is_stable'")){throw 'ANDROID_EVIDENCE_ROOTFIX_V10=FAIL stale_perf_toggle_gate_remaining'}
  Write-Utf8Bom $testPath $test
  Write-Host 'REGRESSION_CHECK=PASS name=visible_build_identity_is_mandatory source=manifest_tested_sha display=PERF+panel runtime_event=BUILD_IDENTITY'
  Write-Host "REGRESSION_CHECK=PASS name=stale_apk_confusion_is_observable short_sha=$($ExpectedSha.Substring(0,8)) zip=device.json+game-events"
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V10=PASS mode=apply sha=$ExpectedSha schema=v10 predecessor=v9"
}catch{
  $failure=$_
  if(Test-Path -LiteralPath $testBackup -PathType Leaf){Copy-Item -LiteralPath $testBackup -Destination $testPath -Force}
  if(Test-Path -LiteralPath $perfBackup -PathType Leaf){Copy-Item -LiteralPath $perfBackup -Destination $perfPath -Force}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v9 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V10_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
