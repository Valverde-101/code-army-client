param(
  [Parameter(Mandatory=$true)][string]$Repository,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$SourceBranch
)

$ErrorActionPreference = 'Stop'

function Resolve-AndroidBuildRoot {
  if ($env:ANDROIDBUILD_ROOT -and (Test-Path -LiteralPath $env:ANDROIDBUILD_ROOT)) {
    return (Resolve-Path -LiteralPath $env:ANDROIDBUILD_ROOT).Path
  }

  $candidates = New-Object System.Collections.Generic.List[string]
  foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
    if (-not $drive.Root) { continue }
    $root = Join-Path $drive.Root 'AndroidBuild'
    if (-not $candidates.Contains($root)) { $candidates.Add($root) }
  }

  $preferred = $candidates | Where-Object {
    (Test-Path -LiteralPath (Join-Path $_ 'PC-LAUNCHER')) -or
    (Test-Path -LiteralPath (Join-Path $_ 'Repositories'))
  } | Select-Object -First 1

  if (-not $preferred) {
    throw "ANDROIDBUILD_ROOT=FAIL no AndroidBuild root found on mounted filesystem drives"
  }

  return (Resolve-Path -LiteralPath $preferred).Path
}

function Resolve-Git([string]$AndroidBuildRoot) {
  $candidates = @()

  $existing = Get-Command git.exe -ErrorAction SilentlyContinue
  if ($existing) { $candidates += $existing.Source }

  $candidates += @(
    (Join-Path $AndroidBuildRoot 'Tools\Git\cmd\git.exe'),
    (Join-Path $AndroidBuildRoot 'PortableGit\cmd\git.exe')
  )

  $git = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
  if (-not $git) {
    throw "PRECHECK_GIT=FAIL git.exe not found"
  }

  return $git
}

$androidBuildRoot = Resolve-AndroidBuildRoot
$git = Resolve-Git $androidBuildRoot

& $git config --global core.longPaths true

$reposRoot = Join-Path $androidBuildRoot 'Repositories'
$repoName = ($Repository -split '/')[-1]
$target = Join-Path $reposRoot $repoName
$repoUrl = "https://github.com/$Repository.git"

New-Item -ItemType Directory -Force -Path $reposRoot | Out-Null

Write-Host "ANDROIDBUILD_ROOT=$androidBuildRoot"
Write-Host "GIT=$git"
Write-Host "REPOSITORY=$Repository"
Write-Host "BRANCH=$SourceBranch"
Write-Host "EXPECTED_SOURCE_SHA=$ExpectedSha"
Write-Host "PHYSICAL_REPO_ROOT=$target"

$remoteSha = (& $git ls-remote $repoUrl "refs/heads/$SourceBranch" | ForEach-Object { ($_ -split "\s+")[0] }).Trim()
if (-not $remoteSha) {
  throw "PRECHECK_GITHUB=FAIL unable to resolve remote branch=$SourceBranch"
}
if ($remoteSha -ne $ExpectedSha) {
  throw "REMOTE_HEAD=FAIL expected=$ExpectedSha actual=$remoteSha branch=$SourceBranch"
}
Write-Host "PRECHECK_GITHUB=PASS remote_sha=$remoteSha"

if (Test-Path -LiteralPath $target) {
  if (-not (Test-Path -LiteralPath (Join-Path $target '.git'))) {
    throw "SOURCE_VALIDATION=FAIL target exists but is not a git repository path=$target"
  }

  Push-Location $target
  try {
    $dirty = & $git status --porcelain
    if ($dirty) {
      Write-Host "SOURCE_VALIDATION=FAIL physical clone is dirty"
      $dirty | ForEach-Object { Write-Host $_ }
      throw "PHYSICAL_CLONE_DIRTY=FAIL path=$target"
    }

    $origin = (& $git remote get-url origin).Trim()
    if ($origin -notmatch 'Valverde-101/code-army-client') {
      throw "SOURCE_VALIDATION=FAIL unexpected origin=$origin"
    }

    & $git fetch --prune origin $SourceBranch
    if ($LASTEXITCODE -ne 0) { throw "GIT_FETCH=FAIL exit=$LASTEXITCODE" }

    & $git checkout -B $SourceBranch "origin/$SourceBranch"
    if ($LASTEXITCODE -ne 0) { throw "GIT_CHECKOUT=FAIL exit=$LASTEXITCODE" }

    & $git reset --hard $ExpectedSha
    if ($LASTEXITCODE -ne 0) { throw "GIT_RESET=FAIL exit=$LASTEXITCODE" }
  }
  finally {
    Pop-Location
  }
}
else {
  & $git clone --branch $SourceBranch $repoUrl $target
  if ($LASTEXITCODE -ne 0) { throw "GIT_CLONE=FAIL exit=$LASTEXITCODE target=$target" }
}

Push-Location $target
try {
  $actual = (& $git rev-parse HEAD).Trim()
  if ($actual -ne $ExpectedSha) {
    throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$actual"
  }

  $required = @(
    'README.md',
    'src\GameMain.as',
    'src\Config.as',
    'src\iArmyAirOfflineSavingv22_1-app.xml',
    'src\iArmyAirOfflineSavingv22_1.fla',
    'src\config\army_config.json',
    'src\config\tile_map.csv',
    'src\data'
  )

  $missing = @()
  foreach ($item in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $target $item))) {
      $missing += $item
      Write-Host "MISSING=$item"
    }
  }

  if ($missing.Count -gt 0) {
    throw "SOURCE_FILES=FAIL missing_count=$($missing.Count)"
  }

  $asCount = (Get-ChildItem -LiteralPath $target -Recurse -File -Filter '*.as' -ErrorAction SilentlyContinue).Count
  $flaCount = (Get-ChildItem -LiteralPath $target -Recurse -File -Filter '*.fla' -ErrorAction SilentlyContinue).Count
  $pngCount = (Get-ChildItem -LiteralPath $target -Recurse -File -Filter '*.png' -ErrorAction SilentlyContinue).Count
  $mp3Count = (Get-ChildItem -LiteralPath $target -Recurse -File -Filter '*.mp3' -ErrorAction SilentlyContinue).Count
  $jsonCount = (Get-ChildItem -LiteralPath $target -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue).Count

  Write-Host "EXACT_HEAD=PASS sha=$actual"
  Write-Host "SOURCE_FILES=PASS"
  Write-Host "AS_FILES=$asCount"
  Write-Host "FLA_FILES=$flaCount"
  Write-Host "PNG_FILES=$pngCount"
  Write-Host "MP3_FILES=$mp3Count"
  Write-Host "JSON_FILES=$jsonCount"
  Write-Host "LOCAL_SOURCE_READY=PASS path=$target"
}
finally {
  Pop-Location
}
