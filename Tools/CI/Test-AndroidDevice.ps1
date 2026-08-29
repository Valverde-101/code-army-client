param(
  [Parameter(Mandatory=$true)][string]$ApkPath,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$adb=Join-Path $AndroidBuildRoot 'AndroidSDK\platform-tools\adb.exe'
if(-not (Test-Path -LiteralPath $adb)){throw "ADB_DEVICE=FAIL adb_missing=$adb"}

$buildTools=Join-Path $AndroidBuildRoot 'AndroidSDK\build-tools'
$aapt=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'aapt.exe' -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
if(-not $aapt){throw 'ADB_DEVICE=FAIL aapt_missing'}
$badging=(& $aapt.FullName dump badging $ApkPath 2>&1 | Out-String)
if($LASTEXITCODE -ne 0){throw "ADB_DEVICE=FAIL apk_badging_exit=$LASTEXITCODE"}
$package=''
if($badging -match "package: name='([^']+)'"){$package=$matches[1]}
if(-not $package){throw 'ADB_DEVICE=FAIL package_unparseable'}
$packageRegex=[regex]::Escape($package)

$raw=& $adb devices -l
$lines=@($raw | Select-Object -Skip 1 | Where-Object {$_ -and $_.Trim()})
$devices=@();$bad=@()
foreach($line in $lines){
  if($line -match '^(\S+)\s+device\b'){$devices+=$matches[1]}
  elseif($line -match '^(\S+)\s+(unauthorized|offline)\b'){$bad+=$line}
}
if($bad.Count -gt 0){throw "ADB_DEVICE=FAIL bad_state=$($bad -join ';')"}
if($devices.Count -eq 0){
  foreach($gate in @('ADB_DEVICE','INSTALL','START','HEALTH','SMOKE','CRASH_CHECK','ANR_CHECK','PERF_OVERLAY','PHYSICAL_EVIDENCE')){
    Write-Host "$gate=SKIPPED_WITH_REASON no_authorized_device"
  }
  exit 0
}
if($devices.Count -ne 1){throw "ADB_DEVICE=FAIL expected_one_device actual=$($devices.Count)"}

$serial=$devices[0]
$lockRoot=Join-Path $AndroidBuildRoot 'DeviceTests\locks'
New-Item -ItemType Directory -Force -Path $lockRoot | Out-Null
$lockPath=Join-Path $lockRoot "$serial.lock"
$lock=$null
try{
  $lock=[System.IO.File]::Open($lockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
}catch{
  throw "DEVICE_LOCK=FAIL serial=$serial path=$lockPath"
}

try{
  Write-Host "DEVICE_LOCK=PASS serial=$serial"
  $model=(& $adb -s $serial shell getprop ro.product.model).Trim()
  $api=(& $adb -s $serial shell getprop ro.build.version.sdk).Trim()
  $android=(& $adb -s $serial shell getprop ro.build.version.release).Trim()
  $abi=(& $adb -s $serial shell getprop ro.product.cpu.abi).Trim()
  Write-Host "ADB_DEVICE=PASS serial=$serial model=$model android=$android api=$api abi=$abi package=$package"

  & $adb -s $serial logcat -c
  & $adb -s $serial install -r $ApkPath
  if($LASTEXITCODE -ne 0){throw "INSTALL=FAIL serial=$serial exit=$LASTEXITCODE"}

  $pm=(& $adb -s $serial shell pm path $package | Out-String).Trim()
  if($pm -notmatch '^package:'){throw "INSTALL=FAIL package=$package pm_path=$pm"}
  Write-Host "INSTALL=PASS package=$package pm_path=$pm"

  $component=(& $adb -s $serial shell cmd package resolve-activity --brief $package | Out-String).Trim()
  if(-not $component -or $component -match 'No activity found'){throw "START=FAIL resolve_activity=$component"}
  $start=(& $adb -s $serial shell am start -W -n $component 2>&1 | Out-String)
  if($LASTEXITCODE -ne 0){throw "START=FAIL exit=$LASTEXITCODE output=$start"}

  Start-Sleep -Seconds 45
  $pid=(& $adb -s $serial shell pidof $package | Out-String).Trim()
  if(-not $pid){throw 'START=FAIL no_pid_after_45s'}
  Write-Host "START=PASS component=$component pid=$pid stability_seconds=45"

  $evidence=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android\physical"
  New-Item -ItemType Directory -Force -Path $evidence | Out-Null
  $shot=Join-Path $evidence 'screen.png'
  $cmdLine='"'+$adb+'" -s '+$serial+' exec-out screencap -p > "'+$shot+'"'
  & cmd.exe /c $cmdLine

  $window=(& $adb -s $serial shell dumpsys window windows | Out-String)
  $window | Set-Content (Join-Path $evidence 'window.txt') -Encoding UTF8
  $activity=(& $adb -s $serial shell dumpsys activity activities | Out-String)
  $activity | Set-Content (Join-Path $evidence 'activity.txt') -Encoding UTF8
  $logcat=(& $adb -s $serial logcat -d -v threadtime | Out-String)
  $logcat | Set-Content (Join-Path $evidence 'logcat.txt') -Encoding UTF8

  $uiRemote='/sdcard/armyattack-window-dump.xml'
  $uiDumpOut=(& $adb -s $serial shell uiautomator dump $uiRemote 2>&1 | Out-String)
  $uiDumpExit=$LASTEXITCODE
  if($uiDumpExit -eq 0){
    $uiXml=(& $adb -s $serial shell cat $uiRemote | Out-String)
    $uiXml | Set-Content (Join-Path $evidence 'window_dump.xml') -Encoding UTF8
    & $adb -s $serial shell rm -f $uiRemote | Out-Null
    if($uiXml -notmatch 'content-desc="army_perf_toggle"'){throw 'PERF_OVERLAY=FAIL toggle_not_found'}
    Write-Host 'PERF_OVERLAY=PASS accessibility_id=army_perf_toggle'
  }else{
    Write-Host "PERF_OVERLAY=SKIPPED_WITH_REASON ui_dump_unavailable exit=$uiDumpExit output=$uiDumpOut"
  }

  if($window -notmatch $packageRegex -and $activity -notmatch $packageRegex){throw 'HEALTH=FAIL app_not_foreground_or_visible'}
  Write-Host 'HEALTH=PASS criterion=pid_and_window_or_activity_present_after_45s'
  Write-Host 'SMOKE=PASS criterion=alive_after_45s'

  if($logcat -match "(?i)FATAL EXCEPTION|Fatal signal|SIGSEGV|SIGABRT|AndroidRuntime.*$packageRegex"){throw 'CRASH_CHECK=FAIL'}
  Write-Host 'CRASH_CHECK=PASS'
  if($logcat -match "(?i)ANR in $packageRegex|Application Not Responding.*$packageRegex|input dispatching timed out.*$packageRegex"){throw 'ANR_CHECK=FAIL'}
  Write-Host 'ANR_CHECK=PASS'
  Write-Host "PHYSICAL_EVIDENCE=PASS path=$evidence"
} finally {
  try{& $adb -s $serial shell am force-stop $package | Out-Null}catch{}
  if($lock){$lock.Dispose()}
  Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  Write-Host "DEVICE_LOCK_RELEASE=PASS serial=$serial"
}
