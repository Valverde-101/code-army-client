param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Fail([string]$Gate,[string]$Component,[string]$Operation,[string]$Expected,[string]$Actual,[int]$ExitCode=1){
  Write-Host "$Gate=FAIL"
  Write-Host "COMPONENT=$Component"
  Write-Host "OPERATION=$Operation"
  Write-Host "EXPECTED=$Expected"
  Write-Host "ACTUAL=$Actual"
  Write-Host "EXIT_CODE=$ExitCode"
  exit $ExitCode
}

if(-not $env:GITHUB_WORKSPACE){Fail 'EXACT_HEAD' 'SOURCE' 'workspace' 'GITHUB_WORKSPACE' 'missing'}
if(-not $env:GITHUB_ENV){Fail 'PRECHECK_GITHUB' 'RUNNER' 'github_env' 'GITHUB_ENV' 'missing'}

$root=$null
foreach($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue){
  if(-not $drive.Root){continue}
  $candidate=Join-Path $drive.Root 'AndroidBuild'
  $repo=Join-Path $candidate 'Repositories\code-army-client'
  if(Test-Path -LiteralPath $repo){$root=$candidate;break}
}
if(-not $root){Fail 'PRECHECK_ANDROIDBUILD_ROOT' 'TOOLCHAIN' 'discover_androidbuild_root' '<drive>:\AndroidBuild' 'missing'}

$gitCandidates=@()
$pathGit=Get-Command git.exe -ErrorAction SilentlyContinue
if($pathGit){$gitCandidates+=$pathGit.Source}
$gitCandidates+=@(
  (Join-Path $root 'Tools\Git\cmd\git.exe'),
  (Join-Path $root 'PortableGit\cmd\git.exe')
)
$git=$gitCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
if(-not $git){Fail 'PRECHECK_GIT' 'TOOLCHAIN' 'resolve_portable_git' "$root\Tools\Git\cmd\git.exe or $root\PortableGit\cmd\git.exe" 'missing'}

$gitOutput=@(& $git -C $env:GITHUB_WORKSPACE rev-parse HEAD 2>&1)
$gitExit=$LASTEXITCODE
$actual=if($gitOutput.Count -gt 0){$gitOutput[0].ToString().Trim()}else{''}
if($gitExit -ne 0){Fail 'EXACT_HEAD' 'SOURCE' 'git_rev_parse' $ExpectedSha ($gitOutput -join ' | ') $gitExit}
if($actual -ne $ExpectedSha){Fail 'EXACT_HEAD' 'SOURCE' 'head_match' $ExpectedSha $actual}
Write-Host "EXACT_HEAD=PASS sha=$actual"

$adb=Join-Path $root 'AndroidSDK\platform-tools\adb.exe'
if(-not(Test-Path -LiteralPath $adb)){Fail 'ADB_DEVICE' 'ADB' 'portable_path' $adb 'missing'}
$adbVersion=@(& $adb version 2>&1)
if($LASTEXITCODE -ne 0){Fail 'ADB_DEVICE' 'ADB' 'version' 'exit=0' ("exit="+$LASTEXITCODE) $LASTEXITCODE}

"ANDROIDBUILD_ROOT=$root"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
"ADB_EXE=$adb"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
"GIT_EXE=$git"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append

Write-Host "PRECHECK_GITHUB=PASS repository=$env:GITHUB_REPOSITORY run=$env:GITHUB_RUN_ID"
Write-Host "BROKER=PASS runner_assigned=$env:RUNNER_NAME"
Write-Host "RUNNER_ASSIGNMENT=PASS runner=$env:RUNNER_NAME"
Write-Host "PRECHECK_ANDROIDBUILD_ROOT=PASS root=$root"
Write-Host "GIT_PATH=PASS path=$git"
Write-Host "ADB_PATH=PASS path=$adb"
Write-Host "ADB_VERSION=PASS $($adbVersion -join ' | ')"
exit 0
