# Recover a stale canonical-repository Git index lock only when it is old,
# not held open, and no Git process is active. Never remove an active lock.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [int]$MinAgeSeconds = 120
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($MinAgeSeconds -lt 60) { throw "GIT_INDEX_LOCK_PREFLIGHT=FAIL reason=unsafe_minimum_age" }
if (-not $env:ANDROIDBUILD_ROOT) { throw "GIT_INDEX_LOCK_PREFLIGHT=FAIL reason=androidbuild_root_missing" }
$canonical = [IO.Path]::GetFullPath((Join-Path $env:ANDROIDBUILD_ROOT 'Repositories\code-army-client')).TrimEnd('\')
$actual = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
if (-not [string]::Equals($canonical,$actual,[StringComparison]::OrdinalIgnoreCase)) {
    throw "GIT_INDEX_LOCK_PREFLIGHT=FAIL reason=unexpected_repository_root"
}
if (-not (Test-Path -LiteralPath $actual -PathType Container)) {
    Write-Host 'GIT_INDEX_LOCK_PREFLIGHT=PASS state=repository_not_materialized'
    return
}
$lockPath = Join-Path $actual '.git\index.lock'
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    Write-Host 'GIT_INDEX_LOCK_PREFLIGHT=PASS state=absent'
    return
}
$lock = Get-Item -LiteralPath $lockPath -Force
$age = ([DateTime]::UtcNow - $lock.LastWriteTimeUtc).TotalSeconds
if ($age -lt $MinAgeSeconds) {
    throw "GIT_INDEX_LOCK_PREFLIGHT=FAIL reason=recent_lock age_seconds=$([int]$age) min_age_seconds=$MinAgeSeconds"
}
function Assert-NoRunningGit([int]$WaitSeconds=0) {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $announced = $false
    while ($true) {
        try {
            $active = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'git.exe'" -ErrorAction Stop | Where-Object { $_ -and $_.ProcessId })
        } catch {
            throw 'GIT_INDEX_LOCK_PREFLIGHT=FAIL reason=git_process_discovery_unavailable'
        }
        if ($active.Count -eq 0) { return }
        if ($WaitSeconds -le 0 -or (Get-Date) -ge $deadline) { break }
        if (-not $announced) {
            Write-Host "GIT_INDEX_LOCK_PREFLIGHT=WAIT reason=git_process_active count=$($active.Count) timeout_seconds=$WaitSeconds"
            $announced = $true
        }
        Start-Sleep -Seconds 3
    }
    $processes = @($active | ForEach-Object {
        $started = if ($_.CreationDate) { [int](([DateTime]::UtcNow - ([DateTime]$_.CreationDate).ToUniversalTime()).TotalSeconds) } else { -1 }
        "pid=$($_.ProcessId):age_seconds=$started"
    })
    throw "GIT_INDEX_LOCK_PREFLIGHT=FAIL reason=git_process_active count=$($active.Count) wait_seconds=$WaitSeconds process_age=$($processes -join ',')"
}
Assert-NoRunningGit -WaitSeconds 60
$handle = $null
try {
    $handle = [IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
} catch {
    throw 'GIT_INDEX_LOCK_PREFLIGHT=FAIL reason=lock_file_in_use'
} finally {
    if ($handle) { $handle.Dispose() }
}
$now = Get-Item -LiteralPath $lockPath -Force
if ($now.Length -ne $lock.Length -or $now.LastWriteTimeUtc -ne $lock.LastWriteTimeUtc) {
    throw 'GIT_INDEX_LOCK_PREFLIGHT=FAIL reason=lock_changed_during_check'
}
Assert-NoRunningGit
Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
if (Test-Path -LiteralPath $lockPath) {
    throw 'GIT_INDEX_LOCK_PREFLIGHT=FAIL reason=stale_lock_cleanup_unconfirmed'
}
Write-Host "GIT_INDEX_LOCK_PREFLIGHT=PASS state=stale_lock_recovered age_seconds=$([int]$age) no_git_processes=true exclusive_probe=true"
