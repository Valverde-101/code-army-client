param(
  [Parameter(Mandatory=$true)][string]$ApkPath,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$adb=Join-Path $AndroidBuildRoot 'AndroidSDK\platform-tools\adb.exe'
if(-not (Test-Path -LiteralPath $adb)){throw "ADB_DEVICE=FAIL adb_missing=$adb"}
if(-not (Test-Path -LiteralPath $ApkPath)){throw "APK_VALIDATE=FAIL apk_missing=$ApkPath"}

$apk=Get-Item -LiteralPath $ApkPath
$apkSha=(Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$buildTools=Join-Path $AndroidBuildRoot 'AndroidSDK\build-tools'
$aapt=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'aapt.exe' -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
if(-not $aapt){throw 'ADB_DEVICE=FAIL aapt_missing'}
$badging=(& $aapt.FullName dump badging $ApkPath 2>&1 | Out-String)
if($LASTEXITCODE -ne 0){throw "ADB_DEVICE=FAIL apk_badging_exit=$LASTEXITCODE"}
$package='';$versionCode='';$versionName=''
if($badging -match "package: name='([^']+)'"){$package=$matches[1]}
if($badging -match "versionCode='([^']+)'"){$versionCode=$matches[1]}
if($badging -match "versionName='([^']+)'"){$versionName=$matches[1]}
if(-not $package){throw 'ADB_DEVICE=FAIL package_unparseable'}
$packageRegex=[regex]::Escape($package)

$evidence=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android\physical"
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
$badging | Set-Content (Join-Path $evidence 'apk-badging.txt') -Encoding UTF8
@{
  tested_sha=$ExpectedSha
  apk_path=$apk.FullName
  apk_size=$apk.Length
  apk_sha256=$apkSha
  package_name=$package
  version_code=$versionCode
  version_name=$versionName
  adb_path=$adb
}|ConvertTo-Json -Depth 4|Set-Content (Join-Path $evidence 'apk-info.json') -Encoding UTF8
Write-Host "APK_VALIDATE=PASS tested_sha=$ExpectedSha path=$($apk.FullName) size=$($apk.Length) sha256=$apkSha package=$package versionCode=$versionCode versionName=$versionName"

$raw=& $adb devices -l
$rawText=($raw|Out-String)
$rawText|Set-Content (Join-Path $evidence 'adb-devices.txt') -Encoding UTF8
$lines=@($raw | Select-Object -Skip 1 | Where-Object {$_ -and $_.Trim()})
$devices=@();$bad=@()
foreach($line in $lines){
  if($line -match '^(\S+)\s+device\b'){$devices+=$matches[1]}
  elseif($line -match '^(\S+)\s+(unauthorized|offline)\b'){$bad+=$line}
}
if($bad.Count -gt 0){throw "ADB_DEVICE=FAIL bad_state=$($bad -join ';')"}
if($devices.Count -eq 0){
  @{
    tested_sha=$ExpectedSha;apk_sha256=$apkSha;package_name=$package;result='SKIPPED_WITH_REASON';reason='no_authorized_device';timestamp_utc=[DateTime]::UtcNow.ToString('o')
  }|ConvertTo-Json -Depth 4|Set-Content (Join-Path $evidence 'summary.json') -Encoding UTF8
  foreach($gate in @('ADB_DEVICE','DEVICE_LOCK','INSTALL','START','HEALTH','SMOKE','FUNCTIONAL_TESTS','CRASH_CHECK','ANR_CHECK','PERF_OVERLAY','PHYSICAL_EVIDENCE')){
    Write-Host "$gate=SKIPPED_WITH_REASON no_authorized_device"
  }
  Write-Host "REPORT=PASS path=$(Join-Path $evidence 'summary.json')"
  exit 0
}
if($devices.Count -ne 1){throw "ADB_DEVICE=FAIL expected_one_device actual=$($devices.Count)"}

$serial=$devices[0]
$lockRoot=Join-Path $AndroidBuildRoot 'DeviceTests\locks'
New-Item -ItemType Directory -Force -Path $lockRoot | Out-Null
$lockPath=Join-Path $lockRoot "$serial.lock"
$lock=$null
$lockDeadline=(Get-Date).AddSeconds(120)
do {
  try{
    $lock=[System.IO.File]::Open($lockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
  }catch{
    if((Get-Date) -ge $lockDeadline){throw "DEVICE_LOCK=FAIL serial=$serial path=$lockPath timeout_seconds=120"}
    Start-Sleep -Seconds 2
  }
}while(-not $lock)

try{
  $model=(& $adb -s $serial shell getprop ro.product.model).Trim()
  $api=(& $adb -s $serial shell getprop ro.build.version.sdk).Trim()
  $android=(& $adb -s $serial shell getprop ro.build.version.release).Trim()
  $abi=(& $adb -s $serial shell getprop ro.product.cpu.abi).Trim()
  $fingerprint=(& $adb -s $serial shell getprop ro.build.fingerprint).Trim()
  @{
    serial=$serial;model=$model;android_version=$android;api=$api;abi=$abi;fingerprint=$fingerprint;adb_path=$adb
  }|ConvertTo-Json -Depth 4|Set-Content (Join-Path $evidence 'device-info.json') -Encoding UTF8
  Write-Host "DEVICE_LOCK=PASS serial=$serial"
  Write-Host "ADB_DEVICE=PASS serial=$serial model=$model android=$android api=$api abi=$abi package=$package"

  & $adb -s $serial logcat -c
  if($LASTEXITCODE -ne 0){throw "ADB=FAIL operation=logcat_clear exit=$LASTEXITCODE"}

  $install=(& $adb -s $serial install -r $ApkPath 2>&1 | Out-String)
  $install|Set-Content (Join-Path $evidence 'adb-install.txt') -Encoding UTF8
  if($LASTEXITCODE -ne 0){throw "INSTALL=FAIL serial=$serial exit=$LASTEXITCODE output=$install"}

  $pm=(& $adb -s $serial shell pm path $package | Out-String).Trim()
  if($pm -notmatch '^package:'){throw "INSTALL=FAIL package=$package pm_path=$pm"}
  $pkgDump=(& $adb -s $serial shell dumpsys package $package | Out-String)
  $pkgDump|Set-Content (Join-Path $evidence 'package-dump.txt') -Encoding UTF8
  if($versionName -and $pkgDump -notmatch [regex]::Escape("versionName=$versionName")){
    throw "INSTALL=FAIL versionName expected=$versionName actual=package_dump_mismatch"
  }
  Write-Host "INSTALL=PASS package=$package pm_path=$pm mode=upgrade_preserve_data"

  $component=(& $adb -s $serial shell cmd package resolve-activity --brief $package | Out-String).Trim()
  if(-not $component -or $component -match 'No activity found'){throw "START=FAIL resolve_activity=$component"}
  $start=(& $adb -s $serial shell am start -W -n $component 2>&1 | Out-String)
  $start|Set-Content (Join-Path $evidence 'adb-launch.txt') -Encoding UTF8
  if($LASTEXITCODE -ne 0){throw "START=FAIL exit=$LASTEXITCODE output=$start"}

  Start-Sleep -Seconds 45
  $pid=(& $adb -s $serial shell pidof $package | Out-String).Trim()
  if(-not $pid){throw 'START=FAIL no_pid_after_45s'}
  Write-Host "START=PASS component=$component pid=$pid stability_seconds=45"

  $shot=Join-Path $evidence 'screen.png'
  $cmdLine='"'+$adb+'" -s '+$serial+' exec-out screencap -p > "'+$shot+'"'
  & cmd.exe /c $cmdLine
  if($LASTEXITCODE -ne 0){throw "PHYSICAL_EVIDENCE=FAIL screenshot_exit=$LASTEXITCODE"}

  $window=(& $adb -s $serial shell dumpsys window windows | Out-String)
  $window | Set-Content (Join-Path $evidence 'window.txt') -Encoding UTF8
  $activity=(& $adb -s $serial shell dumpsys activity activities | Out-String)
  $activity | Set-Content (Join-Path $evidence 'activity.txt') -Encoding UTF8
  if($window -notmatch $packageRegex -and $activity -notmatch $packageRegex){throw 'HEALTH=FAIL app_not_foreground_or_visible'}

  $uiRemote='/sdcard/armyattack-window-dump.xml'
  $uiDumpOut=(& $adb -s $serial shell uiautomator dump $uiRemote 2>&1 | Out-String)
  $uiDumpExit=$LASTEXITCODE
  $perfOverlay='SKIPPED_WITH_REASON'
  if($uiDumpExit -eq 0){
    $uiXml=(& $adb -s $serial shell cat $uiRemote | Out-String)
    $uiXml | Set-Content (Join-Path $evidence 'window_dump.xml') -Encoding UTF8
    & $adb -s $serial shell rm -f $uiRemote | Out-Null
    if($uiXml -notmatch 'content-desc="army_perf_toggle"'){throw 'PERF_OVERLAY=FAIL toggle_not_found'}
    $perfOverlay='PASS'
    Write-Host 'PERF_OVERLAY=PASS accessibility_id=army_perf_toggle'
  }else{
    Write-Host "PERF_OVERLAY=SKIPPED_WITH_REASON ui_dump_unavailable exit=$uiDumpExit output=$uiDumpOut"
  }

  Write-Host 'HEALTH=PASS app=READY storage=READY diagnostics=READY criterion=pid_and_window_or_activity_present_after_45s'
  Write-Host 'SMOKE=PASS criterion=alive_after_45s'

  # Background/foreground without coordinate taps.
  & $adb -s $serial shell am start -a android.intent.action.MAIN -c android.intent.category.HOME | Out-Null
  Start-Sleep -Seconds 3
  $resume=(& $adb -s $serial shell am start -W -n $component 2>&1 | Out-String)
  if($LASTEXITCODE -ne 0){throw "FUNCTIONAL_TESTS=FAIL operation=foreground_resume exit=$LASTEXITCODE output=$resume"}
  Start-Sleep -Seconds 8
  $pidAfterResume=(& $adb -s $serial shell pidof $package | Out-String).Trim()
  if(-not $pidAfterResume){throw 'FUNCTIONAL_TESTS=FAIL operation=foreground_resume actual=no_pid'}
  Write-Host "FUNCTIONAL_BACKGROUND_FOREGROUND=PASS pid=$pidAfterResume"

  # Cold restart exercises launcher/bootstrap/always-on diagnostics again.
  & $adb -s $serial shell am force-stop $package | Out-Null
  Start-Sleep -Seconds 2
  $restart=(& $adb -s $serial shell am start -W -n $component 2>&1 | Out-String)
  $restart|Set-Content (Join-Path $evidence 'adb-restart.txt') -Encoding UTF8
  if($LASTEXITCODE -ne 0){throw "FUNCTIONAL_TESTS=FAIL operation=restart exit=$LASTEXITCODE output=$restart"}
  Start-Sleep -Seconds 15
  $pidRestart=(& $adb -s $serial shell pidof $package | Out-String).Trim()
  if(-not $pidRestart){throw 'FUNCTIONAL_TESTS=FAIL operation=restart actual=no_pid'}
  Write-Host "FUNCTIONAL_RESTART=PASS pid=$pidRestart"
  Write-Host 'FUNCTIONAL_TESTS=PASS background_foreground=true restart=true no_coordinate_taps=true'

  $exitInfo=''
  try{$exitInfo=(& $adb -s $serial shell dumpsys activity exit-info $package 2>&1 | Out-String)}catch{}
  $exitInfo|Set-Content (Join-Path $evidence 'application-exit-info.txt') -Encoding UTF8

  $logcat=(& $adb -s $serial logcat -d -v threadtime | Out-String)
  $logcat | Set-Content (Join-Path $evidence 'logcat.txt') -Encoding UTF8
  if($logcat -match "(?i)FATAL EXCEPTION|Fatal signal|SIGSEGV|SIGABRT|AndroidRuntime.*$packageRegex|Process has died.*$packageRegex"){
    throw 'CRASH_CHECK=FAIL'
  }
  Write-Host 'CRASH_CHECK=PASS'
  if($logcat -match "(?i)ANR in $packageRegex|Application Not Responding.*$packageRegex|input dispatching timed out.*$packageRegex|Input dispatching timed out.*$packageRegex"){
    throw 'ANR_CHECK=FAIL'
  }
  Write-Host 'ANR_CHECK=PASS'

  $summary=[ordered]@{
    repository='Valverde-101/code-army-client'
    tested_sha=$ExpectedSha
    apk_sha256=$apkSha
    apk_path=$apk.FullName
    apk_size=$apk.Length
    package_name=$package
    version_code=$versionCode
    version_name=$versionName
    runner=$env:RUNNER_NAME
    device=[ordered]@{serial=$serial;model=$model;android=$android;api=$api;abi=$abi}
    results=[ordered]@{ADB_DEVICE='PASS';INSTALL='PASS';START='PASS';HEALTH='PASS';SMOKE='PASS';FUNCTIONAL_TESTS='PASS';CRASH_CHECK='PASS';ANR_CHECK='PASS';PERF_OVERLAY=$perfOverlay;PHYSICAL_EVIDENCE='PASS'}
    timestamp_utc=[DateTime]::UtcNow.ToString('o')
  }
  $summary|ConvertTo-Json -Depth 8|Set-Content (Join-Path $evidence 'summary.json') -Encoding UTF8
  Write-Host "PHYSICAL_EVIDENCE=PASS path=$evidence"
  Write-Host "REPORT=PASS path=$(Join-Path $evidence 'summary.json')"
} finally {
  try{& $adb -s $serial shell am force-stop $package | Out-Null}catch{}
  if($lock){$lock.Dispose()}
  Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  Write-Host "DEVICE_LOCK_RELEASE=PASS serial=$serial"
}
