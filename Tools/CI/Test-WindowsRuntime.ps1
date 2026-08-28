param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [Parameter(Mandatory=$true)][string]$WorkingDirectory,
  [Parameter(Mandatory=$true)][string]$EvidenceRoot,
  [Parameter(Mandatory=$true)][string]$Label,
  [int]$StabilitySeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $ExePath)) {
  throw "WINDOW_RUNTIME_PRECHECK=FAIL label=$Label missing_exe=$ExePath"
}
if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
  throw "WINDOW_RUNTIME_PRECHECK=FAIL label=$Label missing_workdir=$WorkingDirectory"
}
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('ArmyAttackWindowProbe' -as [type])) {
  Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class ArmyAttackWindowProbe
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsHungAppWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    public static IntPtr FindVisibleWindow(int processId)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid != (uint)processId || !IsWindowVisible(hWnd))
                return true;

            RECT r;
            if (!GetWindowRect(hWnd, out r))
                return true;

            if ((r.Right - r.Left) < 200 || (r.Bottom - r.Top) < 150)
                return true;

            found = hWnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static string WindowTitle(IntPtr hWnd)
    {
        StringBuilder sb = new StringBuilder(512);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }
}
"@
}

function Get-WindowRectObject([IntPtr]$Handle) {
  $rect = New-Object ArmyAttackWindowProbe+RECT
  if (-not [ArmyAttackWindowProbe]::GetWindowRect($Handle, [ref]$rect)) {
    throw "WINDOW_RECT=FAIL label=$Label handle=$Handle"
  }
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  [pscustomobject]@{
    Left = $rect.Left
    Top = $rect.Top
    Right = $rect.Right
    Bottom = $rect.Bottom
    Width = $width
    Height = $height
  }
}

function Capture-WindowEvidence([IntPtr]$Handle, [string]$Suffix) {
  $rect = Get-WindowRectObject $Handle
  if ($rect.Width -lt 640 -or $rect.Height -lt 480) {
    throw "WINDOW_RECT=FAIL label=$Label width=$($rect.Width) height=$($rect.Height)"
  }

  $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $left = [Math]::Max($rect.Left, $virtual.Left)
  $top = [Math]::Max($rect.Top, $virtual.Top)
  $right = [Math]::Min($rect.Right, $virtual.Right)
  $bottom = [Math]::Min($rect.Bottom, $virtual.Bottom)
  $width = $right - $left
  $height = $bottom - $top
  if ($width -lt 320 -or $height -lt 240) {
    throw "SCREENSHOT=FAIL label=$Label clipped_width=$width clipped_height=$height"
  }

  $safeLabel = ($Label -replace '[^A-Za-z0-9_.-]', '_')
  $shotPath = Join-Path $EvidenceRoot ("$safeLabel-$Suffix.png")
  $bmp = New-Object System.Drawing.Bitmap($width, $height)
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $gfx.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size($width, $height)))

    $unique = New-Object 'System.Collections.Generic.HashSet[int]'
    $values = New-Object 'System.Collections.Generic.List[double]'
    $sampleX = 32
    $sampleY = 18
    for ($yi = 0; $yi -lt $sampleY; $yi++) {
      $y = [Math]::Min($height - 1, [Math]::Floor(($yi + 0.5) * $height / $sampleY))
      for ($xi = 0; $xi -lt $sampleX; $xi++) {
        $x = [Math]::Min($width - 1, [Math]::Floor(($xi + 0.5) * $width / $sampleX))
        $color = $bmp.GetPixel([int]$x, [int]$y)
        [void]$unique.Add($color.ToArgb())
        $brightness = 0.2126 * $color.R + 0.7152 * $color.G + 0.0722 * $color.B
        $values.Add([double]$brightness)
      }
    }

    $mean = ($values | Measure-Object -Average).Average
    $sumSq = 0.0
    foreach ($v in $values) {
      $delta = $v - $mean
      $sumSq += $delta * $delta
    }
    $stddev = [Math]::Sqrt($sumSq / [Math]::Max(1, $values.Count))
    $bmp.Save($shotPath, [System.Drawing.Imaging.ImageFormat]::Png)
  }
  finally {
    $gfx.Dispose()
    $bmp.Dispose()
  }

  $shot = Get-Item -LiteralPath $shotPath
  $shotHash = (Get-FileHash -LiteralPath $shotPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $complexity = [Math]::Round($unique.Count * $stddev, 2)

  Write-Host "SCREENSHOT=PASS label=$Label phase=$Suffix path=$shotPath"
  Write-Host "SCREENSHOT_SIZE=$($shot.Length) label=$Label phase=$Suffix"
  Write-Host "SCREENSHOT_SHA256=$shotHash label=$Label phase=$Suffix"
  Write-Host "VISUAL_UNIQUE_COLORS=$($unique.Count) label=$Label phase=$Suffix"
  Write-Host ("VISUAL_BRIGHTNESS_STDDEV={0:N3} label={1} phase={2}" -f $stddev,$Label,$Suffix)
  Write-Host ("VISUAL_COMPLEXITY={0:N2} label={1} phase={2}" -f $complexity,$Label,$Suffix)

  if ($shot.Length -lt 4096 -or $unique.Count -lt 6 -or $stddev -lt 1.5) {
    throw "VISUAL_SMOKE=FAIL label=$Label phase=$Suffix size=$($shot.Length) unique=$($unique.Count) stddev=$stddev"
  }
  Write-Host "VISUAL_SMOKE=PASS label=$Label phase=$Suffix"

  [pscustomobject]@{
    Path = $shotPath
    Sha256 = $shotHash
    Size = $shot.Length
    UniqueColors = $unique.Count
    StdDev = $stddev
    Complexity = $complexity
    Width = $rect.Width
    Height = $rect.Height
  }
}

$launchTime = Get-Date
$proc = $null
$trackedPid = $null
$handle = [IntPtr]::Zero
try {
  $proc = Start-Process -FilePath $ExePath -WorkingDirectory $WorkingDirectory -PassThru
  $trackedPid = $proc.Id
  Write-Host "START_ATTEMPT=PASS label=$Label pid=$trackedPid exe=$ExePath"

  $deadline = (Get-Date).AddSeconds(20)
  do {
    Start-Sleep -Milliseconds 500
    $proc.Refresh()
    if ($proc.HasExited) {
      throw "START=FAIL label=$Label pid=$trackedPid exit=$($proc.ExitCode)"
    }
    $handle = [ArmyAttackWindowProbe]::FindVisibleWindow($trackedPid)
  } while ($handle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)

  if ($handle -eq [IntPtr]::Zero) {
    throw "WINDOW_HANDLE=FAIL label=$Label pid=$trackedPid no_visible_window_after_20s"
  }

  $title = [ArmyAttackWindowProbe]::WindowTitle($handle)
  $rect = Get-WindowRectObject $handle
  Write-Host "START=PASS label=$Label pid=$trackedPid"
  Write-Host "WINDOW_HANDLE=PASS label=$Label handle=$handle title=$title"
  Write-Host "WINDOW_RECT=PASS label=$Label left=$($rect.Left) top=$($rect.Top) width=$($rect.Width) height=$($rect.Height)"

  if ([ArmyAttackWindowProbe]::IsHungAppWindow($handle)) {
    throw "WINDOW_RESPONDING=FAIL label=$Label phase=initial"
  }
  Write-Host "WINDOW_RESPONDING=PASS label=$Label phase=initial"

  Start-Sleep -Seconds 3
  $initial = Capture-WindowEvidence $handle 'initial'

  $elapsed = 0
  while ($elapsed -lt $StabilitySeconds) {
    Start-Sleep -Seconds 5
    $elapsed += 5
    $proc.Refresh()
    if ($proc.HasExited) {
      throw "RUNTIME_STABILITY=FAIL label=$Label elapsed=$elapsed exit=$($proc.ExitCode)"
    }
    if ([ArmyAttackWindowProbe]::IsHungAppWindow($handle)) {
      throw "WINDOW_RESPONDING=FAIL label=$Label elapsed=$elapsed"
    }
    Write-Host "RUNTIME_SAMPLE=PASS label=$Label elapsed=$elapsed working_set=$($proc.WorkingSet64) cpu=$($proc.TotalProcessorTime.TotalMilliseconds)"
  }

  $final = Capture-WindowEvidence $handle 'final'
  $changed = $initial.Sha256 -ne $final.Sha256
  Write-Host "SCREENSHOT_CHANGED=$changed label=$Label"
  Write-Host "RUNTIME_STABILITY=PASS label=$Label seconds=$StabilitySeconds"
  Write-Host "WINDOW_RESPONDING=PASS label=$Label phase=final"

  $crashes = @()
  try {
    $exeName = [regex]::Escape([System.IO.Path]::GetFileName($ExePath))
    $crashes = @(Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$launchTime } -ErrorAction Stop |
      Where-Object {
        $_.ProviderName -in @('Application Error','Windows Error Reporting','Application Hang') -and
        $_.Message -match $exeName
      })
    if ($crashes.Count -gt 0) {
      foreach ($event in $crashes | Select-Object -First 10) {
        Write-Host "WINDOW_EVENT=$($event.ProviderName) id=$($event.Id) time=$($event.TimeCreated)"
      }
      throw "CRASH_CHECK=FAIL label=$Label events=$($crashes.Count)"
    }
    Write-Host "CRASH_CHECK=PASS label=$Label"
  }
  catch {
    if ($_.Exception.Message -like 'CRASH_CHECK=FAIL*') { throw }
    Write-Host "CRASH_CHECK=SKIPPED_WITH_REASON label=$Label reason=event_log_unavailable message=$($_.Exception.Message)"
  }

  Write-Host "WINDOW_RUNTIME_VALIDATION=PASS label=$Label"
}
finally {
  if ($trackedPid) {
    try { Stop-Process -Id $trackedPid -Force -ErrorAction SilentlyContinue } catch {}
  }
}
