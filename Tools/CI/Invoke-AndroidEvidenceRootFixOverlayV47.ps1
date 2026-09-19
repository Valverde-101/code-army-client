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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V47=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v46=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV46.ps1'
if(-not(Test-Path -LiteralPath $v46 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V47=FAIL predecessor_missing=$v46"}

function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}

# V46's runtime changes are correct, but its patch-list insertion originally
# anchored to one serialized representation of the GameState patch-spec row.
# Earlier overlay composition can legitimately leave the same row with a
# different backslash representation. Build a temporary, parser-validated V46
# delegate whose insertion locates the GameState row semantically instead.
$source=Normalize-Lf ([IO.File]::ReadAllText($v46))
$startToken='    $gameStateSpec='
$endToken="'enemy_moving_swf_patch_spec'"
$start=$source.IndexOf($startToken,[StringComparison]::Ordinal)
if($start -lt 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V47=FAIL composition_start_missing'}
if($source.IndexOf($startToken,$start+$startToken.Length,[StringComparison]::Ordinal) -ge 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V47=FAIL composition_start_ambiguous'}
$endMarker=$source.IndexOf($endToken,$start,[StringComparison]::Ordinal)
if($endMarker -lt 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V47=FAIL composition_end_missing'}
if($source.IndexOf($endToken,$endMarker+$endToken.Length,[StringComparison]::Ordinal) -ge 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V47=FAIL composition_end_ambiguous'}
$end=$source.IndexOf("`n",$endMarker,[StringComparison]::Ordinal)
if($end -lt 0){$end=$source.Length}else{$end++}

$semanticBlock=@'
    $gameStatePattern="(?m)^(?<indent>\s*)\[ordered\]@\{Class='game\.states\.GameState';Source='(?<source>src[^']*GameState\.as)';Log='ffdec-feature-gamestate\.log'\},\s*$"
    $gameStateMatches=[regex]::Matches($patcher,$gameStatePattern)
    if($gameStateMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V46=FAIL patch=enemy_moving_swf_patch_spec semantic_game_state_count=$($gameStateMatches.Count)"}
    $gameStateMatch=$gameStateMatches[0]
    $moveSpec=$gameStateMatch.Groups['indent'].Value+"[ordered]@{Class='game.actions.EnemyMovingAction';Source='src\game\actions\EnemyMovingAction.as';Log='ffdec-feature-enemy-moving-failsafe.log'},"
    $insertAt=$gameStateMatch.Index+$gameStateMatch.Length
    $patcher=$patcher.Substring(0,$insertAt)+"`n"+$moveSpec+$patcher.Substring($insertAt)
    Write-Host 'EVIDENCE_ROOTFIX_V46_HOOK=PASS name=enemy_moving_swf_patch_spec matches=1 semantic=true'
'@
$patched=$source.Substring(0,$start)+(Normalize-Lf $semanticBlock)+$source.Substring($end)

if($patched -notmatch "semantic_game_state_count" -or $patched -notmatch "Class='game\.actions\.EnemyMovingAction'"){
  throw 'ANDROID_EVIDENCE_ROOTFIX_V47=FAIL semantic_patch_missing'
}
if($patched -match '\$gameStateSpec='){
  throw 'ANDROID_EVIDENCE_ROOTFIX_V47=FAIL brittle_anchor_survived'
}

$temp=Join-Path $PSScriptRoot ('.Invoke-AndroidEvidenceRootFixOverlayV46-v47-'+[Guid]::NewGuid().ToString('N')+'.ps1')
try {
  [IO.File]::WriteAllText($temp,$patched,(New-Object System.Text.UTF8Encoding($true)))
  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V47_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V47=FAIL patched_v46_parser_invalid'
  }
  Write-Host 'EVIDENCE_ROOTFIX_V47_COMPOSITION=PASS predecessor=v46 strategy=semantic_game_state_patchspec representation_independent=true parser=true'
  & $temp -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V47=FAIL predecessor_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V47=PASS mode=$Mode predecessor=v46 sha=$ExpectedSha semantic_patchspec=true"
}
finally {
  if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
}
