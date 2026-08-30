param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [ValidateRange(1,20)][int]$KeepBuilds=3
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(-not (Test-Path -LiteralPath $RepoRoot)){throw "REPO_WORKSPACE=FAIL repo_missing=$RepoRoot"}
$repoWorkRoot=Join-Path $RepoRoot '.work'
$canonicalRepoBuildRoot=Join-Path $repoWorkRoot 'Builds\code-army-client'
$legacyBuildParent=Join-Path $AndroidBuildRoot 'Builds'
$legacyRepoBuildRoot=Join-Path $legacyBuildParent 'code-army-client'
$archiveRoot=Join-Path $AndroidBuildRoot 'APK-FINAL\archive'

New-Item -ItemType Directory -Force -Path $repoWorkRoot,$canonicalRepoBuildRoot,$legacyBuildParent | Out-Null

function Remove-JunctionOnly([string]$Path){
  $cmd=Get-Command cmd.exe -ErrorAction Stop
  & $cmd.Source /d /c ('rmdir "{0}"' -f $Path)
  if($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $Path)){throw "REPO_WORKSPACE=FAIL junction_remove path=$Path exit=$LASTEXITCODE"}
}

function Get-LinkTarget([string]$Path){
  try{
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if(-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $null}
    $target=$item.Target
    if($target -is [array]){$target=$target|Select-Object -First 1}
    if($target){return [IO.Path]::GetFullPath([string]$target).TrimEnd('\')}
  }catch{}
  return $null
}

function Select-KeepDirectories([string]$Root,[string]$PinnedName,[int]$Count){
  if(-not (Test-Path -LiteralPath $Root)){return @()}
  $dirs=@(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
  $result=New-Object System.Collections.Generic.List[object]
  $pinned=$dirs|Where-Object{$_.Name -eq $PinnedName}|Select-Object -First 1
  if($pinned){$result.Add($pinned)}
  foreach($dir in $dirs){
    if($result.Count -ge $Count){break}
    if($pinned -and $dir.FullName -eq $pinned.FullName){continue}
    $result.Add($dir)
  }
  return @($result)
}

# One-time migration: preserve only the newest/pinned build folders, then make the old
# global path a compatibility junction. Actual bytes live under the repository .work.
if(Test-Path -LiteralPath $legacyRepoBuildRoot){
  $target=Get-LinkTarget $legacyRepoBuildRoot
  $canonicalFull=[IO.Path]::GetFullPath($canonicalRepoBuildRoot).TrimEnd('\')
  if($target){
    if($target -ne $canonicalFull){
      Remove-JunctionOnly $legacyRepoBuildRoot
    }
  }else{
    $selected=@(Select-KeepDirectories -Root $legacyRepoBuildRoot -PinnedName $ExpectedSha -Count $KeepBuilds)
    foreach($dir in $selected){
      $dest=Join-Path $canonicalRepoBuildRoot $dir.Name
      if(Test-Path -LiteralPath $dest){
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force
      }else{
        Move-Item -LiteralPath $dir.FullName -Destination $dest
      }
    }
    Remove-Item -LiteralPath $legacyRepoBuildRoot -Recurse -Force
    Write-Host "REPO_WORKSPACE_MIGRATION=PASS from=$legacyRepoBuildRoot to=$canonicalRepoBuildRoot"
  }
}

if(-not (Test-Path -LiteralPath $legacyRepoBuildRoot)){
  New-Item -ItemType Junction -Path $legacyRepoBuildRoot -Target $canonicalRepoBuildRoot | Out-Null
}
$linkTarget=Get-LinkTarget $legacyRepoBuildRoot
$canonicalExpected=[IO.Path]::GetFullPath($canonicalRepoBuildRoot).TrimEnd('\')
if($linkTarget -ne $canonicalExpected){throw "REPO_WORKSPACE=FAIL legacy_link expected=$canonicalExpected actual=$linkTarget"}

function Prune-Directories([string]$Root,[string]$PinnedName,[int]$Count,[string]$Label){
  if(-not (Test-Path -LiteralPath $Root)){return}
  $keep=@(Select-KeepDirectories -Root $Root -PinnedName $PinnedName -Count $Count)
  $keepPaths=@{}
  foreach($dir in $keep){$keepPaths[$dir.FullName.ToLowerInvariant()]=$true}
  $removed=0
  foreach($dir in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)){
    if(-not $keepPaths.ContainsKey($dir.FullName.ToLowerInvariant())){
      Remove-Item -LiteralPath $dir.FullName -Recurse -Force
      $removed++
    }
  }
  $remaining=@(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
  if($remaining.Count -gt $Count){throw "REPO_RETENTION=FAIL label=$Label remaining=$($remaining.Count) keep=$Count"}
  Write-Host "REPO_RETENTION=PASS label=$Label kept=$($remaining.Count) removed=$removed root=$Root"
}

Prune-Directories -Root $canonicalRepoBuildRoot -PinnedName $ExpectedSha -Count $KeepBuilds -Label 'repo_builds'
Prune-Directories -Root $archiveRoot -PinnedName $ExpectedSha -Count $KeepBuilds -Label 'apk_archive'

Write-Host "REPO_WORKSPACE=PASS canonical=$canonicalRepoBuildRoot legacy_alias=$legacyRepoBuildRoot keep=$KeepBuilds expected_sha=$ExpectedSha"
if($env:GITHUB_ENV){
  "REPO_WORK_ROOT=$repoWorkRoot"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "REPO_BUILD_ROOT=$canonicalRepoBuildRoot"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
}
