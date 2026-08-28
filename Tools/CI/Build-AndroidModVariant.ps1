param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$PhysicalAndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$PinnedAndroidBuildRoot,
  [Parameter(Mandatory=$true)][ValidateSet('colossal','crimson','hardmode','none','swapped','swapped2','truecrimson')][string]$Variant
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Get-TreeDigest([string]$Root){
  if(-not (Test-Path -LiteralPath $Root)){throw "TREE_DIGEST=FAIL missing=$Root"}
  $rows=New-Object System.Collections.Generic.List[string]
  $files=@(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Stop|Sort-Object FullName)
  [long]$bytes=0
  foreach($file in $files){
    $rel=$file.FullName.Substring($Root.Length).TrimStart([char[]]"\\/").Replace('\\','/')
    $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $bytes+=$file.Length
    $rows.Add("$rel|$($file.Length)|$hash")
  }
  $payload=[Text.Encoding]::UTF8.GetBytes(($rows -join "`n"))
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$digest=[BitConverter]::ToString($sha.ComputeHash($payload)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
  return [pscustomobject]@{files=$files.Count;bytes=$bytes;sha256=$digest}
}

$gitCandidates=@((Join-Path $PhysicalAndroidBuildRoot 'Tools\Git\cmd\git.exe'),(Join-Path $PhysicalAndroidBuildRoot 'PortableGit\cmd\git.exe'))
$gitCmd=Get-Command git.exe -ErrorAction SilentlyContinue
if($gitCmd){$gitCandidates=@($gitCmd.Source)+$gitCandidates}
$git=$gitCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
if(-not $git){throw 'MOD_PRECHECK_GIT=FAIL'}
$actual=(& $git -C $RepoRoot rev-parse HEAD).Trim()
if($actual -ne $ExpectedSha){throw "MOD_EXACT_HEAD=FAIL expected=$ExpectedSha actual=$actual"}
Write-Host "MOD_EXACT_HEAD=PASS sha=$actual"

$publishedExpectedSha='306bccc7db5b1ce34dd68a3bc80093648c9224bd'
$publishedRoot=Join-Path $RepoRoot 'vendor\Test_army_attack'
if(-not (Test-Path -LiteralPath $publishedRoot)){throw "MOD_SOURCE=FAIL vendor_missing=$publishedRoot"}
$publishedActual=(& $git -C $publishedRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $publishedActual -ne $publishedExpectedSha){throw "MOD_SOURCE=FAIL expected=$publishedExpectedSha actual=$publishedActual"}

$modRoot=Join-Path $publishedRoot ("mods\"+$Variant)
$dataRoot=Join-Path $modRoot 'data'
$configRoot=Join-Path $modRoot 'config'
$assetsRoot=Join-Path $modRoot 'assets'
foreach($p in @($modRoot,$dataRoot,$configRoot,$assetsRoot)){if(-not (Test-Path -LiteralPath $p)){throw "MOD_SOURCE=FAIL variant=$Variant missing=$p"}}
$swfs=@(Get-ChildItem -LiteralPath $assetsRoot -File -Filter '*.swf' -ErrorAction Stop)
if($swfs.Count -ne 1){throw "MOD_SWF=FAIL variant=$Variant expected=1 actual=$($swfs.Count)"}
$sourceSwf=$swfs[0]
$sourceSwfHash=(Get-FileHash -LiteralPath $sourceSwf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$dataDigest=Get-TreeDigest $dataRoot
$configDigest=Get-TreeDigest $configRoot
Write-Host "MOD_SOURCE=PASS variant=$Variant source_sha=$publishedActual"
Write-Host "MOD_SWF=PASS variant=$Variant path=$($sourceSwf.FullName) size=$($sourceSwf.Length) sha256=$sourceSwfHash"
Write-Host "MOD_DATA=PASS files=$($dataDigest.files) bytes=$($dataDigest.bytes) sha256=$($dataDigest.sha256)"
Write-Host "MOD_CONFIG=PASS files=$($configDigest.files) bytes=$($configDigest.bytes) sha256=$($configDigest.sha256)"

$airRoot=Join-Path $PhysicalAndroidBuildRoot 'Tools\AIRSDK-50.2.3.6'
$adt=Join-Path $airRoot 'bin\adt.bat'
$javaHome=Join-Path $PhysicalAndroidBuildRoot 'Tools\Java\jdk-17'
$java=Join-Path $javaHome 'bin\java.exe'
$sdk=Join-Path $PinnedAndroidBuildRoot 'AndroidSDK'
$packageSdk=Join-Path $PinnedAndroidBuildRoot 'Tools\AndroidSDK-AIR50-api33'
$buildTools=Join-Path $sdk 'build-tools\33.0.2'
$aapt=Join-Path $buildTools 'aapt.exe'
$apksigner=Join-Path $buildTools 'apksigner.bat'
$zipalign=Join-Path $buildTools 'zipalign.exe'
foreach($p in @($adt,$java,$aapt,$apksigner,$zipalign,(Join-Path $packageSdk 'platforms\android-33\android.jar'))){if(-not (Test-Path -LiteralPath $p)){throw "MOD_TOOLCHAIN=FAIL missing=$p"}}
$env:JAVA_HOME=$javaHome
$javaBin=Join-Path $javaHome 'bin'
$env:PATH=$javaBin+';'+$env:PATH
Remove-Item Env:JAVA_TOOL_OPTIONS -ErrorAction SilentlyContinue
$resolvedJava=(Get-Command java.exe -ErrorAction Stop).Source
if(-not $resolvedJava.StartsWith($javaBin,[System.StringComparison]::OrdinalIgnoreCase)){throw "MOD_JAVA_PATH_PIN=FAIL variant=$Variant expected_root=$javaBin actual=$resolvedJava"}
$javaVersionErr=Join-Path $env:TEMP ("army-java-version-"+[guid]::NewGuid().ToString('N')+".err.txt")
$javaVersionOut=Join-Path $env:TEMP ("army-java-version-"+[guid]::NewGuid().ToString('N')+".out.txt")
try{
  $javaProbe=Start-Process -FilePath $resolvedJava -ArgumentList @('-version') -NoNewWindow -PassThru -Wait -RedirectStandardOutput $javaVersionOut -RedirectStandardError $javaVersionErr
  $javaVersionLines=@()
  if(Test-Path -LiteralPath $javaVersionOut){$javaVersionLines+=@(Get-Content -LiteralPath $javaVersionOut -ErrorAction SilentlyContinue)}
  if(Test-Path -LiteralPath $javaVersionErr){$javaVersionLines+=@(Get-Content -LiteralPath $javaVersionErr -ErrorAction SilentlyContinue)}
  $javaVersionText=(@($javaVersionLines|ForEach-Object{$_.ToString()}) -join ' ')
  if($javaProbe.ExitCode -ne 0 -or $javaVersionText -notmatch 'version "17\.'){throw "MOD_JAVA_VERSION=FAIL variant=$Variant exit=$($javaProbe.ExitCode) actual=$javaVersionText"}
}finally{
  Remove-Item -LiteralPath $javaVersionOut,$javaVersionErr -Force -ErrorAction SilentlyContinue
}
Write-Host "MOD_JAVA_PATH_PIN=PASS variant=$Variant path=$resolvedJava version=$javaVersionText"
$adtVersion=(& $adt -version 2>&1|ForEach-Object{$_.ToString()}) -join ' '
if($LASTEXITCODE -ne 0 -or $adtVersion -notmatch '^50\.2\.3\.6'){throw "MOD_TOOLCHAIN=FAIL air=$adtVersion"}
Write-Host "MOD_TOOLCHAIN=PASS air=50.2.3.6 java=17 api=33 build_tools=33.0.2 abi=arm64-v8a"

$buildRoot=Join-Path $PhysicalAndroidBuildRoot ("Builds\code-army-client\"+$ExpectedSha+"\android\mods\"+$Variant)
$stage=Join-Path $buildRoot 'stage'
if(Test-Path -LiteralPath $buildRoot){Remove-Item -LiteralPath $buildRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $stage|Out-Null
$appContentSwf='iArmyAirOffline.swf'
Copy-Item -LiteralPath $sourceSwf.FullName -Destination (Join-Path $stage $appContentSwf) -Force
Copy-Item -LiteralPath $dataRoot -Destination (Join-Path $stage 'data') -Recurse -Force
Copy-Item -LiteralPath $configRoot -Destination (Join-Path $stage 'config') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'src\AppIconsForPublish') -Destination (Join-Path $stage 'AppIconsForPublish') -Recurse -Force

$objectiveIcons=Join-Path $stage 'data\icons\mission_icons\objective_icons'
if(Test-Path -LiteralPath $objectiveIcons){
  foreach($asset in @(Get-ChildItem -LiteralPath $objectiveIcons -File -Filter '*obrazovky (397).png' -ErrorAction SilentlyContinue)){
    $refs=Get-ChildItem -LiteralPath $stage -Recurse -File -Include '*.json','*.xml','*.csv','*.txt','*.as' -ErrorAction SilentlyContinue|Select-String -SimpleMatch $asset.Name -List -ErrorAction SilentlyContinue
    if($refs){throw "MOD_STAGE_SANITIZE=FAIL variant=$Variant referenced_invalid_asset=$($asset.Name)"}
    Remove-Item -LiteralPath $asset.FullName -Force
    Write-Host "MOD_STAGE_SANITIZE=PASS removed=$($asset.Name)"
  }
}

$packageId="army.attack.mod.$Variant"
$expectedAndroidPackage="air.$packageId"
$descriptor=Join-Path $buildRoot ("ArmyAttack-"+$Variant+"-android-app.xml")
$displayName=(Get-Culture).TextInfo.ToTitleCase($Variant.Replace('2',' 2'))
$xml=@"
<?xml version="1.0" encoding="utf-8"?>
<application xmlns="http://ns.adobe.com/air/application/50.2">
  <id>$packageId</id>
  <versionNumber>1.0.0</versionNumber>
  <versionLabel>mod-$Variant-android-$($ExpectedSha.Substring(0,8))</versionLabel>
  <filename>ArmyAttackMod$Variant</filename>
  <name>Army Attack - $displayName</name>
  <initialWindow>
    <content>$appContentSwf</content>
    <visible>true</visible>
    <fullScreen>true</fullScreen>
    <aspectRatio>landscape</aspectRatio>
    <renderMode>auto</renderMode>
    <autoOrients>false</autoOrients>
  </initialWindow>
  <icon>
    <image36x36>AppIconsForPublish/icon36.png</image36x36>
    <image48x48>AppIconsForPublish/icon48.png</image48x48>
    <image72x72>AppIconsForPublish/icon72.png</image72x72>
    <image96x96>AppIconsForPublish/icon96.png</image96x96>
    <image144x144>AppIconsForPublish/icon144.png</image144x144>
    <image192x192>AppIconsForPublish/icon192.png</image192x192>
  </icon>
  <android>
    <manifestAdditions><![CDATA[
      <manifest>
        <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="33"/>
        <uses-feature android:glEsVersion="0x00020000" android:required="true"/>
        <application android:hardwareAccelerated="true" android:usesCleartextTraffic="false"/>
      </manifest>
    ]]></manifestAdditions>
  </android>
</application>
"@
$xml|Set-Content -LiteralPath $descriptor -Encoding UTF8

$cert=Join-Path $buildRoot 'android-mod-ci-signing.p12'
$certPass='ArmyAttackModLocalCI'
$apkPath=Join-Path $buildRoot ("ArmyAttack-mod-"+$Variant+"-"+$ExpectedSha+".apk")
$stdout=Join-Path $buildRoot 'adt-mod.out.log'
$stderr=Join-Path $buildRoot 'adt-mod.err.log'
try{
  $certArgs=@('-certificate','-cn',("ArmyAttackMod"+$Variant),'-ou','Dev','-o','ValverdeLocalBuild','-c','PE','2048-RSA',$cert,$certPass)
  $cp=Start-Process -FilePath $adt -ArgumentList $certArgs -WorkingDirectory $buildRoot -NoNewWindow -PassThru -Wait
  if($cp.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $cert)){throw "MOD_CERT=FAIL variant=$Variant exit=$($cp.ExitCode)"}
  $args=@('-package','-target','apk-captive-runtime','-arch','armv8','-storetype','pkcs12','-keystore',$cert,'-storepass',$certPass,$apkPath,$descriptor,'-C',$stage,'.','-platformsdk',$packageSdk)
  $pp=Start-Process -FilePath $adt -ArgumentList $args -WorkingDirectory $buildRoot -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  if($pp.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $apkPath)){
    if(Test-Path $stdout){Get-Content $stdout -Tail 80|ForEach-Object{Write-Host $_}}
    if(Test-Path $stderr){Get-Content $stderr -Tail 80|ForEach-Object{Write-Host $_}}
    throw "MOD_PACKAGE=FAIL variant=$Variant exit=$($pp.ExitCode)"
  }
}finally{
  Remove-Item -LiteralPath $cert -Force -ErrorAction SilentlyContinue
  Write-Host "MOD_CERT_CLEANUP=PASS variant=$Variant"
}

$badging=@(& $aapt dump badging $apkPath 2>&1|ForEach-Object{$_.ToString()})
if($LASTEXITCODE -ne 0){throw "MOD_VALIDATE=FAIL variant=$Variant aapt"}
$badgingText=$badging -join "`n"
$pkg='';$target=0;$min=0
if($badgingText -match "package:\s+name='([^']+)'"){$pkg=$matches[1]}
if($badgingText -match "targetSdkVersion:'(\d+)'"){$target=[int]$matches[1]}
if($badgingText -match "sdkVersion:'(\d+)'"){$min=[int]$matches[1]}
if($pkg -ne $expectedAndroidPackage){throw "MOD_VALIDATE=FAIL variant=$Variant package_expected=$expectedAndroidPackage actual=$pkg"}
if($target -ne 33){throw "MOD_VALIDATE=FAIL variant=$Variant target_sdk=$target"}
if($min -lt 21){throw "MOD_VALIDATE=FAIL variant=$Variant min_sdk=$min"}

$entries=@(& $aapt list $apkPath 2>&1|ForEach-Object{$_.ToString()})
if($LASTEXITCODE -ne 0 -or -not ($entries|Where-Object{$_ -like 'lib/arm64-v8a/*'})){throw "MOD_VALIDATE=FAIL variant=$Variant abi=arm64-v8a_missing"}
& $zipalign -c -v 4 $apkPath 1>$null
if($LASTEXITCODE -ne 0){throw "MOD_VALIDATE=FAIL variant=$Variant zipalign"}
& $apksigner verify --verbose $apkPath 1>$null
if($LASTEXITCODE -ne 0){throw "MOD_VALIDATE=FAIL variant=$Variant signature"}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($apkPath)
try{
  $entry=@($zip.Entries|Where-Object{$_.FullName -eq ("assets/"+$appContentSwf)})|Select-Object -First 1
  if(-not $entry){throw "MOD_VALIDATE=FAIL variant=$Variant swf_entry_missing"}
  $stream=$entry.Open()
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$zipSwfHash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
}finally{$zip.Dispose()}
if($zipSwfHash -ne $sourceSwfHash){throw "MOD_VALIDATE=FAIL variant=$Variant swf_hash expected=$sourceSwfHash actual=$zipSwfHash"}

$apk=Get-Item -LiteralPath $apkPath
$apkSha=(Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$prov=[ordered]@{
  repository='Valverde-101/code-army-client'
  tested_sha=$ExpectedSha
  source_repository='Valverde-101/Test_army_attack'
  source_sha=$publishedActual
  variant=$Variant
  content_lineage='published_mod_snapshot'
  modern_android_runtime=$true
  air_sdk='50.2.3.6'
  android_target_sdk=33
  android_min_sdk=$min
  android_abi='arm64-v8a'
  package_name=$pkg
  swf_path=("vendor/Test_army_attack/mods/"+$Variant+"/assets/"+$sourceSwf.Name)
  swf_size=$sourceSwf.Length
  swf_sha256=$sourceSwfHash
  data=$dataDigest
  config=$configDigest
  apk_path=$apkPath
  apk_size=$apk.Length
  apk_sha256=$apkSha
}
$provPath=Join-Path $buildRoot 'MOD-PROVENANCE.json'
$prov|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $provPath -Encoding UTF8
$badging|Set-Content -LiteralPath (Join-Path $buildRoot 'apk-badging.txt') -Encoding UTF8

Write-Host "MOD_BUILD=PASS variant=$Variant"
Write-Host "MOD_APK_VALIDATE=PASS variant=$Variant package=$pkg target_sdk=$target min_sdk=$min abi=arm64-v8a"
Write-Host "MOD_APK_PATH=$apkPath"
Write-Host "MOD_APK_SIZE=$($apk.Length)"
Write-Host "MOD_APK_SHA256=$apkSha"
Write-Host "MOD_SWF_SHA256=$sourceSwfHash"
Write-Host "MOD_PROVENANCE=$provPath"
