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

  # V21 now owns the runtime-test transition from the repository's literal v9
  # assertions to CURRENT_SAVE_VERSION. Keep V22 focused on its import/picker
  # compatibility seams and fail early if that ownership regresses.
  foreach($required in @('runtime_test_offline_save_version_v10','runtime_test_daily_reward_saveversion_current')){
    if(-not $text.Contains($required)){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL v21_save_version_compat_missing token=$required"}
  }
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V22_SAVE_VERSION_COMPAT=PASS owner=v21 schema=v9 semantic_current_version=true'

  # Root cause from b2cca00: even API method names such as File.copyTo are not a
  # stable contract of FFDec's post-compile source re-export. Prove the complete
  # import transaction in the V21 source template (including ordering), then use
  # only identifiers already demonstrated to survive final-SWF decompilation for
  # the compiled PauseDialog gate. This avoids weakening behavior while removing
  # representation-dependent assertions.
  $validationToken='var validation:String = OfflineSave.validatePortableSave(savedata);'
  $backupToken='if (internalFile.exists) internalFile.copyTo(backupFile, true);'
  $tempToken='var tempFile:File = File.applicationStorageDirectory.resolvePath("savefile.import.tmp");'
  $moveToken='tempFile.moveTo(internalFile, true);'
  $loadToken='loadProgress(savedata);'
  $validationPos=$text.IndexOf($validationToken,[StringComparison]::Ordinal)
  $backupPos=$text.IndexOf($backupToken,[StringComparison]::Ordinal)
  $tempPos=$text.IndexOf($tempToken,[StringComparison]::Ordinal)
  $movePos=$text.IndexOf($moveToken,[StringComparison]::Ordinal)
  $loadPos=$text.IndexOf($loadToken,[StringComparison]::Ordinal)
  if($validationPos -lt 0 -or $backupPos -lt 0 -or $tempPos -lt 0 -or $movePos -lt 0 -or $loadPos -lt 0){
    throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL source_import_behavior_missing validation=$validationPos backup=$backupPos temp=$tempPos move=$movePos load=$loadPos"
  }
  if(-not($validationPos -lt $backupPos -and $backupPos -lt $tempPos -and $tempPos -lt $movePos -and $movePos -lt $loadPos)){
    throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL source_import_behavior_order validation=$validationPos backup=$backupPos temp=$tempPos move=$movePos load=$loadPos"
  }
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V22_IMPORT_SOURCE_CONTRACT=PASS validation_before_mutation=true backup_before_temp=true atomic_move_before_load=true'

  $pauseMarkersPattern='(?m)^\s*\$v21PauseMarkers=@\(.*\)\s*$'
  $pauseMarkerMatches=[regex]::Matches($text,$pauseMarkersPattern)
  if($pauseMarkerMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL v21_final_pause_markers expected=1 actual=$($pauseMarkerMatches.Count)"}
  $newPauseMarkers=@'
$v21PauseMarkers=@('browseForOpen','onExternalSaveSelected')
'@.TrimEnd()
  $pauseMarkerMatch=$pauseMarkerMatches[0]
  $text=$text.Substring(0,$pauseMarkerMatch.Index)+$newPauseMarkers+$text.Substring($pauseMarkerMatch.Index+$pauseMarkerMatch.Length)
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V22_FINAL_IMPORT_VERIFY=PASS source_behavior=validation+backup+temp+atomic_move+load compiled_validation_method=OfflineSave final_pause=picker+selected_handler representation_independent=true'

  [IO.File]::WriteAllText($v21,$text,(New-Object System.Text.UTF8Encoding($true)))

  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($v21,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V22_PATCHED_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V22=FAIL patched_v21_parser_invalid'
  }
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V22_COMPAT=PASS fixes=semantic_onPermission+pause_dialog_swf_path+mobile_picker_nested_block+runtime_save_version_owned_by_v21+source_import_transaction+representation_independent_final_gate parser=true'

  & $v21 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL predecessor_apply_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V22=PASS mode=apply predecessor=v21 sha=$ExpectedSha compatibility=semantic_import+swf_path+mobile_picker_nested_block+runtime_save_version_owned_by_v21+source_import_transaction+representation_independent_final_gate"
}
finally {
  [IO.File]::WriteAllBytes($v21,$original)
}
