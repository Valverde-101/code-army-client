param(
  [string]$RepositoryRoot,
  [string]$Version = '23.2',
  [string]$ExpectedSha,
  [string]$ExpectedSourceSha256 = '99a7e8c219610eabbe97aee74228d52ded1532b4c2d4310432d15082b2ff11c4'
)

$ErrorActionPreference = 'Stop'

function Resolve-RepositoryRoot {
  param([string]$ExplicitRoot)
  if ($ExplicitRoot) { return (Resolve-Path -LiteralPath $ExplicitRoot -ErrorAction Stop).Path }
  $candidate = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  if (Test-Path -LiteralPath (Join-Path $candidate '.git')) { return (Resolve-Path -LiteralPath $candidate).Path }
  throw 'SWF_VALIDATE=FAIL unable_to_resolve_repository_root'
}

function Resolve-Git {
  foreach ($name in @('git.exe','git')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
    if (-not $drive.Root) { continue }
    foreach ($candidate in @((Join-Path $drive.Root 'AndroidBuild\Tools\Git\cmd\git.exe'),(Join-Path $drive.Root 'AndroidBuild\PortableGit\cmd\git.exe'))) {
      if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
  }
  throw 'SWF_VALIDATE=FAIL git_not_found'
}

$repoRoot = Resolve-RepositoryRoot -ExplicitRoot $RepositoryRoot
$git = Resolve-Git
$rawRoot = Join-Path $repoRoot ".work\swf-extracted\$Version"
$reportRoot = Join-Path $repoRoot ".work\reports\$Version"
if (-not (Test-Path -LiteralPath $rawRoot)) { throw "SWF_VALIDATE=FAIL raw_root_missing=$rawRoot" }

$actualHead = (& $git -C $repoRoot rev-parse HEAD).Trim()
if ($ExpectedSha -and $actualHead -ne $ExpectedSha) { throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$actualHead" }
Write-Host "EXACT_HEAD=PASS sha=$actualHead"

$trackedWork = @(& $git -C $repoRoot ls-files -- '.work')
if ($trackedWork.Count -gt 0) {
  $trackedWork | ForEach-Object { Write-Host "TRACKED_WORK_FILE=$_" }
  throw 'WORKSPACE_GITIGNORE=FAIL work_files_are_tracked'
}
& $git -C $repoRoot check-ignore -q '.work/'
if ($LASTEXITCODE -ne 0) { throw 'WORKSPACE_GITIGNORE=FAIL .work_not_ignored' }
Write-Host 'WORKSPACE_GITIGNORE=PASS path=.work/'

$manifestPath = Join-Path $rawRoot 'manifest.json'
$hashCsv = Join-Path $rawRoot 'files.sha256.csv'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "SWF_VALIDATE=FAIL manifest_missing=$manifestPath" }
if (-not (Test-Path -LiteralPath $hashCsv)) { throw "SWF_VALIDATE=FAIL hash_inventory_missing=$hashCsv" }

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.extraction_status -ne 'PASS') { throw "SWF_VALIDATE=FAIL manifest_status=$($manifest.extraction_status)" }
if ($manifest.repository_head -ne $actualHead) { throw "SWF_VALIDATE=FAIL manifest_head=$($manifest.repository_head) actual_head=$actualHead" }
if ($manifest.source.sha256 -ne $ExpectedSourceSha256.ToLowerInvariant()) { throw "SWF_VALIDATE=FAIL source_sha256 expected=$ExpectedSourceSha256 actual=$($manifest.source.sha256)" }

$sourcePath = Join-Path $repoRoot ($manifest.source.path.Replace('/','\'))
if (-not (Test-Path -LiteralPath $sourcePath)) { throw "SWF_VALIDATE=FAIL source_missing=$sourcePath" }
$actualSourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSourceHash -ne $ExpectedSourceSha256.ToLowerInvariant()) { throw "SWF_VALIDATE=FAIL source_changed expected=$ExpectedSourceSha256 actual=$actualSourceHash" }
Write-Host "SWF_SOURCE=PASS sha256=$actualSourceHash path=$sourcePath"

$minimumRequired = @{ images=1; shapes=1; sprites=1; frames=1; scripts=1; raw=1 }
$categoryResults = [ordered]@{}
foreach ($name in $minimumRequired.Keys) {
  $path = Join-Path $rawRoot $name
  $count = @(Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue).Count
  if ($count -lt $minimumRequired[$name]) { throw "SWF_VALIDATE=FAIL category=$name expected_min=$($minimumRequired[$name]) actual=$count" }
  $categoryResults[$name] = $count
  Write-Host "SWF_CATEGORY=PASS name=$name files=$count"
}

$rows = @(Import-Csv -LiteralPath $hashCsv)
if ($rows.Count -lt 1) { throw 'SWF_VALIDATE=FAIL hash_inventory_empty' }

$mismatches = New-Object System.Collections.Generic.List[object]
$checked = 0
foreach ($row in $rows) {
  $path = Join-Path $rawRoot ($row.path.Replace('/','\'))
  if (-not (Test-Path -LiteralPath $path)) { $mismatches.Add([PSCustomObject]@{path=$row.path;reason='missing'}); continue }
  $file = Get-Item -LiteralPath $path
  if ([Int64]$row.size -ne $file.Length) { $mismatches.Add([PSCustomObject]@{path=$row.path;reason='size';expected=$row.size;actual=$file.Length}); continue }
  $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($hash -ne $row.sha256.ToLowerInvariant()) { $mismatches.Add([PSCustomObject]@{path=$row.path;reason='sha256';expected=$row.sha256;actual=$hash}); continue }
  $checked++
}

New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$validationPath = Join-Path $reportRoot 'validation.json'
$result = [ordered]@{
  schema_version=1
  status=if($mismatches.Count -eq 0){'PASS'}else{'FAIL'}
  repository_head=$actualHead
  source_sha256=$actualSourceHash
  checked_files=$checked
  mismatches=@($mismatches)
  categories=$categoryResults
  validated_utc=[DateTime]::UtcNow.ToString('o')
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $validationPath -Encoding UTF8

if ($mismatches.Count -gt 0) {
  $mismatches | Select-Object -First 20 | ForEach-Object { Write-Host "HASH_MISMATCH=$($_ | ConvertTo-Json -Compress)" }
  throw "SWF_VALIDATE=FAIL mismatch_count=$($mismatches.Count) report=$validationPath"
}

Write-Host "SWF_HASH_INVENTORY=PASS checked=$checked"
Write-Host "SWF_VALIDATE=PASS version=$Version report=$validationPath"
