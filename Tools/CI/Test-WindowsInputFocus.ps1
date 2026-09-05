param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$candidateRoot = Join-Path $AndroidBuildRoot ("Builds\code-army-client\{0}\windows-full-candidate\ArmyAttack" -f $ExpectedSha)
$exePath = Join-Path $candidateRoot 'Army Attack.exe'
if (-not (Test-Path -LiteralPath $exePath)) {
  throw "INPUT_FOCUS_PRECHECK=FAIL missing_exe=$exePath"
}

Add-Type -AssemblyName System.Windows.Forms
if (-not ('ArmyAttackInputFocusProbe' -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class ArmyAttackInputFocusProbe
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool IsHungAppWindow(IntPtr hWnd);
}
"@
}

$proc = $null
try {
  $proc = Start-Process -FilePath $exePath -WorkingDirectory $candidateRoot -PassThru
  Write-Host "INPUT_FOCUS_START=PASS pid=$($proc.Id) exe=$exePath"

  $deadline = (Get-Date).AddSeconds(20)
  $main = [IntPtr]::Zero
  do {
    Start-Sleep -Milliseconds 400
    $proc.Refresh()
    if ($proc.HasExited) {
      throw "INPUT_FOCUS_START=FAIL process_exited=$($proc.ExitCode)"
    }
    if ($proc.MainWindowHandle -ne 0) {
      $main = [IntPtr]$proc.MainWindowHandle
      break
    }
  } while ((Get-Date) -lt $deadline)

  if ($main -eq [IntPtr]::Zero) {
    throw "INPUT_FOCUS_WINDOW=FAIL no_main_window_after_20s"
  }
  if ([ArmyAttackInputFocusProbe]::IsHungAppWindow($main)) {
    throw "INPUT_FOCUS_WINDOW=FAIL phase=pre_input hung=true"
  }

  $focused = $false
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    [void][ArmyAttackInputFocusProbe]::SetForegroundWindow($main)
    Start-Sleep -Milliseconds 300
    $foreground = [ArmyAttackInputFocusProbe]::GetForegroundWindow()
    $ownerPid = [uint32]0
    [void][ArmyAttackInputFocusProbe]::GetWindowThreadProcessId($foreground, [ref]$ownerPid)
    Write-Host "INPUT_FOCUS_SAMPLE attempt=$attempt foreground=$foreground owner_pid=$ownerPid expected_pid=$($proc.Id)"
    if ($ownerPid -eq [uint32]$proc.Id) {
      $focused = $true
      break
    }
    Start-Sleep -Milliseconds 300
  }

  if (-not $focused) {
    throw "INPUT_FOCUS=FAIL unable_to_focus_candidate pid=$($proc.Id)"
  }
  Write-Host "INPUT_FOCUS=PASS pid=$($proc.Id)"

  [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
  Start-Sleep -Milliseconds 800
  $proc.Refresh()
  if ($proc.HasExited) {
    throw "INPUT_TARGET=FAIL action=escape process_exited=$($proc.ExitCode)"
  }
  if ([ArmyAttackInputFocusProbe]::IsHungAppWindow($main)) {
    throw "INPUT_TARGET=FAIL action=escape hung=true"
  }

  $foreground = [ArmyAttackInputFocusProbe]::GetForegroundWindow()
  $ownerPid = [uint32]0
  [void][ArmyAttackInputFocusProbe]::GetWindowThreadProcessId($foreground, [ref]$ownerPid)
  if ($ownerPid -ne [uint32]$proc.Id) {
    throw "INPUT_TARGET=FAIL action=escape foreground_owner=$ownerPid expected_pid=$($proc.Id)"
  }

  [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
  Start-Sleep -Milliseconds 800
  $proc.Refresh()
  if ($proc.HasExited) {
    throw "INPUT_TARGET=FAIL action=escape_roundtrip process_exited=$($proc.ExitCode)"
  }
  if ([ArmyAttackInputFocusProbe]::IsHungAppWindow($main)) {
    throw "INPUT_TARGET=FAIL action=escape_roundtrip hung=true"
  }

  Write-Host "INPUT_TARGET=PASS action=escape_roundtrip owner_pid=$ownerPid"
  Write-Host "INPUT_FOCUS_VALIDATION=PASS"
}
finally {
  if ($null -ne $proc) {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
}
