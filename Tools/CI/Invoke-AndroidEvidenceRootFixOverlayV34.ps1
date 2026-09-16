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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V34=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v33=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV33.ps1'
if(-not(Test-Path -LiteralPath $v33 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V34=FAIL predecessor_missing=$v33"}

# V33 originally anchored the FFDec patch-spec insertion on the complete GameHUD
# source-path line. PowerShell does not use backslash as an escape character, so
# the overescaped path in that runtime string could never match the actual patcher
# source. Repair V33 at execution time to use the stable `$patchSpecs=@(` block
# boundary instead of any class/path-specific line, then restore its exact bytes.
$original=[IO.File]::ReadAllBytes($v33)
try {
  $text=[Text.Encoding]::UTF8.GetString($original).Replace("`r`n","`n").Replace("`r","`n")

  $anchorPattern='(?m)^\s*\$patchAnchor=.*game\.gui\.GameHUD.*$'
  $anchorMatches=[regex]::Matches($text,$anchorPattern)
  if($anchorMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V34=FAIL repair=patch_anchor expected=1 actual=$($anchorMatches.Count)"}
  $anchorReplacement='  $patchAnchor=''$patchSpecs=@('''
  $text=[regex]::Replace($text,$anchorPattern,$anchorReplacement,1)

  $insertPattern="(?m)^\s*\`$patcher=Replace-LiteralOne\s+\`$patcher\s+\`$patchAnchor.*'patcher_v33_runtime_classes'\s*$"
  $insertMatches=[regex]::Matches($text,$insertPattern)
  if($insertMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V34=FAIL repair=patch_insertion expected=1 actual=$($insertMatches.Count)"}
  $insertReplacement=@'
  $patcher=Replace-LiteralOne $patcher $patchAnchor ($patchAnchor+"`n"+$extraSpecs) 'patcher_v33_runtime_classes'
'@.TrimEnd()
  $text=[regex]::Replace($text,$insertPattern,[System.Text.RegularExpressions.MatchEvaluator]{param($m) $insertReplacement},1)

  if(-not $text.Contains('$patchAnchor=''$patchSpecs=@(''')){throw 'ANDROID_EVIDENCE_ROOTFIX_V34=FAIL verify=structural_anchor_missing'}
  if(-not $text.Contains('($patchAnchor+"`n"+$extraSpecs)')){throw 'ANDROID_EVIDENCE_ROOTFIX_V34=FAIL verify=structural_insertion_missing'}

  [IO.File]::WriteAllText($v33,$text,(New-Object System.Text.UTF8Encoding($true)))
  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($v33,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V34_PATCHED_V33_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V34=FAIL patched_v33_parser_invalid'
  }

  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V34_REPAIR=PASS root_cause=overescaped_path_specific_patch_anchor strategy=patchspec_structural_anchor predecessor=v33 parser=true'
  & $v33 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V34=FAIL predecessor_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V34=PASS mode=$Mode predecessor=v33 sha=$ExpectedSha structural_anchor=true"
}
finally {
  [IO.File]::WriteAllBytes($v33,$original)
}
