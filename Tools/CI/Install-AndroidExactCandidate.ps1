param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [string]$AndroidBuildRoot,
  [string]$Serial
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

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

$deviceLines=@(& $adb devices -l)
$authorized=@()
foreach($line in $deviceLines){
  if($line -match '^(?<serial>\S+)\s+device(?:\s|$)'){$authorized+=$matches['serial']}
}
if($Serial){
  if($authorized -notcontains $Serial){throw "MANUAL_INSTALL_EXACT=FAIL component=ADB operation=select_device expected=$Serial actual=$($authorized -join ',')"}
}elseif($authorized.Count -eq 1){
  $Serial=$authorized[0]
}elseif($authorized.Count -eq 0){
  throw 'MANUAL_INSTALL_EXACT=FAIL component=ADB operation=discover expected=one_authorized_device actual=none'
}else{
  throw "MANUAL_INSTALL_EXACT=FAIL component=ADB operation=discover expected=one_authorized_device actual=multiple serials=$($authorized -join ',')"
}

Write-Host "MANUAL_INSTALL_PRECHECK=PASS tested_sha=$ExpectedSha apk=$apk size=$apkSize sha256=$apkSha adb=$adb serial=$Serial"
& $adb -s $Serial install -r $apk
if($LASTEXITCODE -ne 0){throw "MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=adb_install exit=$LASTEXITCODE serial=$Serial"}

$pkg='air.army.attack'
$pmPath=(& $adb -s $Serial shell pm path $pkg 2>&1 | Out-String).Trim()
if($LASTEXITCODE -ne 0 -or $pmPath -notmatch '^package:'){throw "MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=pm_path package=$pkg actual=$pmPath"}
$dump=(& $adb -s $Serial shell dumpsys package $pkg 2>&1 | Out-String)
$versionMatch=[regex]::Match($dump,'versionName=(?<value>[^\r\n\s]+)')
if(-not $versionMatch.Success){throw 'MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=verify_version_name actual=missing'}
$versionName=$versionMatch.Groups['value'].Value
if($versionName -notlike "*$short*"){throw "MANUAL_INSTALL_EXACT=FAIL component=INSTALL operation=verify_exact_sha expected_short_sha=$short actual_version_name=$versionName"}

Write-Host "INSTALL=PASS package=$pkg serial=$Serial versionName=$versionName tested_sha=$ExpectedSha apk_sha256=$apkSha"
Write-Host "MANUAL_INSTALL_EXACT=PASS tested_sha=$ExpectedSha apk_sha256=$apkSha serial=$Serial versionName=$versionName"
