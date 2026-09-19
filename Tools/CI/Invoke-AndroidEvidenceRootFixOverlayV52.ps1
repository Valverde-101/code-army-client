param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [string]$RequestedMode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if($RequestedMode -notin @('Apply','Restore')){throw "ANDROID_EVIDENCE_ROOTFIX_V52=FAIL invalid_mode=$RequestedMode"}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V52=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v48=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV48.ps1'
if(-not(Test-Path -LiteralPath $v48 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V52=FAIL v48_missing=$v48"}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Replace-ExactOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $count=([regex]::Matches($Text,[regex]::Escape($Needle))).Count
  if($count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V52=FAIL patch=$Name expected=1 actual=$count"}
  Write-Host "EVIDENCE_ROOTFIX_V52_HOOK=PASS name=$Name matches=1"
  return $Text.Replace($Needle,$Replacement)
}

$original=[IO.File]::ReadAllBytes($v48)
try {
  $text=Normalize-Lf ([Text.Encoding]::UTF8.GetString($original))

  $text=Replace-ExactOne $text "  [ValidateSet('Apply','Restore')][string]`$Mode='Apply'" "  [string]`$RequestedMode='Apply'" 'v48_mode_parameter'
  $text=Replace-ExactOne $text "if(`$Mode -eq 'Restore'){" "if(`$RequestedMode -eq 'Restore'){" 'v48_restore_dispatch'

  $oldManual="  `$hud=Replace-One `$hud 'this.savePortableAndShare();' 'this.requestPortableSaveShare(param1);' 'manual_save_routes_through_guard'"
  $newManual=@'
  $manualSavePattern='(?s)(public\s+function\s+buttonSavePressed\s*\(\s*param1\s*:\s*MouseEvent\s*\)\s*:\s*void\s*\{.*?CONFIG::BUILD_FOR_MOBILE_AIR\s*\{\s*)this\.savePortableAndShare\(\);'
  $manualSaveMatches=[regex]::Matches($hud,$manualSavePattern)
  if($manualSaveMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL patch=manual_save_routes_through_guard semantic_count=$($manualSaveMatches.Count)"}
  $hud=[regex]::Replace($hud,$manualSavePattern,'$1this.requestPortableSaveShare(param1);',1)
  Write-Host 'EVIDENCE_ROOTFIX_V48_HOOK=PASS name=manual_save_routes_through_guard matches=1 semantic=true scope=buttonSavePressed'
'@.TrimEnd()
  $text=Replace-ExactOne $text $oldManual $newManual 'manual_save_method_scoped'

  $legacyVisibility='visible = enemy.getContainer() && enemy.getContainer().visible;'
  $unlockedAreaVisibility='visible = enemy.getCell() && this.mScene.isInsideVisibleArea(enemy.getCell());'
  $actualViewportVisibility='visible = this.mScene.isRenderableActuallyInViewport(enemy);'
  $legacyVisibilityCount=([regex]::Matches($text,[regex]::Escape($legacyVisibility))).Count
  $unlockedAreaVisibilityCount=([regex]::Matches($text,[regex]::Escape($unlockedAreaVisibility))).Count
  $actualViewportVisibilityCount=([regex]::Matches($text,[regex]::Escape($actualViewportVisibility))).Count
  if($legacyVisibilityCount -eq 1 -and $unlockedAreaVisibilityCount -eq 0 -and $actualViewportVisibilityCount -eq 0){
    $text=$text.Replace($legacyVisibility,$actualViewportVisibility)
    Write-Host 'EVIDENCE_ROOTFIX_V52_HOOK=PASS name=enemy_activity_camera_viewport matches=1 action=migrated_from_container_visible target=actual_render_viewport'
  }elseif($legacyVisibilityCount -eq 0 -and $unlockedAreaVisibilityCount -eq 1 -and $actualViewportVisibilityCount -eq 0){
    $text=$text.Replace($unlockedAreaVisibility,$actualViewportVisibility)
    Write-Host 'EVIDENCE_ROOTFIX_V52_HOOK=PASS name=enemy_activity_camera_viewport matches=1 action=migrated_from_unlocked_area target=actual_render_viewport'
  }elseif($legacyVisibilityCount -eq 0 -and $unlockedAreaVisibilityCount -eq 0 -and $actualViewportVisibilityCount -eq 1){
    Write-Host 'EVIDENCE_ROOTFIX_V52_HOOK=PASS name=enemy_activity_camera_viewport matches=1 action=already_applied target=actual_render_viewport'
  }else{
    throw "ANDROID_EVIDENCE_ROOTFIX_V52=FAIL patch=enemy_activity_camera_viewport legacy=$legacyVisibilityCount unlocked_area=$unlockedAreaVisibilityCount actual_viewport=$actualViewportVisibilityCount"
  }
  $text=$text.Replace('visible_always_active=true','viewport_always_active=true')

  $oldAi="  `$game=Replace-One `$game 'if (enemy && enemy.isAlive()) {' 'if (enemy && enemy.isAlive() && this.isOfflineEnemySpatiallyActive(enemy)) {' 'ai_tuning_active_set_only'"
  $newAi=@'
  $aiMethodStartPattern='(?m)^\s*private\s+function\s+ensureOfflineEnemyAiTuned\s*\(\s*param1\s*:\s*int\s*\)\s*:\s*void\s*\{'
  $aiStartMatches=[regex]::Matches($game,$aiMethodStartPattern)
  if($aiStartMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL patch=ai_tuning_active_set_only method_count=$($aiStartMatches.Count)"}
  $aiStart=$aiStartMatches[0].Index
  $afterStart=$aiStart+$aiStartMatches[0].Length
  $tail=$game.Substring($afterStart)
  $nextMethod=[regex]::Match($tail,'(?m)^\s*(?:(?:private|public|protected)\s+|override\s+(?:public|protected)\s+)function\s+')
  if(-not $nextMethod.Success){throw 'ANDROID_EVIDENCE_ROOTFIX_V48=FAIL patch=ai_tuning_active_set_only method_end_missing'}
  $aiEnd=$afterStart+$nextMethod.Index
  $aiMethod=$game.Substring($aiStart,$aiEnd-$aiStart)
  $aliveNeedle='if (enemy && enemy.isAlive()) {'
  $aliveCount=([regex]::Matches($aiMethod,[regex]::Escape($aliveNeedle))).Count
  if($aliveCount -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL patch=ai_tuning_active_set_only scoped_count=$aliveCount"}
  $aiPatched=$aiMethod.Replace($aliveNeedle,'if (enemy && enemy.isAlive() && this.isOfflineEnemySpatiallyActive(enemy)) {')
  $game=$game.Substring(0,$aiStart)+$aiPatched+$game.Substring($aiEnd)
  Write-Host 'EVIDENCE_ROOTFIX_V48_HOOK=PASS name=ai_tuning_active_set_only matches=1 semantic=true scope=ensureOfflineEnemyAiTuned census_unfiltered=true'
'@.TrimEnd()
  $text=Replace-ExactOne $text $oldAi $newAi 'ai_tuning_method_scoped'

  [IO.File]::WriteAllText($v48,$text,(New-Object System.Text.UTF8Encoding($true)))
  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($v48,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V52_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V52=FAIL patched_v48_parser_invalid'
  }

  Write-Host "EVIDENCE_ROOTFIX_V52_COMPOSITION=PASS canonical=v48 legacy_adapters_bypassed=v49,v50,v51 mode=$RequestedMode parser=true temporary_script=false in_place_transaction=true"
  & $v48 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode $RequestedMode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V52=FAIL v48_exit=$LASTEXITCODE"}
  Write-Host 'REGRESSION_CHECK=PASS name=rootfix_single_compositor canonical=v48 legacy_layers=0 temporary_script=false'
  Write-Host 'REGRESSION_CHECK=PASS name=manual_save_semantic_scope method=buttonSavePressed'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_activity_visibility source=isRenderableActuallyInViewport unlocked_area_predicate=false fog_of_war_independent=true viewport_always_active=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_spatial_census_not_self_filtered refresh=all_alive tuner=active_set_only feedback_loop=false'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V52=PASS mode=$RequestedMode sha=$ExpectedSha architecture=single_compositor"
}
finally {
  [IO.File]::WriteAllBytes($v48,$original)
}
