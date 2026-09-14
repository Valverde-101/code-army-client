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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v21=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV21.ps1'
if(-not(Test-Path -LiteralPath $v21 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL predecessor_missing=$v21"}

$tokens=$null
$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($v21,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0){
  $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V22_PREDECESSOR_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
  throw 'ANDROID_EVIDENCE_ROOTFIX_V22=FAIL predecessor_parser_invalid'
}

if($Mode -eq 'Restore'){
  & $v21 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V22=PASS mode=restore predecessor=v21 sha=$ExpectedSha"
  return
}

$original=[IO.File]::ReadAllBytes($v21)
try {
  $text=[IO.File]::ReadAllText($v21)

  # V21 originally anchored its imported-save helper to a generic AIR CONFIG block.
  # Compile the unique onPermission seam for this execution only.
  $oldLine="  `$pause=Replace-LiteralOne `$pause 'CONFIG::BUILD_FOR_AIR {' `$importHelper.TrimEnd() 'external_import_validate_persist'"
  $sq=[char]39
  $pattern='(?ms)CONFIG::BUILD_FOR_AIR\s*\{\s*public function onPermission\(e:\s*PermissionEvent\):\s*void\s*\{'
  $newLine='  $pause=Replace-RegexOne $pause '+$sq+$pattern+$sq+' ($importHelper.TrimEnd()+"`n`t`t`tpublic function onPermission(e: PermissionEvent): void {") '+$sq+'external_import_validate_persist'+$sq
  $count=([regex]::Matches($text,[regex]::Escape($oldLine))).Count
  if($count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL v21_import_anchor_line expected=1 actual=$count"}
  $text=$text.Replace($oldLine,$newLine)

  # PowerShell does not treat backslash as a string escape. Normalize exactly the
  # over-escaped V21 GameHUD patch-spec needle to the real repository path.
  $oldPauseSpec="Source='src\\game\\gui\\GameHUD.as'"
  $newPauseSpec="Source='src\game\gui\GameHUD.as'"
  $pauseSpecCount=([regex]::Matches($text,[regex]::Escape($oldPauseSpec))).Count
  if($pauseSpecCount -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL v21_pause_dialog_swf_spec expected=1 actual=$pauseSpecCount"}
  $text=$text.Replace($oldPauseSpec,$newPauseSpec)

  # V21 upgrades emitted saves to CURRENT_SAVE_VERSION=8. Its predecessor test still
  # asserted the removed literal v7 assignment. Use single-quoted PowerShell strings
  # with doubled inner quotes so this compatibility edit is parser-safe and exact.
  $oldSaveAssertion='Require-Contains $offline ''savedata["saveversion"] = 7;'' ''offline_save_version_bumped_for_active_map'''
  $newSaveAssertion='Require-Contains $offline ''savedata["saveversion"] = CURRENT_SAVE_VERSION;'' ''offline_save_version_bumped_for_active_map'''
  $saveAssertionCount=([regex]::Matches($text,[regex]::Escape($oldSaveAssertion))).Count
  if($saveAssertionCount -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL v21_stale_save_version_regression expected=1 actual=$saveAssertionCount"}
  $text=$text.Replace($oldSaveAssertion,$newSaveAssertion)

  [IO.File]::WriteAllText($v21,$text,(New-Object System.Text.UTF8Encoding($true)))

  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($v21,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V22_PATCHED_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V22=FAIL patched_v21_parser_invalid'
  }
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V22_COMPAT=PASS fixes=semantic_onPermission+pause_dialog_swf_path+save_v8_regression parser=true'

  & $v21 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL predecessor_apply_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V22=PASS mode=apply predecessor=v21 sha=$ExpectedSha compatibility=semantic_import+swf_path+save_v8_regression"
}
finally {
  [IO.File]::WriteAllBytes($v21,$original)
}
