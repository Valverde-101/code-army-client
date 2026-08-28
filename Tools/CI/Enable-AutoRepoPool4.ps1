param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [int]$Slots=4
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$runtimeSource=Join-Path $PSScriptRoot 'Start-AutoRepoPool4.runtime.ps1'
$launcherDir=Join-Path $AndroidBuildRoot 'PC-LAUNCHER\Launcher'
$runtimeDest=Join-Path $launcherDir 'Start-AutoRepoPool4.ps1'
$startScript=Join-Path $launcherDir 'AndroidBuild-START.ps1'
$backupDir=Join-Path $AndroidBuildRoot 'PC-LAUNCHER\Backups'
New-Item -ItemType Directory -Force -Path $launcherDir,$backupDir|Out-Null
if(-not (Test-Path -LiteralPath $runtimeSource)){throw "AUTOREPO_POOL_INSTALL=FAIL runtime_source_missing=$runtimeSource"}
Copy-Item -LiteralPath $runtimeSource -Destination $runtimeDest -Force
$tokens=$null;$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($runtimeDest,[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0){throw "AUTOREPO_POOL_INSTALL=FAIL runtime_parser=$($errors[0].Message)"}

if(Test-Path -LiteralPath $startScript){
  $source=Get-Content -LiteralPath $startScript -Raw
  $marker='# ANDROIDBUILD AUTOREPO POOL4'
  if($source -notmatch [regex]::Escape($marker)){
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup=Join-Path $backupDir ("AndroidBuild-START.ps1.before-autorepo4-"+$stamp)
    Copy-Item -LiteralPath $startScript -Destination $backup -Force
    $append=@(
      '',
      $marker,
      "try { & (Join-Path `$Root 'PC-LAUNCHER\Launcher\Start-AutoRepoPool4.ps1') -AndroidBuildRoot `$Root -Slots 4 } catch { Write-Warning ('Auto-Repo Pool4: ' + `$_.Exception.Message) }"
    ) -join [Environment]::NewLine
    $newSource=$source.TrimEnd()+[Environment]::NewLine+$append+[Environment]::NewLine
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseInput($newSource,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw "AUTOREPO_LAUNCHER_PATCH=FAIL parser=$($errors[0].Message)"}
    Set-Content -LiteralPath $startScript -Value $newSource -Encoding UTF8
    Write-Host "AUTOREPO_LAUNCHER_PATCH=PASS backup=$backup"
  }else{Write-Host 'AUTOREPO_LAUNCHER_PATCH=PASS already_present=1'}
}else{Write-Host 'AUTOREPO_LAUNCHER_PATCH=SKIPPED_WITH_REASON start_script_missing'}

& $runtimeDest -AndroidBuildRoot $AndroidBuildRoot -Slots $Slots
