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

# V21's external-import helper originally anchored on the bare token
# CONFIG::BUILD_FOR_AIR {. PauseDialog contains that token multiple times
# (imports, permission handler and file-selection handler), so the strict
# literal-one guard correctly failed before mutation. Compile a unique semantic
# anchor around the AIR onPermission method for this execution only.
$original=[IO.File]::ReadAllBytes($v21)
try {
  $text=[Text.Encoding]::UTF8.GetString($original)
  $old=@'
$pause=Replace-LiteralOne $pause 'CONFIG::BUILD_FOR_AIR {' $importHelper.TrimEnd() 'external_import_validate_persist'
'@.Trim()
  $new=@'
$importAnchor=@'
CONFIG::BUILD_FOR_AIR {
			public function onPermission(e: PermissionEvent): void {
'@.TrimEnd()
  $importReplacement=$importHelper.TrimEnd()+"`n`t`t`tpublic function onPermission(e: PermissionEvent): void {"
  $pause=Replace-LiteralOne $pause $importAnchor $importReplacement 'external_import_validate_persist'
'@.Trim()
  $count=([regex]::Matches($text,[regex]::Escape($old))).Count
  if($count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL v21_import_anchor expected=1 actual=$count"}
  $text=$text.Replace($old,$new)
  [IO.File]::WriteAllText($v21,$text,(New-Object System.Text.UTF8Encoding($true)))

  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($v21,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V22_PATCHED_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V22=FAIL patched_v21_parser_invalid'
  }
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V22_COMPAT=PASS root_cause=ambiguous_bare_config_anchor boundary=onPermission semantic=true parser=true'

  & $v21 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V22=FAIL predecessor_apply_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V22=PASS mode=apply predecessor=v21 sha=$ExpectedSha external_import_anchor=onPermission"
}
finally {
  [IO.File]::WriteAllBytes($v21,$original)
}
