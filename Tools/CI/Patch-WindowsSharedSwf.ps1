param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$InputSwf,
  [Parameter(Mandatory=$true)][string]$OutputSwf,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [string]$GitPath,
  [string]$ManifestPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$gitCandidates=@()
if($GitPath){$gitCandidates+=$GitPath}
$gitCmd=Get-Command git.exe -ErrorAction SilentlyContinue
if($gitCmd){$gitCandidates+=$gitCmd.Source}
$repoParent=Split-Path -Parent $RepoRoot
$root=Split-Path -Parent $repoParent
$gitCandidates+=@((Join-Path $root 'Tools\Git\cmd\git.exe'),(Join-Path $root 'PortableGit\cmd\git.exe'))
$git=$gitCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_ -PathType Leaf)}|Select-Object -First 1
if(-not $git){throw 'WINDOWS_SWF_PATCH=FAIL git_missing'}
$head=(& $git -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $head -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$head"}
if(-not(Test-Path -LiteralPath $InputSwf -PathType Leaf)){throw "WINDOWS_SWF_PATCH=FAIL input_missing=$InputSwf"}

$basePatcher=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
if(-not(Test-Path -LiteralPath $basePatcher -PathType Leaf)){throw "WINDOWS_SWF_PATCH=FAIL base_patcher_missing=$basePatcher"}
$baseText=Get-Content -LiteralPath $basePatcher -Raw
foreach($needle in @(
  'function Convert-MobileAirSourceForFFDec',
  "if(`$configMode -eq 'BUILD_FOR_MOBILE_AIR')",
  'Convert-MobileAirSourceForFFDec -Source $source -Destination $ffdecSource',
  "if(`$ClassName -eq 'game.gui.GameHUD')"
)){
  if(-not $baseText.Contains($needle)){throw "WINDOWS_SWF_PATCH=FAIL patcher_contract_missing=$needle"}
}

# Derive the desktop-AIR FFDec compiler path from the exact same patch set used by Android.
# Outside CONFIG blocks is shared. BUILD_FOR_AIR blocks are retained, MOBILE and NOT_AIR blocks are excluded.
$desktopText=$baseText
$desktopText=$desktopText.Replace('function Convert-MobileAirSourceForFFDec','function Convert-WindowsAirSourceForFFDec')
$desktopText=$desktopText.Replace("if(`$configMode -eq 'BUILD_FOR_MOBILE_AIR')","if(`$configMode -eq 'BUILD_FOR_AIR')")
$desktopText=$desktopText.Replace('Convert-MobileAirSourceForFFDec -Source $source -Destination $ffdecSource','Convert-WindowsAirSourceForFFDec -Source $source -Destination $ffdecSource')
$desktopText=$desktopText.Replace("if(`$ClassName -eq 'game.gui.GameHUD'){","if(`$false -and `$ClassName -eq 'game.gui.GameHUD'){")
$desktopText=$desktopText.Replace('target=BUILD_FOR_MOBILE_AIR','target=BUILD_FOR_AIR')

$outDir=Split-Path -Parent $OutputSwf
if(-not $outDir){throw 'WINDOWS_SWF_PATCH=FAIL output_parent_missing'}
New-Item -ItemType Directory -Force -Path $outDir|Out-Null
$tempPatcher=Join-Path $outDir 'Patch-WindowsSharedSwf.generated.ps1'
$desktopText|Set-Content -LiteralPath $tempPatcher -Encoding UTF8
if(-not $ManifestPath){$ManifestPath=Join-Path $outDir 'SWF-WINDOWS-SHARED-PATCH.json'}
$inputSha=(Get-FileHash -LiteralPath $InputSwf -Algorithm SHA256).Hash.ToLowerInvariant()

try{
  $invoke=@{
    RepoRoot=$RepoRoot
    InputSwf=$InputSwf
    OutputSwf=$OutputSwf
    ExpectedSha=$ExpectedSha
    GitPath=$git
    ExpectedSourceSha256=$inputSha
    ManifestPath=$ManifestPath
  }
  & $tempPatcher @invoke
  if($LASTEXITCODE -ne 0){throw "WINDOWS_SWF_PATCH=FAIL generated_patcher_exit=$LASTEXITCODE"}
  if(-not(Test-Path -LiteralPath $OutputSwf -PathType Leaf)){throw "WINDOWS_SWF_PATCH=FAIL output_missing=$OutputSwf"}
  $outputSha=(Get-FileHash -LiteralPath $OutputSwf -Algorithm SHA256).Hash.ToLowerInvariant()
  if($outputSha -eq $inputSha){throw 'WINDOWS_SWF_PATCH=FAIL output_equals_seed'}
  $manifest=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.tested_sha -ne $ExpectedSha){throw "WINDOWS_SWF_PATCH=FAIL manifest_sha=$($manifest.tested_sha) expected=$ExpectedSha"}
  $manifest|Add-Member -NotePropertyName target_profile -NotePropertyValue 'windows-air-desktop' -Force
  $manifest|Add-Member -NotePropertyName base_patcher -NotePropertyValue 'Tools/CI/Patch-AndroidPerformanceSwf.ps1' -Force
  $manifest|Add-Member -NotePropertyName base_patcher_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath $basePatcher -Algorithm SHA256).Hash.ToLowerInvariant()) -Force
  $manifest|Add-Member -NotePropertyName source_seed_sha256 -NotePropertyValue $inputSha -Force
  $manifest|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $ManifestPath -Encoding UTF8
  Write-Host "WINDOWS_SWF_PATCH=PASS tested_sha=$ExpectedSha seed_sha256=$inputSha output_sha256=$outputSha profile=windows-air-desktop manifest=$ManifestPath"
}finally{
  Remove-Item -LiteralPath $tempPatcher -Force -ErrorAction SilentlyContinue
}
