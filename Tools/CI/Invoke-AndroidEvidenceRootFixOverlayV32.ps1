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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V32=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v31=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV31.ps1'
if(-not(Test-Path -LiteralPath $v31 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V32=FAIL predecessor_missing=$v31"}
$managerPath=Join-Path $RepoRoot 'src\game\missions\MissionManager.as'
if(-not(Test-Path -LiteralPath $managerPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V32=FAIL manager_missing=$managerPath"}

function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $i=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($i -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V32=FAIL patch=$Name literal_missing"}
  $j=$Text.IndexOf($Needle,$i+$Needle.Length,[StringComparison]::Ordinal)
  if($j -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V32=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V32_HOOK=PASS name=$Name matches=1 literal=true"
  return $Text.Substring(0,$i)+$Replacement+$Text.Substring($i+$Needle.Length)
}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V32=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V32_HOOK=PASS name=$Name matches=1 semantic=true"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Require-Token([string]$Text,[string]$Token,[string]$Name){
  if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V32=FAIL verify=$Name token=$Token"}
}

if($Mode -eq 'Restore'){
  & $v31 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V32=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V32=PASS mode=restore predecessor=v31 sha=$ExpectedSha"
  return
}

& $v31 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V32=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  $manager=Normalize-Lf ([IO.File]::ReadAllText($managerPath))

  # MissionManager was never compiled by the mobile SWF patcher before V31.
  # Its decompiled source contains constructor syntax accepted as text but rejected
  # by FFDec replaceAS3: `new Array;` -> PARENT_OPEN expected, SEMICOLON found.
  $manager=Replace-LiteralOne $manager 'smNodes = new Array;' 'smNodes = new Array();' 'mission_manager_array_constructor_parentheses'
  $manager=Replace-RegexOne $manager '(?m)^([ \t]*)return null[ \t]*$' '${1}return null;' 'mission_manager_explicit_null_return_semicolon'
  $manager=Replace-LiteralOne $manager 'return false // ducktape fix' 'return false; // legacy missing mission fallback' 'mission_manager_explicit_false_return_semicolon'

  # The unknown incomplete-mission branch used the previous finished-mission loop
  # variable. If there were no finished missions, dereferencing _loc7_ could itself
  # produce Error #1009 while trying to report the actual configuration problem.
  $manager=Replace-LiteralOne $manager 'Utils.LogError("Trying to setup unknown mission \"" + _loc7_.mission_id);' 'Utils.LogError("Trying to setup unknown mission \"" + _loc9_.mission_id);' 'mission_manager_unknown_incomplete_uses_current_record'

  # Excluded-mission tree construction previously retried the same failed lookup and
  # then unconditionally called getNodeForMission(null), whose param1.mId access can
  # raise Error #1009. Missing cross-map prerequisites are now observable and skipped.
  $treePattern='(?s)[ \t]*_loc1_\s*=\s*getMission\(_loc4_\.ID\);\s*if\(_loc1_\s*==\s*null\)\s*\{\s*getMission\(_loc4_\.ID\);\s*\}\s*_loc2_\.mParentNodes\.push\(getNodeForMission\(_loc1_\)\);'
  $treeReplacement=@'
               _loc1_ = getMission(_loc4_.ID);
               if(_loc1_ == null)
               {
                  Utils.DiagEvent("MISSION_TREE_MISSING_REQUIRED","mission=" + _loc2_.mMission.mId + ";required=" + _loc4_.ID + ";map=" + _loc2_.mMission.mMapId);
                  continue;
               }
               _loc3_ = getNodeForMission(_loc1_);
               if(_loc3_ != null)
               {
                  _loc2_.mParentNodes.push(_loc3_);
               }
'@.TrimEnd()
  $manager=Replace-RegexOne $manager $treePattern $treeReplacement 'mission_tree_null_parent_guard'

  $nodePattern='(?s)(private\s+static\s+function\s+getNodeForMission\(param1:Mission\)\s*:\s*MissionNode\s*\{\s*var\s+_loc2_:MissionNode\s*=\s*null;)'
  $nodeReplacement='$1'+"`n         if(param1 == null)`n         {`n            Utils.DiagEvent(`"MISSION_TREE_MISSING_REQUIRED`",`"result=SKIP_NULL_NODE`" );`n            return null;`n         }"
  $manager=Replace-RegexOne $manager $nodePattern $nodeReplacement 'mission_tree_get_node_null_guard'

  $badCtor=[regex]::Matches($manager,'\bnew\s+[A-Za-z_$][A-Za-z0-9_.$]*\s*;')
  if($badCtor.Count -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V32=FAIL manager_ffdec_constructor_syntax remaining=$($badCtor.Count)"}
  foreach($token in @(
    'smNodes = new Array();',
    'return null;',
    'return false; // legacy missing mission fallback',
    '_loc9_.mission_id);',
    'MISSION_TREE_MISSING_REQUIRED',
    'continue;',
    'if(param1 == null)'
  )){Require-Token $manager $token ('manager_'+$token)}

  Write-Utf8Bom $managerPath $manager
  Write-Host 'REGRESSION_CHECK=PASS name=mission_manager_ffdec_source_compat malformed_constructor=0 explicit_returns=true'
  Write-Host 'REGRESSION_CHECK=PASS name=mission_tree_missing_required_is_null_safe retry_removed=true null_parent_skipped=true telemetry=true'
  Write-Host 'REGRESSION_CHECK=PASS name=mission_incomplete_unknown_diagnostic_uses_current_record stale_loop_variable=false'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V32=PASS mode=apply predecessor=v31 sha=$ExpectedSha manager_ffdec_compat=true mission_tree_null_safe=true"
}
catch {
  $message=$_.Exception.Message
  try { & $v31 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Host }
  catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V32_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  throw $message
}
