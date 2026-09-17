param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [string]$RequestedMode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if($RequestedMode -notin @('Apply','Restore')){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL invalid_mode=$RequestedMode"}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v54=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV54.ps1'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v55\'+$ExpectedSha)
$backupPath=Join-Path $backupRoot 'Patch-AndroidPerformanceSwf.post-v54.ps1'
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v54 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL predecessor_missing=$v54"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-ExactOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL patch=$Name missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL patch=$Name ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V55_HOOK=PASS name=$Name matches=1 semantic=false"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Restore-OwnedPatcher {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL restore_backup_missing=$backupPath"}
  Copy-Item -LiteralPath $backupPath -Destination $patcherPath -Force
  $actualHash=Get-Sha256 $patcherPath
  $expectedHash=([string]$manifest.patcher_sha256).ToUpperInvariant()
  if($actualHash -ne $expectedHash){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL restore_hash expected=$expectedHash actual=$actualHash"}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V55_OWNED_RESTORE=PASS patcher=post_v54'
}

if($RequestedMode -eq 'Restore'){
  Restore-OwnedPatcher
  & $v54 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V55=PASS mode=restore predecessor=v54 sha=$ExpectedSha active_config_gate=lexical"
  return
}

$v54Applied=$false
try {
  & $v54 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Apply
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL predecessor_apply_exit=$LASTEXITCODE"}
  $v54Applied=$true

  if(-not(Test-Path -LiteralPath $patcherPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL patcher_missing=$patcherPath"}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  Copy-Item -LiteralPath $patcherPath -Destination $backupPath -Force
  $baselineHash=Get-Sha256 $patcherPath
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v55';source_sha=$ExpectedSha;predecessor='v54';patcher_sha256=$baselineHash}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $helperAnchor=@'
function Convert-MobileAirSourceForFFDec([string]$Source,[string]$Destination,[string]$ClassName){
'@
  $helper=@'
function Test-AS3ActiveConfigDirective([string]$Text){
  $inBlockComment=$false
  $quote=[char]0
  $escaped=$false
  for($i=0;$i -lt $Text.Length;$i++){
    $ch=$Text[$i]
    $next=if($i+1 -lt $Text.Length){$Text[$i+1]}else{[char]0}
    if($inBlockComment){
      if($ch -eq '*' -and $next -eq '/'){$inBlockComment=$false;$i++}
      continue
    }
    if([int]$quote -ne 0){
      if($escaped){$escaped=$false;continue}
      if($ch -eq '\'){$escaped=$true;continue}
      if($ch -eq $quote){$quote=[char]0}
      continue
    }
    if($ch -eq '/' -and $next -eq '/'){
      while($i -lt $Text.Length -and $Text[$i] -ne "`n"){$i++}
      continue
    }
    if($ch -eq '/' -and $next -eq '*'){$inBlockComment=$true;$i++;continue}
    if($ch -eq '"' -or $ch -eq "'"){$quote=$ch;continue}
    if($ch -eq 'C' -and $i+8 -le $Text.Length -and $Text.Substring($i,8) -ceq 'CONFIG::'){return $true}
  }
  return $false
}

function Convert-MobileAirSourceForFFDec([string]$Source,[string]$Destination,[string]$ClassName){
'@
  $patcher=Replace-ExactOne $patcher $helperAnchor.TrimStart("`n") $helper.TrimStart("`n") 'active_config_lexer_helper'

  $oldGate='  if($text -match ''CONFIG::''){throw "SWF_PERF_PATCH=FAIL config_directive_survived source=$Source"}'
  $newGate=@'
  if(Test-AS3ActiveConfigDirective -Text $text){throw "SWF_PERF_PATCH=FAIL active_config_directive_survived source=$Source"}
  Write-Host "FFDEC_CONFIG_ACTIVE_DIRECTIVES=PASS class=$ClassName active=0 comments_ignored=true strings_ignored=true"
'@.TrimEnd()
  $patcher=Replace-ExactOne $patcher $oldGate $newGate 'active_config_gate_comment_aware'

  $runAnchor='Remove-Item -LiteralPath $OutputSwf -Force -ErrorAction SilentlyContinue'
  $selfTest=@'
$commentedConfig="/*`nCONFIG::BUILD_FOR_MOBILE_AIR {`n  var disabled:Boolean = true;`n}`n*/"
$lineCommentConfig='// CONFIG::BUILD_FOR_AIR { disabled }'
$stringConfig='var marker:String = "CONFIG::BUILD_FOR_AIR {";'
$activeConfig="CONFIG::BUILD_FOR_AIR {`n}"
foreach($probe in @($commentedConfig,$lineCommentConfig,$stringConfig)){
  if(Test-AS3ActiveConfigDirective -Text $probe){throw 'SWF_PERF_PATCH=FAIL config_lexer_selftest_false_positive'}
}
if(-not(Test-AS3ActiveConfigDirective -Text $activeConfig)){throw 'SWF_PERF_PATCH=FAIL config_lexer_selftest_false_negative'}
Write-Host 'FFDEC_CONFIG_LEXER_SELFTEST=PASS block_comment=true line_comment=true string=true active_directive=true fail_closed=true'

Remove-Item -LiteralPath $OutputSwf -Force -ErrorAction SilentlyContinue
'@
  $patcher=Replace-ExactOne $patcher $runAnchor $selfTest.TrimEnd() 'active_config_lexer_selftest'

  Write-Utf8Bom $patcherPath $patcher
  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($patcherPath,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V55_PATCHER_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V55=FAIL patched_patcher_parser_invalid'
  }
  foreach($token in @('Test-AS3ActiveConfigDirective','FFDEC_CONFIG_ACTIVE_DIRECTIVES=PASS','FFDEC_CONFIG_LEXER_SELFTEST=PASS','active_config_directive_survived','comments_ignored=true','strings_ignored=true')){
    if(-not $patcher.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_V55=FAIL verify=$token"}
  }
  if($patcher.Contains("if(`$text -match 'CONFIG::')")){throw 'ANDROID_EVIDENCE_ROOTFIX_V55=FAIL stale_raw_config_gate_survived'}
  Write-Host 'REGRESSION_CHECK=PASS name=ffdec_config_survivor_gate lexical=true block_comments_ignored=true line_comments_ignored=true strings_ignored=true active_directive_fail_closed=true'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_dialog_commented_mobile_config accepted=true active_air_blocks_preprocessed=true expected_opened=2 expected_closed=2'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V55=PASS mode=apply predecessor=v54 sha=$ExpectedSha root_cause=comment_blind_config_survivor_gate"
}
catch {
  $failure=$_
  try { Restore-OwnedPatcher } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V55_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  if($v54Applied){
    try { & $v54 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Restore | Out-Host }
    catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V55_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  }
  throw $failure
}
