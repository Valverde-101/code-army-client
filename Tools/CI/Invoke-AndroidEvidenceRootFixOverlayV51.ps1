param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$RequestedMode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V51=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v50=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV50.ps1'
$v48=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV48.ps1'
if(-not(Test-Path -LiteralPath $v50 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V51=FAIL predecessor_missing=$v50"}
if(-not(Test-Path -LiteralPath $v48 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V51=FAIL v48_missing=$v48"}

function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}

# V48 legitimately introduces a second `if (enemy && enemy.isAlive())` in
# refreshOfflineEnemySpatialSet(). The global Replace-One that follows must not
# guess between that census loop and ensureOfflineEnemyAiTuned(): the census
# must inspect every alive enemy, while only the tuner is allowed to filter to
# the current spatial working set. Replace that one global patch instruction
# with a method-scoped semantic rewrite.
$original=[IO.File]::ReadAllBytes($v48)
try {
  $text=Normalize-Lf ([Text.Encoding]::UTF8.GetString($original))
  $old=@'
  $game=Replace-One $game 'if (enemy && enemy.isAlive()) {' 'if (enemy && enemy.isAlive() && this.isOfflineEnemySpatiallyActive(enemy)) {' 'ai_tuning_active_set_only'
'@.TrimEnd()
  $new=@'
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
  $count=([regex]::Matches($text,[regex]::Escape($old))).Count
  if($count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V51=FAIL composition_anchor expected=1 actual=$count"}
  $text=$text.Replace($old,$new)
  [IO.File]::WriteAllText($v48,$text,(New-Object System.Text.UTF8Encoding($true)))

  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($v48,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V51_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V51=FAIL patched_v48_parser_invalid'
  }
  Write-Host 'EVIDENCE_ROOTFIX_V51_COMPOSITION=PASS predecessor=v50 root=v48 patch=ai_tuning_method_scoped census=all_alive tuner=spatial_active parser=true'
  Write-Host "EVIDENCE_ROOTFIX_MODE_BINDING=PASS adapter=v51 requested=$RequestedMode parameter=RequestedMode alias=none"

  & $v50 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode $RequestedMode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V51=FAIL predecessor_exit=$LASTEXITCODE"}

  Write-Host 'REGRESSION_CHECK=PASS name=enemy_spatial_census_not_self_filtered refresh=all_alive tuner=active_set_only feedback_loop=false'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V51=PASS mode=$RequestedMode predecessor=v50 sha=$ExpectedSha ai_tuning_scope=semantic"
}
finally {
  [IO.File]::WriteAllBytes($v48,$original)
}
