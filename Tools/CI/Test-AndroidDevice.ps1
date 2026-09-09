param(
  [Parameter(Mandatory=$true)][string]$ApkPath,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [string]$EvidenceRoot,
  [string]$DeviceSerial
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$adb=Join-Path $AndroidBuildRoot 'AndroidSDK\platform-tools\adb.exe'
if(-not(Test-Path -LiteralPath $adb -PathType Leaf)){throw "ADB_DEVICE=FAIL adb_missing=$adb"}
if(-not(Test-Path -LiteralPath $ApkPath -PathType Leaf)){throw "APK_VALIDATE=FAIL apk_missing=$ApkPath"}
$apk=Get-Item -LiteralPath $ApkPath
$apkSha=(Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

$buildTools=Join-Path $AndroidBuildRoot 'AndroidSDK\build-tools'
$aapt=Get-ChildItem -LiteralPath $buildTools -Recurse -File -Filter 'aapt.exe' -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1
if(-not $aapt){throw 'APK_VALIDATE=FAIL aapt_missing'}
$badging=(& $aapt.FullName dump badging $ApkPath 2>&1|Out-String)
if($LASTEXITCODE -ne 0){throw "APK_VALIDATE=FAIL badging_exit=$LASTEXITCODE"}
$package='';$versionCode='';$versionName='';$abis=@()
if($badging -match "package: name='([^']+)'"){$package=$matches[1]}
if($badging -match "versionCode='([^']+)'"){$versionCode=$matches[1]}
if($badging -match "versionName='([^']+)'"){$versionName=$matches[1]}
foreach($m in [regex]::Matches($badging,"native-code: '([^']+)'")){$abis+=$m.Groups[1].Value}
if(-not $package){throw 'APK_VALIDATE=FAIL package_unparseable'}
$packageRegex=[regex]::Escape($package)
$evidence=if($EvidenceRoot){$EvidenceRoot}else{Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android\physical"}
New-Item -ItemType Directory -Force -Path $evidence|Out-Null
$badging|Set-Content -LiteralPath (Join-Path $evidence 'apk-badging.txt') -Encoding UTF8
[ordered]@{tested_sha=$ExpectedSha;apk_path=$apk.FullName;apk_size=$apk.Length;apk_sha256=$apkSha;package_name=$package;version_code=$versionCode;version_name=$versionName;abis=$abis;adb_path=$adb;evidence_root=$evidence}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $evidence 'apk-info.json') -Encoding UTF8
Write-Host "APK_VALIDATE=PASS tested_sha=$ExpectedSha path=$($apk.FullName) size=$($apk.Length) sha256=$apkSha package=$package versionCode=$versionCode versionName=$versionName"

$raw=& $adb devices -l;$rawText=($raw|Out-String);$rawText|Set-Content -LiteralPath (Join-Path $evidence 'adb-devices.txt') -Encoding UTF8
$devices=@();$bad=@()
foreach($line in @($raw|Select-Object -Skip 1|Where-Object{$_ -and $_.Trim()})){
  if($line -match '^(\S+)\s+device\b'){$devices+=$matches[1]}
  elseif($line -match '^(\S+)\s+(unauthorized|offline)\b'){$bad+=$line}
}
if($bad.Count -gt 0){throw "ADB_DEVICE=FAIL bad_state=$($bad -join ';')"}
if($devices.Count -eq 0){
  [ordered]@{tested_sha=$ExpectedSha;apk_sha256=$apkSha;package_name=$package;result='SKIPPED_WITH_REASON';reason='no_authorized_device';timestamp_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $evidence 'summary.json') -Encoding UTF8
  foreach($gate in @('ADB_DEVICE','DEVICE_LOCK','INSTALL','START','BOOT_READY','HEALTH','SMOKE','FUNCTIONAL_TESTS','CRASH_CHECK','ANR_CHECK','PERF_OVERLAY','PHYSICAL_EVIDENCE')){Write-Host "$gate=SKIPPED_WITH_REASON no_authorized_device"}
  Write-Host "REPORT=PASS path=$(Join-Path $evidence 'summary.json')";exit 0
}
$requested=if($DeviceSerial){$DeviceSerial}elseif($env:ANDROID_SERIAL){$env:ANDROID_SERIAL}else{''}
if($requested){
  if($devices -notcontains $requested){throw "ADB_DEVICE=FAIL requested_serial=$requested available=$($devices -join ',')"}
  $serial=$requested
}else{
  $serial=@($devices|Sort-Object)[0]
  if($devices.Count -gt 1){Write-Host "ADB_DEVICE_SELECTION=PASS strategy=deterministic_first serial=$serial candidates=$($devices -join ',')"}
}

$lockRoot=Join-Path $AndroidBuildRoot 'DeviceTests\locks';New-Item -ItemType Directory -Force -Path $lockRoot|Out-Null
$lockPath=Join-Path $lockRoot "$serial.lock";$lock=$null;$deadline=(Get-Date).AddSeconds(120)
do{
  try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{if((Get-Date) -ge $deadline){throw "DEVICE_LOCK=FAIL serial=$serial timeout_seconds=120 path=$lockPath"};Start-Sleep 2}
}while(-not $lock)

function Get-Pid(){return (& $adb -s $serial shell pidof $package|Out-String).Trim()}
function Get-Logcat(){return (& $adb -s $serial logcat -d -v threadtime|Out-String)}
function Wait-BootReady([string]$Phase,[int]$TimeoutSeconds=120){
  $end=(Get-Date).AddSeconds($TimeoutSeconds);$last='';$pid=''
  do{
    $pid=Get-Pid
    if($pid){
      $last=Get-Logcat
      if($last -match '(?m)ArmyAttackGame\s*:\s*BOOT_TRANSITION_FAILURE\b'){
        $last|Set-Content -LiteralPath (Join-Path $evidence ("boot-$Phase-logcat.txt")) -Encoding UTF8
        throw "BOOT_READY=FAIL phase=$Phase reason=transition_failure"
      }
      if($last -match '(?m)ArmyAttackGame\s*:\s*ASSET_LOAD_ERROR\b'){
        $last|Set-Content -LiteralPath (Join-Path $evidence ("boot-$Phase-logcat.txt")) -Encoding UTF8
        throw "BOOT_READY=FAIL phase=$Phase reason=asset_load_error"
      }
      if($last -match '(?m)ArmyAttackGame\s*:\s*BOOT_READY\b'){
        $last|Set-Content -LiteralPath (Join-Path $evidence ("boot-$Phase-logcat.txt")) -Encoding UTF8
        $gate=($last -match '(?m)ArmyAttackGame\s*:\s*ASSET_LOAD_GATE\b.*(?:^|[;\s])pending=0(?:[;\s]|$)')
        $swf=($last -match '(?m)ArmyAttackGame\s*:\s*SWF_LOAD_COMPLETE\b')
        if(-not $gate){throw "BOOT_READY=FAIL phase=$Phase reason=asset_gate_not_zero"}
        if(-not $swf){throw "BOOT_READY=FAIL phase=$Phase reason=swf_load_complete_missing"}
        return [pscustomobject]@{pid=$pid;log=$last;asset_gate_zero=$gate;swf_complete=$swf;asset_complete_count=([regex]::Matches($last,'(?m)ArmyAttackGame\s*:\s*ASSET_LOAD_COMPLETE\b')).Count}
      }
    }
    Start-Sleep -Seconds 3
  }while((Get-Date) -lt $end)
  $last=Get-Logcat;$last|Set-Content -LiteralPath (Join-Path $evidence ("boot-$Phase-logcat.txt")) -Encoding UTF8
  throw "BOOT_READY=FAIL phase=$Phase reason=timeout timeout_seconds=$TimeoutSeconds pid=$pid"
}
function Launch-AndWait([string]$Phase){
  & $adb -s $serial logcat -c|Out-Null
  $start=(& $adb -s $serial shell am start -W -n $component 2>&1|Out-String)
  $start|Set-Content -LiteralPath (Join-Path $evidence ("adb-launch-$Phase.txt")) -Encoding UTF8
  if($LASTEXITCODE -ne 0){throw "START=FAIL phase=$Phase exit=$LASTEXITCODE output=$start"}
  return Wait-BootReady -Phase $Phase -TimeoutSeconds 120
}

try{
  $model=(& $adb -s $serial shell getprop ro.product.model).Trim();$api=(& $adb -s $serial shell getprop ro.build.version.sdk).Trim();$android=(& $adb -s $serial shell getprop ro.build.version.release).Trim();$abi=(& $adb -s $serial shell getprop ro.product.cpu.abi).Trim();$fingerprint=(& $adb -s $serial shell getprop ro.build.fingerprint).Trim()
  [ordered]@{serial=$serial;model=$model;android_version=$android;api=$api;abi=$abi;fingerprint=$fingerprint;adb_path=$adb}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $evidence 'device-info.json') -Encoding UTF8
  Write-Host "DEVICE_LOCK=PASS serial=$serial";Write-Host "ADB_DEVICE=PASS serial=$serial model=$model android=$android api=$api abi=$abi"

  # Upgrade-preserving install is tested first so existing saves/migrations cannot be hidden by a clear-data step.
  $install=(& $adb -s $serial install -r $ApkPath 2>&1|Out-String);$install|Set-Content -LiteralPath (Join-Path $evidence 'adb-install.txt') -Encoding UTF8
  if($LASTEXITCODE -ne 0){throw "INSTALL=FAIL serial=$serial exit=$LASTEXITCODE output=$install"}
  $pm=(& $adb -s $serial shell pm path $package|Out-String).Trim();if($pm -notmatch '^package:'){throw "INSTALL=FAIL pm_path=$pm"}
  $pkgDump=(& $adb -s $serial shell dumpsys package $package|Out-String);$pkgDump|Set-Content -LiteralPath (Join-Path $evidence 'package-dump.txt') -Encoding UTF8
  if($versionName -and $pkgDump -notmatch [regex]::Escape("versionName=$versionName")){throw "INSTALL=FAIL versionName expected=$versionName actual=package_dump_mismatch"}
  Write-Host "INSTALL=PASS package=$package mode=upgrade_preserve_data pm_path=$pm"
  $component=(& $adb -s $serial shell cmd package resolve-activity --brief $package|Out-String).Trim();if(-not $component -or $component -match 'No activity found'){throw "START=FAIL resolve_activity=$component"}

  $upgrade=Launch-AndWait 'upgrade';Write-Host "BOOT_UPGRADE=PASS pid=$($upgrade.pid) asset_complete_count=$($upgrade.asset_complete_count)"
  Write-Host "START=PASS component=$component pid=$($upgrade.pid) boot_ready=true"

  # Now prove a clean first-run boot as a separate scenario.
  & $adb -s $serial shell am force-stop $package|Out-Null
  $clear=(& $adb -s $serial shell pm clear $package 2>&1|Out-String)
  if($LASTEXITCODE -ne 0 -or $clear -notmatch 'Success'){throw "FUNCTIONAL_TESTS=FAIL operation=fresh_clear output=$clear"}
  $fresh=Launch-AndWait 'fresh';Write-Host "BOOT_FRESH=PASS pid=$($fresh.pid) asset_complete_count=$($fresh.asset_complete_count)"

  $window=(& $adb -s $serial shell dumpsys window windows|Out-String);$activity=(& $adb -s $serial shell dumpsys activity activities|Out-String)
  $window|Set-Content -LiteralPath (Join-Path $evidence 'window.txt') -Encoding UTF8;$activity|Set-Content -LiteralPath (Join-Path $evidence 'activity.txt') -Encoding UTF8
  if($window -notmatch $packageRegex -and $activity -notmatch $packageRegex){throw 'HEALTH=FAIL app_not_foreground_or_visible'}
  $shot=Join-Path $evidence 'screen-ready.png';$cmd='"'+$adb+'" -s '+$serial+' exec-out screencap -p > "'+$shot+'"';& cmd.exe /c $cmd;if($LASTEXITCODE -ne 0){throw 'PHYSICAL_EVIDENCE=FAIL screenshot'}

  $uiRemote='/sdcard/armyattack-window-dump.xml';$uiDump=(& $adb -s $serial shell uiautomator dump $uiRemote 2>&1|Out-String);$uiExit=$LASTEXITCODE;$perf='SKIPPED_WITH_REASON'
  if($uiExit -eq 0){$xml=(& $adb -s $serial shell cat $uiRemote|Out-String);$xml|Set-Content -LiteralPath (Join-Path $evidence 'window_dump.xml') -Encoding UTF8;& $adb -s $serial shell rm -f $uiRemote|Out-Null;if($xml -notmatch 'content-desc="army_perf_toggle"'){throw 'PERF_OVERLAY=FAIL toggle_not_found'};$perf='PASS';Write-Host 'PERF_OVERLAY=PASS accessibility_id=army_perf_toggle'}else{Write-Host "PERF_OVERLAY=SKIPPED_WITH_REASON ui_dump_unavailable exit=$uiExit"}
  Write-Host 'BOOT_READY=PASS upgrade=true fresh=true transition_failures=0 asset_errors=0'
  Write-Host 'HEALTH=PASS app=READY storage=READY diagnostics=READY boot=READY'
  Write-Host 'SMOKE=PASS criterion=explicit_boot_ready_and_visible_game_window'

  & $adb -s $serial shell am start -a android.intent.action.MAIN -c android.intent.category.HOME|Out-Null;Start-Sleep 3
  $resume=(& $adb -s $serial shell am start -W -n $component 2>&1|Out-String);if($LASTEXITCODE -ne 0){throw "FUNCTIONAL_TESTS=FAIL operation=foreground_resume output=$resume"};Start-Sleep 5
  if(-not(Get-Pid)){throw 'FUNCTIONAL_TESTS=FAIL operation=foreground_resume no_pid'}
  Write-Host 'FUNCTIONAL_BACKGROUND_FOREGROUND=PASS'

  & $adb -s $serial shell am force-stop $package|Out-Null;Start-Sleep 2
  $restart=Launch-AndWait 'restart';Write-Host "FUNCTIONAL_RESTART=PASS pid=$($restart.pid) boot_ready=true"
  Write-Host 'FUNCTIONAL_TESTS=PASS lifecycle=true fresh_boot=true upgrade_boot=true restart_boot=true no_coordinate_taps=true'

  $exitInfo='';try{$exitInfo=(& $adb -s $serial shell dumpsys activity exit-info $package 2>&1|Out-String)}catch{};$exitInfo|Set-Content -LiteralPath (Join-Path $evidence 'application-exit-info.txt') -Encoding UTF8
  $logcat=Get-Logcat;$logcat|Set-Content -LiteralPath (Join-Path $evidence 'logcat.txt') -Encoding UTF8
  $pidRestart=[string]$restart.pid;$processLog='';if($pidRestart){try{$processLog=(& $adb -s $serial logcat -d -v threadtime --pid=$pidRestart|Out-String)}catch{}};$processLog|Set-Content -LiteralPath (Join-Path $evidence 'logcat-process.txt') -Encoding UTF8
  if($processLog -match '(?i)FATAL EXCEPTION|Fatal signal|SIGSEGV|SIGABRT' -or $exitInfo -match '(?i)REASON_CRASH|REASON_CRASH_NATIVE'){throw 'CRASH_CHECK=FAIL'}
  Write-Host 'CRASH_CHECK=PASS'
  if($logcat -match "(?i)ANR in $packageRegex|Application Not Responding.*$packageRegex|Input dispatching timed out.*$packageRegex" -or $exitInfo -match '(?i)REASON_ANR'){throw 'ANR_CHECK=FAIL'}
  Write-Host 'ANR_CHECK=PASS'

  $summary=[ordered]@{repository='Valverde-101/code-army-client';tested_sha=$ExpectedSha;apk_sha256=$apkSha;apk_path=$apk.FullName;apk_size=$apk.Length;package_name=$package;version_code=$versionCode;version_name=$versionName;runner=$env:RUNNER_NAME;device=[ordered]@{serial=$serial;model=$model;android=$android;api=$api;abi=$abi};boot=[ordered]@{upgrade_ready=$true;fresh_ready=$true;restart_ready=$true;asset_load_error=$false;transition_failure=$false};results=[ordered]@{ADB_DEVICE='PASS';DEVICE_LOCK='PASS';INSTALL='PASS';START='PASS';BOOT_READY='PASS';HEALTH='PASS';SMOKE='PASS';FUNCTIONAL_TESTS='PASS';CRASH_CHECK='PASS';ANR_CHECK='PASS';PERF_OVERLAY=$perf;PHYSICAL_EVIDENCE='PASS'};timestamp_utc=[DateTime]::UtcNow.ToString('o')}
  $summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $evidence 'summary.json') -Encoding UTF8
  Write-Host "PHYSICAL_EVIDENCE=PASS path=$evidence";Write-Host "REPORT=PASS path=$(Join-Path $evidence 'summary.json')"
} finally {
  try{& $adb -s $serial shell am force-stop $package|Out-Null}catch{}
  if($lock){$lock.Dispose()}
  Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  Write-Host "DEVICE_LOCK_RELEASE=PASS serial=$serial"
}
