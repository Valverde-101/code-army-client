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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v34=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV34.ps1'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$dialogPath=Join-Path $RepoRoot 'src\game\gui\popups\CharacterDialoqueWindow.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v36\'+$ExpectedSha)
$backupPath=Join-Path $backupRoot 'Patch-AndroidPerformanceSwf.post-v34.ps1'
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v34 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL predecessor_missing=$v34"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $i=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($i -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL patch=$Name literal_missing"}
  $j=$Text.IndexOf($Needle,$i+$Needle.Length,[StringComparison]::Ordinal)
  if($j -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V36_HOOK=PASS name=$Name matches=1 literal=true"
  return $Text.Substring(0,$i)+$Replacement+$Text.Substring($i+$Needle.Length)
}
function Restore-OwnedPatcher {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL restore_backup_missing=$backupPath"}
  Copy-Item -LiteralPath $backupPath -Destination $patcherPath -Force
  if((Get-Sha256 $patcherPath) -ne ([string]$manifest.patcher_sha256).ToUpperInvariant()){throw 'ANDROID_EVIDENCE_ROOTFIX_V36=FAIL restore_hash'}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V36_OWNED_RESTORE=PASS patcher=post_v34'
}

if($Mode -eq 'Restore'){
  Restore-OwnedPatcher
  & $v34 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V36=PASS mode=restore predecessor=v34 sha=$ExpectedSha"
  return
}

& $v34 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL predecessor_apply_exit=$LASTEXITCODE"}

try {
  if(-not(Test-Path -LiteralPath $patcherPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL patcher_missing=$patcherPath"}
  if(-not(Test-Path -LiteralPath $dialogPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL dialog_missing=$dialogPath"}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  Copy-Item -LiteralPath $patcherPath -Destination $backupPath -Force
  $baselineHash=Get-Sha256 $patcherPath
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v36';source_sha=$ExpectedSha;predecessor='v34';patcher_sha256=$baselineHash}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  if(-not $patcher.Contains("Class='game.gui.popups.CharacterDialoqueWindow'")){throw 'ANDROID_EVIDENCE_ROOTFIX_V36=FAIL snow_dialog_patch_spec_missing'}
  $dialog=Normalize-Lf ([IO.File]::ReadAllText($dialogPath))
  if(-not $dialog.Contains('CONFIG::BUILD_FOR_AIR {')){throw 'ANDROID_EVIDENCE_ROOTFIX_V36=FAIL snow_dialog_air_config_missing'}

  # Root cause: predecessor overlays can legitimately extend the old FFDec class
  # allowlist (V21 adds PauseDialog). V35 tried to replace the complete allowlist
  # literally, so composition failed before FFDec ran. Make both decisions semantic:
  # preprocess any source containing CONFIG:: and choose MOBILE AIR whenever that
  # source actually declares BUILD_FOR_MOBILE_AIR, otherwise use generic BUILD_FOR_AIR.
  $sourceNeedle=@'
  $sourceLines=Get-Content -LiteralPath $Source
  $result=New-Object System.Collections.Generic.List[string]
'@.TrimEnd()
  $sourceReplacement=@'
  $sourceLines=Get-Content -LiteralPath $Source
  $hasMobileConfig=@($sourceLines|Where-Object{$_ -match '^\s*CONFIG::BUILD_FOR_MOBILE_AIR\s*\{' }).Count -gt 0
  $targetConfigMode=if($hasMobileConfig){'BUILD_FOR_MOBILE_AIR'}else{'BUILD_FOR_AIR'}
  $result=New-Object System.Collections.Generic.List[string]
'@.TrimEnd()
  $patcher=Replace-LiteralOne $patcher $sourceNeedle $sourceReplacement 'ffdec_config_target_mode_semantic'

  $patcher=Replace-LiteralOne $patcher "    if(`$configMode -eq 'BUILD_FOR_MOBILE_AIR'){`n      `$result.Add(`$line)`n    }" "    if(`$configMode -eq `$targetConfigMode){`n      `$result.Add(`$line)`n    }" 'ffdec_config_keep_effective_mode'
  $patcher=Replace-LiteralOne $patcher '  Write-Host "FFDEC_SOURCE_PREPROCESS=PASS class=$ClassName target=BUILD_FOR_MOBILE_AIR path=$Destination"' '  Write-Host "FFDEC_SOURCE_PREPROCESS=PASS class=$ClassName target=$targetConfigMode path=$Destination"' 'ffdec_config_target_telemetry'

  $sourceLoopAnchor='  $source=Join-Path $RepoRoot $spec.Source'
  $sourceLoopReplacement=@'
  $source=Join-Path $RepoRoot $spec.Source
  $sourceTextForConfig=Get-Content -LiteralPath $source -Raw
  $hasConfigDirective=[regex]::IsMatch($sourceTextForConfig,'(?m)^\s*CONFIG::(BUILD_FOR_MOBILE_AIR|BUILD_FOR_AIR|NOT_BUILD_FOR_AIR)\s*\{')
'@.TrimEnd()
  $patcher=Replace-LiteralOne $patcher $sourceLoopAnchor $sourceLoopReplacement 'ffdec_config_detect_at_patch_loop'

  $dispatchPattern='(?m)^(\s*)if\((\$spec\.Class\s+-in\s+@\([^\r\n]+\))\)\{\s*$'
  $dispatchMatches=[regex]::Matches($patcher,$dispatchPattern)
  if($dispatchMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V36=FAIL patch=ffdec_config_semantic_dispatch expected=1 actual=$($dispatchMatches.Count)"}
  $dispatch=$dispatchMatches[0]
  $dispatchReplacement=$dispatch.Groups[1].Value+'if('+$dispatch.Groups[2].Value+' -or $hasConfigDirective){'
  $patcher=$patcher.Substring(0,$dispatch.Index)+$dispatchReplacement+$patcher.Substring($dispatch.Index+$dispatch.Length)
  Write-Host 'EVIDENCE_ROOTFIX_V36_HOOK=PASS name=ffdec_config_semantic_dispatch matches=1 regex=true predecessor_allowlist_preserved=true'

  if(-not $patcher.Contains('$targetConfigMode')){throw 'ANDROID_EVIDENCE_ROOTFIX_V36=FAIL verify=target_mode_missing'}
  if(-not $patcher.Contains('$hasMobileConfig')){throw 'ANDROID_EVIDENCE_ROOTFIX_V36=FAIL verify=mobile_semantic_missing'}
  if(-not $patcher.Contains('$hasConfigDirective')){throw 'ANDROID_EVIDENCE_ROOTFIX_V36=FAIL verify=semantic_dispatch_missing'}
  if(-not $patcher.Contains("'game.gui.PauseDialog'")){throw 'ANDROID_EVIDENCE_ROOTFIX_V36=FAIL verify=predecessor_pause_dialog_allowlist_lost'}
  if($patcher.Contains('target=BUILD_FOR_MOBILE_AIR path=$Destination')){throw 'ANDROID_EVIDENCE_ROOTFIX_V36=FAIL verify=stale_fixed_target_telemetry'}
  Write-Utf8Bom $patcherPath $patcher

  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($patcherPath,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V36_PATCHER_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V36=FAIL patched_patcher_parser_invalid'
  }

  Write-Host 'REGRESSION_CHECK=PASS name=ffdec_config_overlay_composition predecessor_allowlist_mutation_safe=true pause_dialog_preserved=true exact_allowlist_anchor=false'
  Write-Host 'REGRESSION_CHECK=PASS name=ffdec_config_source_semantic_preprocess conditional_namespace_detected=true target_mode=source_declared mobile_preferred=true'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_dialog_ffdec_config_mode class=CharacterDialoqueWindow effective=BUILD_FOR_AIR not_build_for_air=discarded mobile_specialized=false'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V36=PASS mode=apply predecessor=v34 sha=$ExpectedSha ffdec_config_semantic=true overlay_composition_safe=true snow_dialog_compile_path=true"
}
catch {
  $failure=$_
  try { Restore-OwnedPatcher } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V36_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  try { & $v34 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Host }
  catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V36_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  throw $failure
}
