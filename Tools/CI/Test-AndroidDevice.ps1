param(
  [Parameter(Mandatory=$true)][string]$ApkPath,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$adb=Join-Path $AndroidBuildRoot 'AndroidSDK\platform-tools\adb.exe'
if(-not (Test-Path $adb)){throw "ADB_DEVICE=FAIL adb_missing=$adb"}
$raw=& $adb devices -l
$lines=@($raw|Select-Object -Skip 1|Where-Object{$_ -and $_.Trim()})
$devices=@();$bad=@()
foreach($line in $lines){
  if($line -match '^(\S+)\s+device\b'){$devices+=$matches[1]}
  elseif($line -match '^(\S+)\s+(unauthorized|offline)\b'){$bad+=$line}
}
if($bad.Count -gt 0){throw "ADB_DEVICE=FAIL bad_state=$($bad -join ';')"}
if($devices.Count -eq 0){
  foreach($gate in @('ADB_DEVICE','INSTALL','START','HEALTH','SMOKE','CRASH_CHECK','ANR_CHECK','PHYSICAL_EVIDENCE')){Write-Host "$gate=SKIPPED_WITH_REASON no_authorized_device"}
  exit 0
}
if($devices.Count -ne 1){throw "ADB_DEVICE=FAIL expected_one_device actual=$($devices.Count)"}
$serial=$devices[0]
$lockRoot=Join-Path $AndroidBuildRoot 'DeviceTests\locks';New-Item -ItemType Directory -Force -Path $lockRoot|Out-Null
$lockPath=Join-Path $lockRoot "$serial.lock";$lock=$null
try{$lock=[System.IO.File]::Open($lockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)}catch{throw "DEVICE_LOCK=FAIL serial=$serial path=$lockPath"}
try{
  Write-Host "DEVICE_LOCK=PASS serial=$serial"
  $model=(& $adb -s $serial shell getprop ro.product.model).Trim();$api=(& $adb -s $serial shell getprop ro.build.version.sdk).Trim()
  $android=(& $adb -s $serial shell getprop ro.build.version.release).Trim();$abi=(& $adb -s $serial shell getprop ro.product.cpu.abi).Trim()
  Write-Host "ADB_DEVICE=PASS serial=$serial model=$model android=$android api=$api abi=$abi"
  & $adb -s $serial logcat -c
  & $adb -s $serial install -r $ApkPath
  if($LASTEXITCODE -ne 0){throw "INSTALL=FAIL serial=$serial exit=$LASTEXITCODE"}
  $pm=(& $adb -s $serial shell pm path army.attack|Out-String).Trim()
  if($pm -notmatch '^package:'){throw "INSTALL=FAIL pm_path=$pm"}
  Write-Host "INSTALL=PASS package=army.attack pm_path=$pm"
  $component=(& $adb -s $serial shell cmd package resolve-activity --brief army.attack|Out-String).Trim()
  if(-not $component -or $component -match 'No activity found'){throw "START=FAIL resolve_activity=$component"}
  $start=(& $adb -s $serial shell am start -W -n $component 2>&1|Out-String)
  if($LASTEXITCODE -ne 0){throw "START=FAIL exit=$LASTEXITCODE output=$start"}
  Start-Sleep -Seconds 12
  $pid=(& $adb -s $serial shell pidof army.attack|Out-String).Trim()
  if(-not $pid){throw 'START=FAIL no_pid'}
  Write-Host "START=PASS component=$component pid=$pid"
  $evidence=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android\physical";New-Item -ItemType Directory -Force -Path $evidence|Out-Null
  $shot=Join-Path $evidence 'screen.png'
  $cmdLine='"'+$adb+'" -s '+$serial+' exec-out screencap -p > "'+$shot+'"'
  & cmd.exe /c $cmdLine
  $window=(& $adb -s $serial shell dumpsys window windows|Out-String);$window|Set-Content (Join-Path $evidence 'window.txt') -Encoding UTF8
  $logcat=(& $adb -s $serial logcat -d -v threadtime|Out-String);$logcat|Set-Content (Join-Path $evidence 'logcat.txt') -Encoding UTF8
  if($window -notmatch 'army\.attack'){throw 'HEALTH=FAIL app_not_in_window_dump'}
  Write-Host 'HEALTH=PASS criterion=pid_and_window_present'
  Write-Host 'SMOKE=PASS criterion=alive_after_12s'
  if($logcat -match '(?i)FATAL EXCEPTION|Fatal signal|SIGSEGV|SIGABRT|AndroidRuntime.*army\.attack'){throw 'CRASH_CHECK=FAIL'}
  Write-Host 'CRASH_CHECK=PASS'
  if($logcat -match '(?i)ANR in army\.attack|Application Not Responding.*army\.attack|input dispatching timed out.*army\.attack'){throw 'ANR_CHECK=FAIL'}
  Write-Host 'ANR_CHECK=PASS'
  Write-Host "PHYSICAL_EVIDENCE=PASS path=$evidence"
} finally {
  try{& $adb -s $serial shell am force-stop army.attack|Out-Null}catch{}
  if($lock){$lock.Dispose()}
  Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  Write-Host "DEVICE_LOCK_RELEASE=PASS serial=$serial"
}
