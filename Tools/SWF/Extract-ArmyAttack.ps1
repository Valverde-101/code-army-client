param(
  [string]$RepositoryRoot,
  [string]$Version = '23.2',
  [string]$SourceSwf,
  [string]$FFDecPath,
  [string]$ExpectedSha,
  [string]$ExpectedSourceSha256 = '99a7e8c219610eabbe97aee74228d52ded1532b4c2d4310432d15082b2ff11c4',
  [switch]$Clean,
  [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'

function Resolve-RepositoryRoot {
  param([string]$ExplicitRoot)
  if ($ExplicitRoot) { return (Resolve-Path -LiteralPath $ExplicitRoot -ErrorAction Stop).Path }
  $candidate = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  if (Test-Path -LiteralPath (Join-Path $candidate '.git')) { return (Resolve-Path -LiteralPath $candidate).Path }
  throw 'SWF_EXTRACT=FAIL unable_to_resolve_repository_root'
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
  throw 'SWF_EXTRACT=FAIL git_not_found'
}

function Resolve-FFDec {
  param([string]$RepoRoot,[string]$ExplicitPath)
  if ($ExplicitPath) {
    if (-not (Test-Path -LiteralPath $ExplicitPath)) { throw "FFDEC_PRECHECK=FAIL explicit_path_missing=$ExplicitPath" }
    return (Resolve-Path -LiteralPath $ExplicitPath).Path
  }
  $roots = @((Join-Path $RepoRoot '.work\tools\ffdec'))
  if ($env:ANDROIDBUILD_ROOT) {
    $roots += @((Join-Path $env:ANDROIDBUILD_ROOT 'Tools\FFDec'),(Join-Path $env:ANDROIDBUILD_ROOT 'Tools\JPEXS'))
  }
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($name in @('ffdec-cli.exe','ffdec.bat','ffdec.jar')) {
      $match = Get-ChildItem -LiteralPath $root -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
      if ($match) { return $match.FullName }
    }
  }
  foreach ($name in @('ffdec-cli.exe','ffdec.bat')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

function Resolve-Java {
  foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
    if (-not $drive.Root) { continue }
    $candidate = Join-Path $drive.Root 'AndroidBuild\Tools\Java\jdk-17\bin\java.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  $cmd = Get-Command java.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw 'FFDEC_PRECHECK=FAIL java_not_found_for_ffdec_jar'
}

$repoRoot = Resolve-RepositoryRoot -ExplicitRoot $RepositoryRoot
$git = Resolve-Git
$actualHead = (& $git -C $repoRoot rev-parse HEAD).Trim()
if ($ExpectedSha -and $actualHead -ne $ExpectedSha) { throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$actualHead" }
Write-Host "EXACT_HEAD=PASS sha=$actualHead"

if (-not $AllowDirty) {
  $dirty = @(& $git -C $repoRoot status --porcelain --untracked-files=no)
  if ($dirty.Count -gt 0) {
    $dirty | ForEach-Object { Write-Host "DIRTY=$_" }
    throw 'SOURCE_VALIDATION=FAIL tracked_worktree_dirty'
  }
}

$initializer = Join-Path $repoRoot 'Tools\SWF\Initialize-ArmyAttackWorkspace.ps1'
if (-not (Test-Path -LiteralPath $initializer)) { throw "SWF_WORKSPACE=FAIL initializer_missing=$initializer" }
& $initializer -RepositoryRoot $repoRoot -Version $Version -GitPath $git

$rawRoot = Join-Path $repoRoot ".work\swf-extracted\$Version"
$reportRoot = Join-Path $repoRoot ".work\reports\$Version"
if ($Clean -and (Test-Path -LiteralPath $rawRoot)) {
  Remove-Item -LiteralPath $rawRoot -Recurse -Force
  & $initializer -RepositoryRoot $repoRoot -Version $Version -GitPath $git
}

if (-not $SourceSwf) { $SourceSwf = Join-Path $repoRoot 'vendor\Test_army_attack\armyattack\assets\iArmyAirOfflineSavingv23.swf' }
if (-not (Test-Path -LiteralPath $SourceSwf)) { throw "SWF_SOURCE=FAIL missing=$SourceSwf" }
$SourceSwf = (Resolve-Path -LiteralPath $SourceSwf).Path
$sourceInfo = Get-Item -LiteralPath $SourceSwf
$sourceHash = (Get-FileHash -LiteralPath $SourceSwf -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedSourceSha256 -and $sourceHash -ne $ExpectedSourceSha256.ToLowerInvariant()) {
  throw "SWF_SOURCE=FAIL expected_sha256=$ExpectedSourceSha256 actual_sha256=$sourceHash"
}
$publishedPath = Join-Path $repoRoot 'vendor\Test_army_attack'
$publishedSha = (& $git -C $publishedPath rev-parse HEAD).Trim()
Write-Host "SWF_SOURCE=PASS path=$SourceSwf size=$($sourceInfo.Length) sha256=$sourceHash"
Write-Host "PUBLISHED_SUBMODULE_SHA=$publishedSha"

$ffdec = Resolve-FFDec -RepoRoot $repoRoot -ExplicitPath $FFDecPath
if (-not $ffdec) {
  $ensure = Join-Path $repoRoot 'Tools\SWF\Ensure-FFDec.ps1'
  if (-not (Test-Path -LiteralPath $ensure)) { throw "FFDEC_PRECHECK=FAIL ensure_script_missing=$ensure" }
  & $ensure -RepositoryRoot $repoRoot
  $ffdec = Resolve-FFDec -RepoRoot $repoRoot
}
if (-not $ffdec) { throw 'FFDEC_PRECHECK=FAIL ffdec_not_resolved_after_provision' }
Write-Host "FFDEC_PRECHECK=PASS path=$ffdec"

$java = $null
if ([IO.Path]::GetExtension($ffdec).ToLowerInvariant() -eq '.jar') {
  $java = Resolve-Java
  Write-Host "FFDEC_JAVA=PASS path=$java"
}

function Invoke-FFDec {
  param([Parameter(Mandatory=$true)][string[]]$Arguments,[Parameter(Mandatory=$true)][string]$LogPath,[Parameter(Mandatory=$true)][string]$Gate)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
  if ($java) { $output = @(& $java '-jar' $ffdec @Arguments 2>&1) } else { $output = @(& $ffdec @Arguments 2>&1) }
  $exitCode = $LASTEXITCODE
  $output | Set-Content -LiteralPath $LogPath -Encoding UTF8
  if ($exitCode -ne 0) {
    $output | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
    throw "$Gate=FAIL exit=$exitCode log=$LogPath"
  }
  Write-Host "$Gate=PASS log=$LogPath"
}

$logsRoot = Join-Path $rawRoot 'raw\logs'
New-Item -ItemType Directory -Force -Path $logsRoot,$reportRoot | Out-Null
$helpLog = Join-Path $logsRoot 'ffdec-help.txt'
Invoke-FFDec -Arguments @('-cli','-help') -LogPath $helpLog -Gate 'FFDEC_HELP'

$exports = @(
  @{ Gate='SWF_EXPORT_IMAGES'; Type='image'; Path=(Join-Path $rawRoot 'images'); Format='image:png' },
  @{ Gate='SWF_EXPORT_SHAPES'; Type='shape'; Path=(Join-Path $rawRoot 'shapes'); Format='shape:svg' },
  @{ Gate='SWF_EXPORT_MORPHSHAPES'; Type='morphshape'; Path=(Join-Path $rawRoot 'shapes\morphshapes'); Format='morphshape:svg' },
  @{ Gate='SWF_EXPORT_SPRITES'; Type='sprite'; Path=(Join-Path $rawRoot 'sprites'); Format='sprite:png' },
  @{ Gate='SWF_EXPORT_FRAMES'; Type='frame'; Path=(Join-Path $rawRoot 'frames'); Format='frame:png' },
  @{ Gate='SWF_EXPORT_SCRIPTS'; Type='script'; Path=(Join-Path $rawRoot 'scripts'); Format='script:as' },
  @{ Gate='SWF_EXPORT_SOUNDS'; Type='sound'; Path=(Join-Path $rawRoot 'raw\sounds'); Format='sound:mp3_wav' },
  @{ Gate='SWF_EXPORT_BINARY'; Type='binaryData'; Path=(Join-Path $rawRoot 'raw\binaryData'); Format=$null },
  @{ Gate='SWF_EXPORT_SYMBOLS'; Type='symbolClass'; Path=(Join-Path $rawRoot 'raw\symbolClass'); Format=$null },
  @{ Gate='SWF_EXPORT_TEXT'; Type='text'; Path=(Join-Path $rawRoot 'raw\text'); Format='text:plain' }
)

foreach ($entry in $exports) {
  New-Item -ItemType Directory -Force -Path $entry.Path | Out-Null
  $args = @('-cli','-onerror','abort','-timeout','180','-exportTimeout','7200','-exportFileTimeout','300','-stat')
  if ($entry.Format) { $args += @('-format',$entry.Format) }
  if ($entry.Type -eq 'frame') { $args += '-ignorebackground' }
  $args += @('-export',$entry.Type,$entry.Path,$SourceSwf)
  $log = Join-Path $logsRoot ("export-" + $entry.Type + '.log')
  Invoke-FFDec -Arguments $args -LogPath $log -Gate $entry.Gate
}

Invoke-FFDec -Arguments @('-cli','-dumpSWF',$SourceSwf) -LogPath (Join-Path $rawRoot 'raw\swf-tags.txt') -Gate 'SWF_DUMP_TAGS'
Invoke-FFDec -Arguments @('-cli','-dumpAS3',$SourceSwf) -LogPath (Join-Path $rawRoot 'raw\as3-list.txt') -Gate 'SWF_DUMP_AS3'
$xmlPath = Join-Path $rawRoot 'raw\swf.xml'
Invoke-FFDec -Arguments @('-cli','-swf2xml',$SourceSwf,$xmlPath) -LogPath (Join-Path $logsRoot 'swf2xml.log') -Gate 'SWF_EXPORT_XML'

$categories = [ordered]@{}
foreach ($category in @('images','shapes','sprites','frames','scripts','raw')) {
  $path = Join-Path $rawRoot $category
  $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue)
  $bytes = 0L
  foreach ($file in $files) { $bytes += $file.Length }
  $categories[$category] = [ordered]@{ path=$path.Substring($repoRoot.Length).TrimStart('\').Replace('\','/'); files=$files.Count; bytes=$bytes }
}

$hashRows = @()
foreach ($file in @(Get-ChildItem -LiteralPath $rawRoot -Recurse -File -ErrorAction Stop)) {
  if ($file.Name -in @('manifest.json','files.sha256.csv')) { continue }
  $relative = $file.FullName.Substring($rawRoot.Length).TrimStart('\').Replace('\','/')
  $hashRows += [PSCustomObject]@{ path=$relative; size=$file.Length; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$hashCsv = Join-Path $rawRoot 'files.sha256.csv'
$hashRows | Sort-Object path | Export-Csv -LiteralPath $hashCsv -NoTypeInformation -Encoding UTF8

$manifest = [ordered]@{
  schema_version=1
  game='Army Attack'
  content_version=$Version
  extraction_status='PASS'
  repository_head=$actualHead
  published_submodule_sha=$publishedSha
  source=[ordered]@{ path=$SourceSwf.Substring($repoRoot.Length).TrimStart('\').Replace('\','/'); size=$sourceInfo.Length; sha256=$sourceHash }
  ffdec=[ordered]@{ path=$ffdec; help_log=$helpLog }
  workspace=[ordered]@{ raw_root=$rawRoot; report_root=$reportRoot }
  categories=$categories
  hashed_files=$hashRows.Count
  generated_utc=[DateTime]::UtcNow.ToString('o')
}
$manifestPath = Join-Path $rawRoot 'manifest.json'
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$summaryPath = Join-Path $reportRoot 'extraction-summary.json'
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "SWF_MANIFEST=PASS path=$manifestPath hashed_files=$($hashRows.Count)"
Write-Host "SWF_EXTRACT=PASS version=$Version raw_root=$rawRoot report=$summaryPath"
