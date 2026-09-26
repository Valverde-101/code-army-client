param(
  [Parameter(Mandatory=$true)][string]$EvidenceRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$ExpectedApkSha256,
  [string]$AndroidBuildRoot=$env:ANDROIDBUILD_ROOT
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if([string]::IsNullOrWhiteSpace($AndroidBuildRoot)){throw 'TARGETED_REGRESSION=FAIL component=TOOLCHAIN operation=resolve_androidbuild_root actual=empty'}
$adb=Join-Path $AndroidBuildRoot 'AndroidSDK\platform-tools\adb.exe'
if(-not(Test-Path -LiteralPath $adb -PathType Leaf)){throw "TARGETED_REGRESSION=FAIL component=ADB operation=resolve_portable_adb expected=$adb actual=missing"}
if(-not(Test-Path -LiteralPath $EvidenceRoot -PathType Container)){throw "TARGETED_REGRESSION=FAIL component=TEST operation=resolve_evidence_root expected=$EvidenceRoot actual=missing"}

$summaryPath=Join-Path $EvidenceRoot 'summary.json'
$apkInfoPath=Join-Path $EvidenceRoot 'apk-info.json'
foreach($required in @($summaryPath,$apkInfoPath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "TARGETED_REGRESSION=FAIL component=TEST operation=load_physical_identity expected=$required actual=missing"}}
$summary=Get-Content -LiteralPath $summaryPath -Raw|ConvertFrom-Json
$apkInfo=Get-Content -LiteralPath $apkInfoPath -Raw|ConvertFrom-Json
$expectedApk=$ExpectedApkSha256.ToLowerInvariant()
if([string]$summary.tested_sha -ne $ExpectedSha){throw "TARGETED_REGRESSION=FAIL component=TEST operation=exact_tested_sha expected=$ExpectedSha actual=$($summary.tested_sha)"}
if(([string]$summary.apk_sha256).ToLowerInvariant() -ne $expectedApk){throw "TARGETED_REGRESSION=FAIL component=APK operation=exact_apk_hash expected=$expectedApk actual=$($summary.apk_sha256)"}
if(([string]$apkInfo.apk_sha256).ToLowerInvariant() -ne $expectedApk){throw "TARGETED_REGRESSION=FAIL component=APK operation=apk_info_hash expected=$expectedApk actual=$($apkInfo.apk_sha256)"}
$serial=[string]$summary.device.serial
$package=[string]$apkInfo.package_name
if([string]::IsNullOrWhiteSpace($serial) -or [string]::IsNullOrWhiteSpace($package)){throw "TARGETED_REGRESSION=FAIL component=TEST operation=physical_identity serial=$serial package=$package"}
$state=(& $adb -s $serial get-state 2>&1|Out-String).Trim()
if($LASTEXITCODE -ne 0 -or $state -ne 'device'){throw "TARGETED_REGRESSION=FAIL component=ADB operation=get_state expected=device actual=$state"}
$pm=(& $adb -s $serial shell pm path $package 2>&1|Out-String).Trim()
if($LASTEXITCODE -ne 0 -or $pm -notmatch '^package:'){throw "TARGETED_REGRESSION=FAIL component=INSTALL operation=pm_path package=$package actual=$pm"}
$component=(& $adb -s $serial shell cmd package resolve-activity --brief $package 2>&1|Out-String).Trim()
if($LASTEXITCODE -ne 0 -or -not $component -or $component -match 'No activity found'){throw "TARGETED_REGRESSION=FAIL component=START operation=resolve_activity actual=$component"}

$lockRoot=Join-Path $AndroidBuildRoot 'DeviceTests\locks'
New-Item -ItemType Directory -Force -Path $lockRoot|Out-Null
$lockPath=Join-Path $lockRoot "$serial.lock"
$lock=$null
$deadline=(Get-Date).AddSeconds(120)
do{
  try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
  catch{if((Get-Date) -ge $deadline){throw "TARGETED_REGRESSION=FAIL component=DEVICE operation=device_lock serial=$serial timeout_seconds=120 path=$lockPath"};Start-Sleep -Seconds 2}
}while(-not $lock)

$action="$package.TEST_COMMAND"
function Get-Logcat(){return (& $adb -s $serial logcat -d -v threadtime|Out-String)}
function Wait-LogPattern([string]$Pattern,[string]$Gate,[int]$TimeoutSeconds=60){
  $end=(Get-Date).AddSeconds($TimeoutSeconds)
  do{
    $log=Get-Logcat
    if($log -match $Pattern){return $log}
    if($log -match '(?m)ArmyAttackGame\s*:\s*(?:GAME_UNCAUGHT|SWF_UNCAUGHT|MAP_TRANSITION_FAIL)\b' -or $log -match '(?i)Error #1009|TypeError:\s*Error #1009|Cannot access a property or method of a null object reference'){
      $log|Set-Content -LiteralPath (Join-Path $EvidenceRoot 'targeted-regression-logcat.txt') -Encoding UTF8
      throw "$Gate=FAIL reason=runtime_failure_before_expected_marker"
    }
    Start-Sleep -Seconds 2
  }while((Get-Date) -lt $end)
  $log=Get-Logcat
  $log|Set-Content -LiteralPath (Join-Path $EvidenceRoot 'targeted-regression-logcat.txt') -Encoding UTF8
  throw "$Gate=FAIL reason=timeout pattern=$Pattern timeout_seconds=$TimeoutSeconds"
}
function Save-Screenshot([string]$Name){
  $path=Join-Path $EvidenceRoot $Name
  $cmd='"'+$adb+'" -s '+$serial+' exec-out screencap -p > "'+$path+'"'
  & cmd.exe /c $cmd
  if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -lt 1024){
    throw "PHYSICAL_EVIDENCE=FAIL operation=screenshot name=$Name exit=$LASTEXITCODE"
  }
  return $path
}
function Invoke-TestCommand([string]$Command,[string]$Arg='',[string]$ExpectedResult='',[int]$TimeoutSeconds=45){
  $escaped=[regex]::Escape($Command)
  $before=Get-Logcat
  $pattern="(?m)ArmyAttackGame\s*:\s*TEST_COMMAND_RESULT\b.*command=$escaped;result=([^\r\n]+)"
  $beforeCount=[regex]::Matches($before,$pattern).Count
  $args=@('-s',$serial,'shell','am','broadcast','-a',$action,'-p',$package,'--es','command',$Command)
  if(-not [string]::IsNullOrWhiteSpace($Arg)){$args+=@('--es','arg',$Arg)}
  $out=(& $adb @args 2>&1|Out-String)
  $out|Add-Content -LiteralPath (Join-Path $EvidenceRoot 'adb-test-commands.txt') -Encoding UTF8
  if($LASTEXITCODE -ne 0){throw "TEST_CONSOLE=FAIL command=$Command exit=$LASTEXITCODE output=$out"}
  $end=(Get-Date).AddSeconds($TimeoutSeconds)
  do{
    $log=Get-Logcat
    $matches=[regex]::Matches($log,$pattern)
    if($matches.Count -gt $beforeCount){
      $line=$matches[$matches.Count-1].Groups[1].Value
      if($ExpectedResult -and $line -notmatch $ExpectedResult){throw "TEST_CONSOLE=FAIL command=$Command expected_result=$ExpectedResult actual=$line"}
      return $line
    }
    if($log -match "(?m)ArmyAttackGame\s*:\s*TEST_COMMAND_FAIL\b.*command=$escaped"){
      throw "TEST_CONSOLE=FAIL command=$Command reason=runtime_command_failure"
    }
    Start-Sleep -Milliseconds 750
  }while((Get-Date) -lt $end)
  throw "TEST_CONSOLE=FAIL command=$Command reason=result_timeout timeout_seconds=$TimeoutSeconds"
}
function Wait-MapCommit([string]$Target,[int]$TimeoutSeconds=75){
  $escaped=[regex]::Escape($Target)
  $pattern="(?m)ArmyAttackGame\s*:\s*MAP_SWITCH_COMMIT\b.*(?:^|;)to=$escaped(?:;|\s|$)"
  [void](Wait-LogPattern -Pattern $pattern -Gate 'MAP_TRANSITION_TEST' -TimeoutSeconds $TimeoutSeconds)
  [void](Invoke-TestCommand -Command 'health' -ExpectedResult ("READY:map_"+$escaped+"_state_") -TimeoutSeconds 20)
}
function Assert-TerritoryCommit([string]$SourcePattern,[string]$Gate){
  $pattern="(?m)ArmyAttackGame\s*:\s*TERRITORY_TOPOLOGY_COMMIT\b.*result=PASS.*source=$SourcePattern.*visual_commit=full"
  [void](Wait-LogPattern -Pattern $pattern -Gate $Gate -TimeoutSeconds 30)
}

try{
  & $adb -s $serial logcat -c|Out-Null
  $launch=(& $adb -s $serial shell am start -W -n $component 2>&1|Out-String)
  $launch|Set-Content -LiteralPath (Join-Path $EvidenceRoot 'adb-launch-targeted.txt') -Encoding UTF8
  if($LASTEXITCODE -ne 0){throw "TARGETED_REGRESSION=FAIL component=START operation=launch exit=$LASTEXITCODE output=$launch"}
  [void](Wait-LogPattern -Pattern '(?m)ArmyAttackGame\s*:\s*BOOT_READY\b' -Gate 'TARGETED_BOOT' -TimeoutSeconds 120)
  [void](Wait-LogPattern -Pattern '(?m)ArmyAttackGame\s*:\s*TEST_CONSOLE_(?:READY|AS3_READY)\b' -Gate 'TEST_CONSOLE' -TimeoutSeconds 45)
  Assert-TerritoryCommit -SourcePattern 'boot_restore:[^;\s]+' -Gate 'TERRITORY_RESTORE_TOPOLOGY'

  $territoryShot=Save-Screenshot 'screen-territory-boot-restore-before-capture.png'
  $initialHealth=Invoke-TestCommand -Command 'health' -ExpectedResult '^READY:map_[A-Za-z0-9]+_state_' -TimeoutSeconds 20
  $initialMap=''
  if($initialHealth -match '^READY:map_([A-Za-z0-9]+)_state_'){$initialMap=$matches[1]}
  if($initialMap -ne 'Home'){
    [void](Invoke-TestCommand -Command 'open_map' -Arg 'Home' -ExpectedResult '^ACCEPTED:map_Home$')
    Wait-MapCommit -Target 'Home'
    Assert-TerritoryCommit -SourcePattern 'switch:Home' -Gate 'TERRITORY_MAP_SWITCH'
  }
  $homeShot=Save-Screenshot 'screen-territory-home-before-capture.png'
  # TEST_COMMAND_RESULT sanitizes '=' and ';' to '_' before writing logcat.\n  # Exact-APK God Mode regression uses the protected native ADB command console:
  # no coordinate taps and no fabricated campaign/inventory state.
  [void](Invoke-TestCommand -Command 'god_mode' -Arg 'status' -ExpectedResult '^READY:god_mode_OFF_map_Home$')
  $godOffShot=Save-Screenshot 'screen-god-mode-off-before.png'
  [void](Invoke-TestCommand -Command 'god_mode' -Arg 'on' -ExpectedResult '^READY:god_mode_ON_map_Home$')
  $godOnShot=Save-Screenshot 'screen-god-mode-on-home.png'
  [void](Invoke-TestCommand -Command 'god_shop' -ExpectedResult '^ACCEPTED:shop_Units$')
  [void](Wait-LogPattern -Pattern '(?m)ArmyAttackGame\s*:\s*GOD_MODE_SHOP\b.*units=15;catalogue=PlayerUnit' -Gate 'GOD_MODE_ALL_TROOPS' -TimeoutSeconds 45)
  $godShopShot=Save-Screenshot 'screen-god-mode-shop-all-15.png'
  [void](Invoke-TestCommand -Command 'god_shop_close' -ExpectedResult '^ACCEPTED:shop_closed$')
  $shopCloseLog=Get-Logcat
  if($shopCloseLog -match '(?m)ArmyAttackGame\s*:\s*POPUP_CLOSE_MISSING\b.*ShopDialog'){throw 'GOD_MODE_SHOP_CLOSE=FAIL popup_not_active'}
  Write-Host 'GOD_MODE_ALL_TROOPS=PASS runtime_catalogue=15 shop=Units screenshot=true no_coordinate_taps=true'

  [void](Invoke-TestCommand -Command 'open_map' -Arg 'Snow' -ExpectedResult '^ACCEPTED:map_Snow$')
  Wait-MapCommit -Target 'Snow'
  Assert-TerritoryCommit -SourcePattern 'switch:Snow' -Gate 'TERRITORY_MAP_SWITCH'
  [void](Invoke-TestCommand -Command 'god_mode' -Arg 'status' -ExpectedResult '^READY:god_mode_ON_map_Snow$')
  $snowFirstShot=Save-Screenshot 'screen-snow-first-entry.png'
  $firstLog=Get-Logcat
  if($firstLog -match '(?m)ArmyAttackGame\s*:\s*MAP_TRANSITION_FAIL\b' -or $firstLog -match '(?i)Error #1009|TypeError:\s*Error #1009|Cannot access a property or method of a null object reference'){
    throw 'SNOW_FIRST_ENTRY=FAIL reason=transition_or_null_reference'
  }
  Write-Host 'SNOW_FIRST_ENTRY=PASS map=Snow transition_commit=true health=READY null_reference=0'

  [void](Invoke-TestCommand -Command 'open_map' -Arg 'Home' -ExpectedResult '^ACCEPTED:map_Home$')
  Wait-MapCommit -Target 'Home'
  [void](Invoke-TestCommand -Command 'open_map' -Arg 'Snow' -ExpectedResult '^ACCEPTED:map_Snow$')
  Wait-MapCommit -Target 'Snow'
  Assert-TerritoryCommit -SourcePattern 'switch:Snow' -Gate 'TERRITORY_MAP_SWITCH'
  $snowRepeatShot=Save-Screenshot 'screen-snow-repeat-entry.png'

  [void](Invoke-TestCommand -Command 'open_map' -Arg 'Home' -ExpectedResult '^ACCEPTED:map_Home$')
  Wait-MapCommit -Target 'Home'
  [void](Invoke-TestCommand -Command 'god_mode' -Arg 'status' -ExpectedResult '^READY:god_mode_ON_map_Home$')
  [void](Invoke-TestCommand -Command 'god_mode' -Arg 'off' -ExpectedResult '^READY:god_mode_OFF_map_Home$')
  $godRestoredShot=Save-Screenshot 'screen-god-mode-off-restored.png'
  $finalLog=Get-Logcat
  if($finalLog -notmatch '(?m)ArmyAttackGame\s*:\s*GOD_MODE\b.*enabled=true' -or $finalLog -notmatch '(?m)ArmyAttackGame\s*:\s*GOD_MODE\b.*enabled=false'){throw 'GOD_MODE_TOGGLE=FAIL transition_trace_missing'}
  $finalLog|Set-Content -LiteralPath (Join-Path $EvidenceRoot 'targeted-regression-logcat.txt') -Encoding UTF8

  $fatal='(?i)FATAL EXCEPTION|AndroidRuntime.*FATAL|Fatal signal|SIGSEGV|SIGABRT'
  $anr="(?i)ANR in $([regex]::Escape($package))|Application Not Responding.*$([regex]::Escape($package))|Input dispatching timed out.*$([regex]::Escape($package))"
  $nullRef='(?i)Error #1009|TypeError:\s*Error #1009|Cannot access a property or method of a null object reference'
  if($finalLog -match '(?m)ArmyAttackGame\s*:\s*(?:GAME_UNCAUGHT|SWF_UNCAUGHT|MAP_TRANSITION_FAIL)\b' -or $finalLog -match $nullRef){throw 'TARGETED_REGRESSION=FAIL component=RUNTIME operation=snow_home_snow reason=uncaught_or_null_reference'}
  if($finalLog -match $fatal){throw 'TARGETED_CRASH_CHECK=FAIL'}
  if($finalLog -match $anr){throw 'TARGETED_ANR_CHECK=FAIL'}

  $result=[ordered]@{
    repository='Valverde-101/code-army-client'
    tested_sha=$ExpectedSha
    apk_sha256=$expectedApk
    serial=$serial
    package_name=$package
    initial_health=$initialHealth
    initial_map=$initialMap
    territory_boot_restore='PASS'
    territory_switch_commit='PASS'
    snow_first_entry='PASS'
    snow_repeat_entry='PASS'
    god_mode_toggle='PASS'
    god_mode_shop_all_15='PASS'
    god_mode_map_persistence='PASS'
    null_reference_count=0
    crash_check='PASS'
    anr_check='PASS'
    screenshots=@($territoryShot,$homeShot,$godOffShot,$godOnShot,$godShopShot,$snowFirstShot,$snowRepeatShot,$godRestoredShot)
    timestamp_utc=[DateTime]::UtcNow.ToString('o')
  }
  $result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $EvidenceRoot 'targeted-regression.json') -Encoding UTF8

  $gateResults=[ordered]@{
    TEST_CONSOLE='PASS'
    TERRITORY_RESTORE_TOPOLOGY='PASS'
    TERRITORY_MAP_SWITCH='PASS'
    SNOW_FIRST_ENTRY='PASS'
    SNOW_REPEAT_ENTRY='PASS'
    TARGETED_CRASH_CHECK='PASS'
    TARGETED_ANR_CHECK='PASS'
    TARGETED_REGRESSION='PASS'
    GOD_MODE_TOGGLE='PASS'
    GOD_MODE_ALL_TROOPS='PASS'
    GOD_MODE_MAP_PERSISTENCE='PASS'
  }
  foreach($entry in $gateResults.GetEnumerator()){
    $prop=$summary.results.PSObject.Properties[$entry.Key]
    if($null -eq $prop){$summary.results|Add-Member -MemberType NoteProperty -Name $entry.Key -Value $entry.Value}
    else{$prop.Value=$entry.Value}
  }
  $summary|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $summaryPath -Encoding UTF8

  Write-Host 'TEST_CONSOLE=PASS transport=adb_broadcast permission=android.permission.DUMP no_coordinate_taps=true'
  Write-Host 'GOD_MODE_TOGGLE=PASS off_on_off=true diagnostics_trace=true screenshots=3'
  Write-Host 'GOD_MODE_MAP_PERSISTENCE=PASS Home_Snow_Home=true default_off=true temporary=true'
  Write-Host 'TERRITORY_RESTORE_TOPOLOGY=PASS boot_restore=true visual_commit=full screenshot_before_capture=true'
  Write-Host 'TERRITORY_MAP_SWITCH=PASS Home=true Snow=true visual_commit=full'
  Write-Host 'SNOW_REPEAT_ENTRY=PASS sequence=Home-Snow-Home-Snow-Home null_reference=0'
  Write-Host 'TARGETED_CRASH_CHECK=PASS'
  Write-Host 'TARGETED_ANR_CHECK=PASS'
  Write-Host "TARGETED_REGRESSION=PASS tested_sha=$ExpectedSha apk_sha256=$expectedApk serial=$serial evidence=$EvidenceRoot"
} finally {
  try{& $adb -s $serial shell am force-stop $package|Out-Null}catch{}
  if($lock){$lock.Dispose()}
  Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  Write-Host "TARGETED_DEVICE_LOCK_RELEASE=PASS serial=$serial"
}
