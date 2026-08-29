param(
  [string]$RepositoryRoot,
  [string]$Version = '23.2'
)

$ErrorActionPreference = 'Stop'

function Resolve-RepositoryRoot {
  param([string]$ExplicitRoot)

  if ($ExplicitRoot) {
    $resolved = Resolve-Path -LiteralPath $ExplicitRoot -ErrorAction Stop
    return $resolved.Path
  }

  $scriptRoot = Split-Path -Parent $PSScriptRoot
  $candidate = Split-Path -Parent $scriptRoot
  if (Test-Path -LiteralPath (Join-Path $candidate '.git')) {
    return (Resolve-Path -LiteralPath $candidate).Path
  }

  throw 'WORKSPACE_INIT=FAIL unable to resolve repository root'
}

if ($Version -notmatch '^[0-9]+(?:\.[0-9]+){1,2}$') {
  throw "WORKSPACE_INIT=FAIL invalid version=$Version"
}

$repoRoot = Resolve-RepositoryRoot -ExplicitRoot $RepositoryRoot
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))) {
  throw "WORKSPACE_INIT=FAIL not a git checkout path=$repoRoot"
}

$editableRoot = Join-Path $repoRoot "editable\armyattack-$Version"
$rawRoot = Join-Path $repoRoot ".work\swf-extracted\$Version"

$directories = @(
  $editableRoot,
  (Join-Path $editableRoot 'units'),
  (Join-Path $editableRoot 'enemies'),
  (Join-Path $editableRoot 'buildings'),
  (Join-Path $editableRoot 'effects'),
  (Join-Path $editableRoot 'terrain'),
  (Join-Path $editableRoot 'ui'),
  (Join-Path $editableRoot 'config'),
  (Join-Path $editableRoot 'sounds'),
  (Join-Path $editableRoot 'manifest'),

  $rawRoot,
  (Join-Path $rawRoot 'images'),
  (Join-Path $rawRoot 'shapes'),
  (Join-Path $rawRoot 'sprites'),
  (Join-Path $rawRoot 'frames'),
  (Join-Path $rawRoot 'scripts'),
  (Join-Path $rawRoot 'raw'),

  (Join-Path $repoRoot ".work\cache\$Version"),
  (Join-Path $repoRoot ".work\build\$Version"),
  (Join-Path $repoRoot ".work\reports\$Version")
)

foreach ($path in $directories) {
  New-Item -ItemType Directory -Force -Path $path | Out-Null
}

Push-Location $repoRoot
try {
  $git = Get-Command git.exe -ErrorAction SilentlyContinue
  if (-not $git) {
    $git = Get-Command git -ErrorAction SilentlyContinue
  }

  if ($git) {
    & $git.Source check-ignore -q '.work/'
    if ($LASTEXITCODE -ne 0) {
      throw 'WORKSPACE_GITIGNORE=FAIL .work/ is not ignored by Git'
    }
    Write-Host 'WORKSPACE_GITIGNORE=PASS path=.work/'
  }
  else {
    Write-Host 'WORKSPACE_GITIGNORE=SKIPPED reason=git_not_found'
  }
}
finally {
  Pop-Location
}

Write-Host "WORKSPACE_INIT=PASS"
Write-Host "REPOSITORY_ROOT=$repoRoot"
Write-Host "EDITABLE_ROOT=$editableRoot"
Write-Host "RAW_ROOT=$rawRoot"
Write-Host "CACHE_ROOT=$(Join-Path $repoRoot ".work\cache\$Version")"
Write-Host "BUILD_ROOT=$(Join-Path $repoRoot ".work\build\$Version")"
Write-Host "REPORT_ROOT=$(Join-Path $repoRoot ".work\reports\$Version")"
