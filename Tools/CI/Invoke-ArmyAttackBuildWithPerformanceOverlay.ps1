param([Parameter(Mandatory=$true)][string]$ContextPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$ctx=Get-Content -LiteralPath $ContextPath -Raw|ConvertFrom-Json
$repoRoot=[string]$ctx.repo_root
$androidBuildRoot=[string]$ctx.androidbuild_root
$expected=[string]$ctx.expected_sha
if(-not $repoRoot -or -not $androidBuildRoot -or $expected -notmatch '^[a-f0-9]{40}$'){throw 'ARMY_PERF_BUILD_HOOK=FAIL invalid_context'}
$repoRoot=(Resolve-Path -LiteralPath $repoRoot).Path
$androidBuildRoot=(Resolve-Path -LiteralPath $androidBuildRoot).Path
Import-Module (Join-Path $androidBuildRoot 'Core\Current\AndroidBuild.psd1') -DisableNameChecking -Force
$git=Get-AndroidBuildGitPath $androidBuildRoot
$identity=Test-AndroidBuildExactHead -RepoRoot $repoRoot -ExpectedSha $expected -AndroidBuildRoot $androidBuildRoot
if([string]$identity.status -ne 'PASS' -or [string]$identity.actual -ne $expected){throw "ARMY_PERF_BUILD_HOOK=FAIL exact_head expected=$expected actual=$($identity.actual)"}
$overlay=Join-Path $repoRoot 'Tools\CI\Invoke-AndroidRuntimePerformanceOverlay.ps1'
$baseHook=Join-Path $repoRoot '.github\scripts\armyattack-build.ps1'
if(-not(Test-Path -LiteralPath $overlay -PathType Leaf)){throw "ARMY_PERF_BUILD_HOOK=FAIL overlay_missing=$overlay"}
if(-not(Test-Path -LiteralPath $baseHook -PathType Leaf)){throw "ARMY_PERF_BUILD_HOOK=FAIL base_hook_missing=$baseHook"}
$tokens=$null;$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($overlay,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0){$errors|ForEach-Object{Write-Host "PARSER_ERROR file=$overlay line=$($_.Extent.StartLineNumber) message=$($_.Message)"};throw 'ARMY_PERF_BUILD_HOOK=FAIL overlay_parser'}
Write-Host "ARMY_PERF_BUILD_HOOK=START sha=$expected strategy=temporary-source-overlay"
try{
  & $overlay -RepoRoot $repoRoot -ExpectedSha $expected -GitPath $git -Mode Apply
  & $baseHook -ContextPath $ContextPath
  Write-Host 'ARMY_PERF_BUILD_HOOK_BASE=PASS'
}finally{
  & $overlay -RepoRoot $repoRoot -ExpectedSha $expected -GitPath $git -Mode Restore
}
$after=(& $git -C $repoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $after -ne $expected){throw "ARMY_PERF_BUILD_HOOK=FAIL final_head expected=$expected actual=$after"}
Write-Host "ARMY_PERF_BUILD_HOOK=PASS sha=$expected source_restored=true"
