param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$impl=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV2.ps1'
if(-not(Test-Path -LiteralPath $impl -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_OVERLAY=FAIL implementation_missing=$impl"}

# V2 owns the composed gameplay fixes. This driver canonicalizes only the
# committed V2 implementation source before execution, never FFDec output or
# generated AS3. That keeps the runtime patch semantic while removing the last
# format-sensitive seams in method signatures and PowerShell quoting.
$source=[IO.File]::ReadAllText($impl).Replace("`r`n","`n").Replace("`r","`n")
$lines=@($source -split "`n",-1)
$inMissileDestroy=$false
$inArtilleryDestroy=$false
$missileSignatureFixed=0
$artillerySignatureFixed=0
$missileMatcherFixed=0
$artilleryMatcherFixed=0
$patchVersionMatcherFixed=0

$patchVersionPatternLine=@'
  $patchVersionPattern='(?m)^\s*\$patchVersion=''mobile-engine-v3\.24-placement-wrecking-rootfix''\s*$'
'@
$patchVersionReplacementLine=@'
  $patcher=Replace-RegexOne $patcher $patchVersionPattern '$patchVersion=''mobile-engine-v3.25-evidence-rootfix-v2''' 'patch_version_v3_25_v2'
'@
$patchVersionPatternLine=$patchVersionPatternLine.TrimEnd("`r","`n")
$patchVersionReplacementLine=$patchVersionReplacementLine.TrimEnd("`r","`n")

for($i=0;$i -lt $lines.Count;$i++){
  $line=[string]$lines[$i]
  if($line -eq "  `$missileDestroy=@'"){$inMissileDestroy=$true;continue}
  if($line -eq "  `$artilleryDestroy=@'"){$inArtilleryDestroy=$true;continue}

  if($inMissileDestroy -and $line -eq '      private function addParticle'){
    $lines[$i]='      private function addParticle(param1:int) : void'
    $missileSignatureFixed++
    continue
  }
  if($inArtilleryDestroy -and $line -eq '      private function addParticle'){
    $lines[$i]='      private function addParticle() : void'
    $artillerySignatureFixed++
    continue
  }
  if(($inMissileDestroy -or $inArtilleryDestroy) -and $line -eq "'@"){
    $inMissileDestroy=$false
    $inArtilleryDestroy=$false
    continue
  }

  if($line -match "^\s*\`$missile=Replace-RegexOne \`$missile .*missile_owned_destroy'\s*`$"){
    $lines[$i]="  `$missile=Replace-RegexOne `$missile '(?m)^\s*private function addParticle\(param1:int\)\s*:\s*void\s*`$' `$missileDestroy 'missile_owned_destroy'"
    $missileMatcherFixed++
    continue
  }
  if($line -match "^\s*\`$artillery=Replace-RegexOne \`$artillery .*artillery_owned_destroy'\s*`$"){
    $lines[$i]="  `$artillery=Replace-RegexOne `$artillery '(?m)^\s*private function addParticle\(\)\s*:\s*void\s*`$' `$artilleryDestroy 'artillery_owned_destroy'"
    $artilleryMatcherFixed++
    continue
  }
  if($line -match "^\s*\`$patcher=Replace-RegexOne \`$patcher .*patch_version_v3_25_v2'\s*`$"){
    $lines[$i]=$patchVersionPatternLine
    $before=if($i -gt 0){@($lines[0..$i])}else{@($lines[0])}
    $after=if($i+1 -lt $lines.Count){@($lines[($i+1)..($lines.Count-1)])}else{@()}
    $lines=@($before + $patchVersionReplacementLine + $after)
    $patchVersionMatcherFixed++
    $i++
    continue
  }
}

if($missileSignatureFixed -ne 1 -or $artillerySignatureFixed -ne 1 -or $missileMatcherFixed -ne 1 -or $artilleryMatcherFixed -ne 1 -or $patchVersionMatcherFixed -ne 1){
  throw "ANDROID_EVIDENCE_ROOTFIX_DRIVER=FAIL missile_signature=$missileSignatureFixed artillery_signature=$artillerySignatureFixed missile_matcher=$missileMatcherFixed artillery_matcher=$artilleryMatcherFixed patch_version_matcher=$patchVersionMatcherFixed"
}

$runtimeRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-driver\'+$ExpectedSha)
New-Item -ItemType Directory -Force -Path $runtimeRoot|Out-Null
$runtimeImpl=Join-Path $runtimeRoot 'Invoke-AndroidEvidenceRootFixOverlayV2.runtime.ps1'
[IO.File]::WriteAllText($runtimeImpl,($lines -join "`n"),(New-Object System.Text.UTF8Encoding($true)))
$tokens=$null
$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($runtimeImpl,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0){
  $errors|ForEach-Object{Write-Host "ROOTFIX_DRIVER_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
  throw 'ANDROID_EVIDENCE_ROOTFIX_DRIVER=FAIL parser_invalid'
}
Write-Host "ANDROID_EVIDENCE_ROOTFIX_DRIVER=PASS semantic_v2=true source_hotfixes=5 runtime=$runtimeImpl"

try{
  & $runtimeImpl -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
}finally{
  if($Mode -eq 'Restore' -and (Test-Path -LiteralPath $runtimeRoot)){
    Remove-Item -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
