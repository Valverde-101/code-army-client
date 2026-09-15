param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$ExpectedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repo=(Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
if($ExpectedSha){
  $git=$null
  foreach($name in @('git.exe','git')){$cmd=Get-Command $name -ErrorAction SilentlyContinue;if($cmd){$git=$cmd.Source;break}}
  if(-not $git){throw 'BOOT_RESOURCE_CONTRACT=FAIL git_not_found'}
  $head=(& $git -C $repo rev-parse HEAD).Trim()
  if($LASTEXITCODE -ne 0 -or $head -ne $ExpectedSha){throw "BOOT_RESOURCE_CONTRACT=FAIL exact_head expected=$ExpectedSha actual=$head"}
}

function Read-Required([string]$Relative){
  $path=Join-Path $repo $Relative
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "BOOT_RESOURCE_CONTRACT=FAIL source_missing=$Relative"}
  return Get-Content -LiteralPath $path -Raw
}

$asset=Read-Required 'src\AssetManager.as'
$first=Read-Required 'src\game\states\GameLoadingFirst.as'
$second=Read-Required 'src\game\states\GameLoadingSecond.as'

$m=[regex]::Match($asset,'CVS_FILES_TO_LOAD\s*:\s*Array\s*=\s*\[([^\]]*)\]')
if(-not $m.Success){throw 'BOOT_RESOURCE_CONTRACT=FAIL csv_registry_unparseable'}
$csvIds=@([regex]::Matches($m.Groups[1].Value,'"([^"]+)"')|ForEach-Object{$_.Groups[1].Value})
if($csvIds.Count -eq 0){throw 'BOOT_RESOURCE_CONTRACT=FAIL csv_registry_empty'}
if($csvIds -contains 'map_2'){throw 'BOOT_RESOURCE_CONTRACT=FAIL legacy_missing_asset=map_2.csv'}
$missing=@()
foreach($id in $csvIds){
  $path=Join-Path $repo ("src\config\$id.csv")
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){$missing+="$id.csv"}
}
if($missing.Count -gt 0){throw "BOOT_RESOURCE_CONTRACT=FAIL missing_required_csv=$($missing -join ',')"}
Write-Host "BOOT_RESOURCE_CONTRACT=PASS required_csv=$($csvIds -join ',') missing=0 legacy_map_2=absent"

foreach($check in @(
  @{Name='first_finish_guard';Text=$first;Need='private var mFinishStarted: Boolean = false;'},
  @{Name='first_finish_single_shot';Text=$first;Need='if (!this.mFinishStarted)'},
  @{Name='first_transition_failure_trace';Text=$first;Need='BOOT_TRANSITION_FAILURE'},
  @{Name='second_finish_guard';Text=$second;Need='private var mFinishStarted:Boolean = false;'},
  @{Name='second_finish_single_shot';Text=$second;Need='if(!this.mFinishStarted)'},
  @{Name='second_transition_failure_trace';Text=$second;Need='BOOT_TRANSITION_FAILURE'},
  @{Name='boot_ready_explicit';Text=$second;Need='Utils.DiagEvent("BOOT_READY"'}
)){
  if(-not $check.Text.Contains([string]$check.Need)){throw "BOOT_STATE_MACHINE_CONTRACT=FAIL check=$($check.Name)"}
  Write-Host "BOOT_REGRESSION_CHECK=PASS name=$($check.Name)"
}
Write-Host 'BOOT_STATE_MACHINE_CONTRACT=PASS first_finalize=idempotent second_finalize=idempotent boot_ready=explicit failure_trace=explicit'
