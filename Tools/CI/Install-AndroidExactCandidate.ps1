param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [string]$AndroidBuildRoot,
  [string]$Serial,
  [switch]$AllowOneTimeSignatureReset
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if($ExpectedSha -notmatch '^[a-fA-F0-9]{40}$'){throw "MANUAL_INSTALL_EXACT=FAIL component=SOURCE operation=validate_sha expected=40_hex actual=$ExpectedSha"}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()
if([string]::IsNullOrWhiteSpace($AndroidBuildRoot)){
  $AndroidBuildRoot=@($env:ANDROIDBUILD_ROOT,'V:\AndroidBuild','D:\AndroidBuild','C:\AndroidBuild') |
    Where-Object{$_ -and (Test-Path -LiteralPath $_ -PathType Container)} |
    Select-Object -First 1
}
if(-not $AndroidBuildRoot){throw 'MANUAL_INSTALL_EXACT=FAIL component=TOOLCHAIN operation=resolve_androidbuild_root actual=missing'}
$AndroidBuildRoot=(Resolve-Path -LiteralPath $AndroidBuildRoot).Path
$adb=Join-Path $AndroidBuildRoot 'AndroidSDK\platform-tools\adb.exe'
if(-not(Test-Path -LiteralPath $adb -PathType Leaf)){throw "MANUAL_INSTALL_EXACT=FAIL component=ADB operation=resolve expected=$adb actual=missing"}

$repo=Join-Path $AndroidBuildRoot 'Repositories\code-army-client'
$apk=Join-Path $repo ('.work\runtime\AndroidBuild\Builds\code-army-client\'+$ExpectedSha+'\android\candidate\ArmyAttack-23.2-'+$ExpectedSha+'.apk')
if(-not(Test-Path -LiteralPath $apk -PathType Leaf)){throw "MANUAL_INSTALL_EXACT=FAIL component=APK operation=resolve_exact expected_sha=$ExpectedSha path=$apk actual=missing"}
$apkSha=(Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToUpperInvariant()
$apkSize=(Get-Item -LiteralPath $apk).Length
$short=$ExpectedSha.Substring(0,8)
$pkg='air.army.attack'

$deviceLines=@(& $adb devices -l)
$authorized=@()
foreach($line in $deviceLines){if($line -match '^(?<serial>\S+)\s+device(?:\s|$)'){$authorized+=$matches['serial']}}
if($Serial){
  if($authorized -notcontains $Serial){throw "MANUAL_INSTALL_EXACT=FAIL component=ADB operation=select_device expected=$Serial actual=$($authorized -join ',')"}
}elseif($authorized.Count -eq 1){
  $Serial=$authorized[0]
}elseif($authorized.Count -eq 0){
  throw 'MANUAL_INSTALL_EXACT=FAIL component=ADB operation=discover expected=one_authorized_device actual=none'
}else{
  throw "MANUAL_INSTALL_EXACT=FAIL component=ADB operation=discover expected=one_authorized_device actual=multiple serials=$($authorized -join ',')"
}

$model=(& $adb -s $Serial shell getprop ro.product.model 2>$null | Out-String).Trim()
$androidVersion=(& $adb -s $Serial shell getprop ro.build.version.release 2>$null | Out-String).Trim()
$api=(& $adb -s $Serial shell getprop ro.build.version.sdk 2>$null | Out-String).Trim()
$abi=(& $adb -s $Serial shell getprop ro.product.cpu.abi 2>$null | Out-String).Trim()
Write-Host "ADB_DEVICE=PASS serial=$Serial model=$model android=$androidVersion api=$api abi=$abi adb=$adb"

$preDump=(& $adb -s $Serial shell dumpsys package $pkg 2>&1 | Out-String)
$preVersion='NOT_INSTALLED'
$preMatch=[regex]::Match($preDump,'versionName=(?<value>[^\r\n\s]+)')
if($preMatch.Success){$preVersion=$preMatch.Groups['value'].Value}
Write-Host "MANUAL_INSTALL_PRECHECK=PASS tested_sha=$ExpectedSha apk=$apk size=$apkSize sha256=$apkSha serial=$Serial installed_before=$preVersion signature_reset_allowed=$($AllowOneTimeSignatureReset.IsPresent)"

function Invoke-ExactInstall {
  $lines=@(& $adb -s $Serial install -r $apk 2>&1 | ForEach-Object{$_.ToString()})
  $exit=$LASTEXITCODE
  $text=($lines -join "`n").Trim()
  $lines|ForEach-Object{Write-Host "ADB_INSTALL=$_"}
  return [pscustomobject]@{exit=$exit;text=$text}
}

$install=Invoke-ExactInstall
if($install.exit -ne 0){
  $signatureMismatch=$install.text -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match|signature.*mismatch'
  if($signatureMismatch -and -not $AllowOneTimeSignatureReset){
    throw "MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=signature_migration expected=stable_candidate_signature actual=legacy_or_different_signature installed_version=$preVersion action=rerun_with_-AllowOneTimeSignatureReset_only_if_data_reset_is_acceptable"
  }
  if($signatureMismatch -and $AllowOneTimeSignatureReset){
    Write-Host "INSTALL_SIGNATURE_RESET=AUTHORIZED serial=$Serial package=$pkg data_reset=true previous_version=$preVersion reason=one_time_migration_to_stable_candidate_signing"
    & $adb -s $Serial uninstall $pkg | ForEach-Object{Write-Host "ADB_UNINSTALL=$_"}
    if($LASTEXITCODE -ne 0){throw "MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=signature_reset_uninstall exit=$LASTEXITCODE"}
    $install=Invoke-ExactInstall
    if($install.exit -ne 0){throw "MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=install_after_signature_reset exit=$($install.exit) actual=$($install.text)"}
    Write-Host 'INSTALL_SIGNATURE_RESET=PASS data_reset=true migration=legacy_to_stable_candidate_signing'
  }else{
    throw "MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=adb_install exit=$($install.exit) actual=$($install.text)"
  }
}

$pmPath=(& $adb -s $Serial shell pm path $pkg 2>&1 | Out-String).Trim()
if($LASTEXITCODE -ne 0 -or $pmPath -notmatch '^package:'){throw "MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=pm_path package=$pkg actual=$pmPath"}
$dump=(& $adb -s $Serial shell dumpsys package $pkg 2>&1 | Out-String)
$versionMatch=[regex]::Match($dump,'versionName=(?<value>[^\r\n\s]+)')
if(-not $versionMatch.Success){throw 'MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=verify_version_name actual=missing'}
$versionName=$versionMatch.Groups['value'].Value
if($versionName -notlike "*$short*"){throw "MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=verify_exact_sha expected_short_sha=$short actual_version_name=$versionName"}

Write-Host "INSTALL=PASS package=$pkg serial=$Serial versionName=$versionName tested_sha=$ExpectedSha apk_sha256=$apkSha"
Write-Host "MANUAL_INSTALL_EXACT=PASS tested_sha=$ExpectedSha apk_sha256=$apkSha serial=$Serial model=$model android=$androidVersion api=$api abi=$abi versionName=$versionName pm_path=$pmPath"
