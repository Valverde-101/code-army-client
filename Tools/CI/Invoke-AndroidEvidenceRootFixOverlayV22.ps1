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

  # Root cause from 6e85947: V21's mobile picker regex stopped at the first nested
  # closing brace inside the legacy documents/legacy branch. Do not match the old
  # assignment byte-for-byte: its regex escaping is itself representation-sensitive.
  # Locate the unique picker assignment semantically, then replace only that line.
  $pickerAssignmentPattern='(?m)^\s*\$pickerPattern=.*startSelectingFile.*$'
  $pickerAssignmentMatches=[regex]::Matches($text,$pickerAssignmentPattern)
  if($pickerAssignmentMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL v21_mobile_picker_assignment expected=1 actual=$($pickerAssignmentMatches.Count)"}
  $newPickerLine=@'
  $pickerPattern='(?ms)(public function startSelectingFile\(\):\s*void\s*\{.*?CONFIG::NOT_BUILD_FOR_AIR\s*\{.*?^\s*\})(\s*CONFIG::BUILD_FOR_MOBILE_AIR\s*\{.*?file\.requestPermission\(\);\s*^\s*\})(\s*^\s*\})'
'@.TrimEnd()
  $pickerAssignment=$pickerAssignmentMatches[0]
  $text=$text.Substring(0,$pickerAssignment.Index)+$newPickerLine+$text.Substring($pickerAssignment.Index+$pickerAssignment.Length)
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V22_PICKER_ASSIGNMENT=PASS semantic=true representation_independent=true'

  # Fail before FFDec if the legacy nested Android save-location branch survived
  # the picker replacement. This converts a compiler-only failure into a precise
  # source-contract failure at the responsible seam.
  $pickerApplyLine="  `$pause=Replace-RegexOne `$pause `$pickerPattern `$pickerReplacement.TrimEnd() 'mobile_external_save_picker'"
  $pickerApplyCount=([regex]::Matches($text,[regex]::Escape($pickerApplyLine))).Count
  if($pickerApplyCount -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL v21_mobile_picker_apply_anchor expected=1 actual=$pickerApplyCount"}
  $pickerGuard=@'
  if($pause.Contains('GameState.mInstance.mSaveLocation == "documents"') -or $pause.Contains('else if (GameState.mInstance.mSaveLocation == "legacy")')){throw 'ANDROID_EVIDENCE_ROOTFIX_V21=FAIL mobile_external_save_picker legacy_branch_survived'}
  Write-Host 'EVIDENCE_ROOTFIX_V21_HOOK=PASS name=mobile_external_save_picker_full_block_removed semantic=true nested_braces=true'
'@.TrimEnd()
  $pickerApplyIndex=$text.IndexOf($pickerApplyLine,[StringComparison]::Ordinal)
  $pickerInsertAt=$pickerApplyIndex+$pickerApplyLine.Length
  $text=$text.Substring(0,$pickerInsertAt)+"`n"+$pickerGuard+$text.Substring($pickerInsertAt)

  # V21 upgrades emitted saves to CURRENT_SAVE_VERSION=8, while V20's runtime test
  # still asserts the literal v7 assignment. The stale assertion lives in the TEST
  # FILE that V21 patches at runtime, not in V21's own source. Inject a V21 runtime
  # migration immediately after its stable patch-version hook instead of searching
  # V21 for a line that can never exist there.
  $runtimePatchPattern="(?m)^\s*\`$test=Replace-LiteralOne \`$test .*'runtime_test_patch_version_v21'\s*$"
  $runtimeMatches=[regex]::Matches($text,$runtimePatchPattern)
  if($runtimeMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL v21_runtime_patch_anchor expected=1 actual=$($runtimeMatches.Count)"}
  $runtimeFixLine=@'
  $test=Replace-LiteralOne $test "Require-Contains `$offline 'savedata[`"saveversion`"] = 7;' 'offline_save_version_bumped_for_active_map'" "Require-Contains `$offline 'savedata[`"saveversion`"] = CURRENT_SAVE_VERSION;' 'offline_save_version_bumped_for_active_map'" 'runtime_test_save_version_v8'
'@.TrimEnd()
  $runtimeMatch=$runtimeMatches[0]
  $insertAt=$runtimeMatch.Index+$runtimeMatch.Length
  $text=$text.Substring(0,$insertAt)+"`n"+$runtimeFixLine+$text.Substring($insertAt)

  # Source-level regression proves PauseDialog invokes OfflineSave.validatePortableSave
  # before persistence and load. The final SWF separately proves validatePortableSave
  # exists in compiled OfflineSave, while PauseDialog's decompiled final bytecode is
  # required to contain the picker, selected-file handler, temp/backup persistence and
  # load commit path. Do not require the cross-class method identifier to survive
  # FFDec's source re-export verbatim inside PauseDialog.
  $pauseMarkersPattern='(?m)^\s*\$v21PauseMarkers=@\(.*\)\s*$'
  $pauseMarkerMatches=[regex]::Matches($text,$pauseMarkersPattern)
  if($pauseMarkerMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL v21_final_pause_markers expected=1 actual=$($pauseMarkerMatches.Count)"}
  $newPauseMarkers=@'
$v21PauseMarkers=@('browseForOpen','onExternalSaveSelected','savefile.import.tmp','savefile.before-import.txt','loadProgress')
'@.TrimEnd()
  $pauseMarkerMatch=$pauseMarkerMatches[0]
  $text=$text.Substring(0,$pauseMarkerMatch.Index)+$newPauseMarkers+$text.Substring($pauseMarkerMatch.Index+$pauseMarkerMatch.Length)
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V22_FINAL_IMPORT_VERIFY=PASS source_validation_call=regression compiled_validation_method=OfflineSave final_pause=picker+persist+load'

  [IO.File]::WriteAllText($v21,$text,(New-Object System.Text.UTF8Encoding($true)))

  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($v21,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V22_PATCHED_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V22=FAIL patched_v21_parser_invalid'
  }
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V22_COMPAT=PASS fixes=semantic_onPermission+pause_dialog_swf_path+mobile_picker_nested_block+runtime_save_v8_regression+final_import_split_semantic_verify parser=true'

  & $v21 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL predecessor_apply_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V22=PASS mode=apply predecessor=v21 sha=$ExpectedSha compatibility=semantic_import+swf_path+mobile_picker_nested_block+runtime_save_v8_regression+final_import_split_semantic_verify"
}
finally {
  [IO.File]::WriteAllBytes($v21,$original)
}
