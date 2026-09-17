param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [Alias('Mode')][ValidateSet('Apply','Restore')][string]$RequestedMode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V49=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v48=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV48.ps1'
if(-not(Test-Path -LiteralPath $v48 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V49=FAIL predecessor_missing=$v48"}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}

# V48 adds requestPortableSaveShare(), which intentionally calls
# savePortableAndShare(). Its original strict one-token replacement therefore
# sees both the wrapper call and the legacy Button_save call. Replace only that
# patch instruction with a semantic Button_save method-scoped replacement.
$source=Normalize-Lf ([IO.File]::ReadAllText($v48))
$old=@'
  $hud=Replace-One $hud 'this.savePortableAndShare();' 'this.requestPortableSaveShare(param1);' 'manual_save_routes_through_guard'
'@.TrimEnd()
$new=@'
  $manualSavePattern='(?s)(public\s+function\s+buttonSavePressed\s*\(\s*param1\s*:\s*MouseEvent\s*\)\s*:\s*void\s*\{.*?CONFIG::BUILD_FOR_MOBILE_AIR\s*\{\s*)this\.savePortableAndShare\(\);'
  $manualSaveMatches=[regex]::Matches($hud,$manualSavePattern)
  if($manualSaveMatches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V48=FAIL patch=manual_save_routes_through_guard semantic_count=$($manualSaveMatches.Count)"}
  $hud=[regex]::Replace($hud,$manualSavePattern,'$1this.requestPortableSaveShare(param1);',1)
  Write-Host 'EVIDENCE_ROOTFIX_V48_HOOK=PASS name=manual_save_routes_through_guard matches=1 semantic=true'
'@.TrimEnd()
$count=([regex]::Matches($source,[regex]::Escape($old))).Count
if($count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V49=FAIL composition_anchor expected=1 actual=$count"}
$patched=$source.Replace($old,$new)
if($patched -notmatch 'manualSavePattern' -or $patched.Contains($old)){
  throw 'ANDROID_EVIDENCE_ROOTFIX_V49=FAIL semantic_patch_not_applied'
}

$temp=Join-Path $PSScriptRoot ('.Invoke-AndroidEvidenceRootFixOverlayV48-v49-'+[Guid]::NewGuid().ToString('N')+'.ps1')
try {
  [IO.File]::WriteAllText($temp,$patched,(New-Object System.Text.UTF8Encoding($true)))
  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V49_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V49=FAIL patched_v48_parser_invalid'
  }
  Write-Host 'EVIDENCE_ROOTFIX_V49_COMPOSITION=PASS predecessor=v48 patch=manual_save_method_scoped semantic=true parser=true'
  Write-Host "EVIDENCE_ROOTFIX_MODE_BINDING=PASS adapter=v49 requested=$RequestedMode internal_parameter=RequestedMode external_alias=Mode"
  & $temp -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $RequestedMode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V49=FAIL predecessor_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V49=PASS mode=$RequestedMode predecessor=v48 sha=$ExpectedSha save_button_semantic=true"
}
finally {
  if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
}
