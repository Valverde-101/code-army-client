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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V50=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v49=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV49.ps1'
$v48=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV48.ps1'
if(-not(Test-Path -LiteralPath $v49 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V50=FAIL predecessor_missing=$v49"}
if(-not(Test-Path -LiteralPath $v48 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V50=FAIL v48_missing=$v48"}

function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
$original=[IO.File]::ReadAllBytes($v48)
try {
  $text=Normalize-Lf ([Text.Encoding]::UTF8.GetString($original))
  $old='visible = enemy.getContainer() && enemy.getContainer().visible;'
  $new='visible = enemy.getCell() && this.mScene.isInsideVisibleArea(enemy.getCell());'
  $count=([regex]::Matches($text,[regex]::Escape($old))).Count
  if($count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V50=FAIL viewport_anchor expected=1 actual=$count"}
  $text=$text.Replace($old,$new)
  $text=$text.Replace('visible_always_active=true','viewport_always_active=true')
  [IO.File]::WriteAllText($v48,$text,(New-Object System.Text.UTF8Encoding($true)))

  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($v48,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $errors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V50_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V50=FAIL patched_v48_parser_invalid'
  }
  Write-Host 'EVIDENCE_ROOTFIX_V50_COMPOSITION=PASS predecessor=v49 root=v48 activity_visibility=camera_viewport fog_visibility_rejected=true parser=true'
  & $v49 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V50=FAIL predecessor_exit=$LASTEXITCODE"}
  Write-Host "REGRESSION_CHECK=PASS name=enemy_ai_activity_visibility source=isInsideVisibleArea fog_of_war_independent=true viewport_always_active=true"
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V50=PASS mode=$Mode predecessor=v49 sha=$ExpectedSha viewport_activity=true"
}
finally {
  [IO.File]::WriteAllBytes($v48,$original)
}
