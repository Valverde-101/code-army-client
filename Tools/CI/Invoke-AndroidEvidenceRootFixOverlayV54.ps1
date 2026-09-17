param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [string]$RequestedMode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if($RequestedMode -notin @('Apply','Restore')){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL invalid_mode=$RequestedMode"}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v53=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV53.ps1'
$testPath=Join-Path $RepoRoot 'Tools\CI\Test-AndroidRuntimePatch.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v54\'+$ExpectedSha)
$backupPath=Join-Path $backupRoot 'Test-AndroidRuntimePatch.post-v53.ps1'
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v53 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL predecessor_missing=$v53"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-ExactOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL patch=$Name missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL patch=$Name ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V54_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Restore-OwnedTest {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL restore_backup_missing=$backupPath"}
  Copy-Item -LiteralPath $backupPath -Destination $testPath -Force
  $actualHash=Get-Sha256 $testPath
  $expectedHash=([string]$manifest.test_sha256).ToUpperInvariant()
  if($actualHash -ne $expectedHash){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL restore_hash expected=$expectedHash actual=$actualHash"}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V54_OWNED_RESTORE=PASS test=post_v53'
}

if($RequestedMode -eq 'Restore'){
  Restore-OwnedTest
  & $v53 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V54=PASS mode=restore predecessor=v53 sha=$ExpectedSha regression_contract=structural_config_parser"
  return
}

$v53Applied=$false
try {
  & $v53 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Apply
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL predecessor_apply_exit=$LASTEXITCODE"}
  $v53Applied=$true

  if(-not(Test-Path -LiteralPath $testPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL test_missing=$testPath"}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  Copy-Item -LiteralPath $testPath -Destination $backupPath -Force
  $baselineHash=Get-Sha256 $testPath
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v54';source_sha=$ExpectedSha;predecessor='v53';test_sha256=$baselineHash}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $test=Normalize-Lf ([IO.File]::ReadAllText($testPath))
  $old="Require-Contains `$swfPatch '(?://.*)?\\z' 'ffdec_config_preprocessor_accepts_trailing_comments'"
  $new=@'
$configRegexMatch=[regex]::Match($swfPatch,'\$candidate=\[regex\]::Match\(\$line,''([^'']+)''\)')
if(-not $configRegexMatch.Success){throw 'REGRESSION=FAIL check=ffdec_config_preprocessor_regex_missing'}
$configRegex=$configRegexMatch.Groups[1].Value
foreach($sample in @('CONFIG::BUILD_FOR_MOBILE_AIR {','  CONFIG::BUILD_FOR_MOBILE_AIR { // trailing comment','CONFIG::BUILD_FOR_AIR { // donor branch')){
  if($sample -notmatch $configRegex){throw "REGRESSION=FAIL check=ffdec_config_preprocessor_accepts_trailing_comments sample=$sample pattern=$configRegex"}
}
Write-Host 'REGRESSION_CHECK=PASS name=ffdec_config_preprocessor_accepts_trailing_comments parser_regex_executed=true'
Require-Contains $swfPatch 'Get-AS3BraceDelta' 'ffdec_config_preprocessor_tracks_brace_depth'
Require-Contains $swfPatch 'FFDEC_CONFIG_BALANCE=PASS' 'ffdec_config_preprocessor_requires_balanced_blocks'
Require-Contains $swfPatch 'parser=brace_depth_stack' 'ffdec_config_preprocessor_structural_identity'
Require-Contains $swfPatch '$stack=New-Object System.Collections.ArrayList' 'ffdec_config_preprocessor_supports_nested_blocks'
Require-NotContains $swfPatch '$configIndent' 'ffdec_config_preprocessor_not_indent_sensitive'
'@.TrimEnd()
  $test=Replace-ExactOne $test $old $new 'migrate_ffdec_config_regression_contract'
  Write-Utf8Bom $testPath $test

  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($testPath,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V54_TEST_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V54=FAIL patched_test_parser_invalid'
  }
  foreach($token in @('configRegexMatch','parser_regex_executed=true','Get-AS3BraceDelta','FFDEC_CONFIG_BALANCE=PASS','ffdec_config_preprocessor_not_indent_sensitive')){
    if(-not $test.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_V54=FAIL verify=$token"}
  }
  Write-Host 'REGRESSION_CHECK=PASS name=ffdec_config_test_contract_migrated stale_literal_z_removed=true executable_regex_sample=true structural_markers=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V54=PASS mode=apply predecessor=v53 sha=$ExpectedSha root_cause=stale_static_regression_contract"
}
catch {
  $failure=$_
  try { Restore-OwnedTest } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V54_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  if($v53Applied){
    try { & $v53 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Restore | Out-Host }
    catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V54_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  }
  throw $failure
}
