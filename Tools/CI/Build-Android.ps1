param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$gitCandidates=@((Join-Path $AndroidBuildRoot 'Tools\Git\cmd\git.exe'),(Join-Path $AndroidBuildRoot 'PortableGit\cmd\git.exe'))
$gitCmd=Get-Command git.exe -ErrorAction SilentlyContinue
if($gitCmd){$gitCandidates=@($gitCmd.Source)+$gitCandidates}
$git=$gitCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
if(-not $git){throw 'PRECHECK_GIT=FAIL'}
Push-Location $RepoRoot
try{$actual=(& $git rev-parse HEAD).Trim();if($actual -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$actual"}}finally{Pop-Location}
Write-Host "EXACT_HEAD=PASS sha=$ExpectedSha"
$androidSdk=Join-Path $AndroidBuildRoot 'AndroidSDK'
$adb=Join-Path $androidSdk 'platform-tools\adb.exe'
if(-not (Test-Path -LiteralPath $androidSdk)){throw "ANDROID_SDK=FAIL path=$androidSdk"}
if(-not (Test-Path -LiteralPath $adb)){throw "ADB=FAIL path=$adb"}
Write-Host "ANDROID_SDK=PASS path=$androidSdk"
Write-Host "ADB=PASS path=$adb"
$javaCandidates=@()
if($env:JAVA_HOME){$javaCandidates+=(Join-Path $env:JAVA_HOME 'bin\java.exe')}
$javaCandidates+=@((Join-Path $AndroidBuildRoot 'Tools\Java\jdk-21\bin\java.exe'),(Join-Path $AndroidBuildRoot 'Tools\Java\jdk-17\bin\java.exe'))
$javaCmd=Get-Command java.exe -ErrorAction SilentlyContinue
if($javaCmd){$javaCandidates+=$javaCmd.Source}
$java=$javaCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
if(-not $java){throw 'JAVA=FAIL'}
$env:JAVA_HOME=Split-Path -Parent (Split-Path -Parent $java)
Write-Host "JAVA=PASS path=$java"
$javaVersionOut=Join-Path $env:TEMP "army-java-version-$PID.out.txt"
$javaVersionErr=Join-Path $env:TEMP "army-java-version-$PID.err.txt"
$pJava=Start-Process -FilePath $java -ArgumentList '-version' -NoNewWindow -PassThru -Wait -RedirectStandardOutput $javaVersionOut -RedirectStandardError $javaVersionErr
if($pJava.ExitCode -ne 0){throw "JAVA_VERSION=FAIL exit=$($pJava.ExitCode)"}
$javaVersionLines=@()
foreach($vf in @($javaVersionOut,$javaVersionErr)){if(Test-Path $vf){$javaVersionLines+=@(Get-Content $vf);Remove-Item $vf -Force -ErrorAction SilentlyContinue}}
$javaVersionLines|ForEach-Object{Write-Host "JAVA_VERSION=$_"}
$javaVersionText=($javaVersionLines -join "`n")
$javaMajor=0
if($javaVersionText -match 'version\s+"(?<major>\d+)(?:\.(?<minor>\d+))?'){$javaMajor=[int]$matches['major'];if($javaMajor -eq 1 -and $matches['minor']){$javaMajor=[int]$matches['minor']}}
Write-Host "JAVA_MAJOR=$javaMajor"
if($javaMajor -ge 9){
  $legacyExports=@(
    '--add-exports=java.base/sun.security.x509=ALL-UNNAMED',
    '--add-exports=java.base/sun.security.pkcs=ALL-UNNAMED'
  )
  $existing=[string]$env:JAVA_TOOL_OPTIONS
  foreach($legacyExport in $legacyExports){if($existing -notlike "*$legacyExport*"){$existing=(($existing+' '+$legacyExport).Trim())}}
  $env:JAVA_TOOL_OPTIONS=$existing
  Write-Host "AIR_LEGACY_JAVA_PREPROBE_COMPAT=PASS java_major=$javaMajor exports=sun.security.x509,sun.security.pkcs"
}
$airRoots=New-Object System.Collections.Generic.List[string]
function Add-AirRoot([string]$p){if($p -and (Test-Path -LiteralPath (Join-Path $p 'bin\adt.bat')) -and -not $airRoots.Contains($p)){$airRoots.Add($p)}}
if($env:AIR_HOME){Add-AirRoot $env:AIR_HOME}
foreach($base in @((Join-Path $AndroidBuildRoot 'Tools'),(Join-Path $AndroidBuildRoot 'AIRSDK'),(Join-Path $env:USERPROFILE 'sdks\air'))){
  if($base -and (Test-Path -LiteralPath $base)){Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue|ForEach-Object{Add-AirRoot $_.FullName}}
}
Add-AirRoot (Join-Path $AndroidBuildRoot 'Tools\AIRSDK-32')
$airChoices=@()
foreach($root in $airRoots){
  $adt=Join-Path $root 'bin\adt.bat'
  $previousErrorActionPreference=$ErrorActionPreference
  try{
    # JVM notices such as "Picked up JAVA_TOOL_OPTIONS" are written to stderr.
    # Windows PowerShell turns redirected native stderr into ErrorRecord objects;
    # with ErrorActionPreference=Stop that can falsely mark a healthy ADT as unusable.
    $ErrorActionPreference='Continue'
    $probeLines=@(& $adt -version 2>&1 | ForEach-Object { $_.ToString() })
    $probeExit=$LASTEXITCODE
  }finally{
    $ErrorActionPreference=$previousErrorActionPreference
  }
  $ver=($probeLines -join "`n").Trim()
  if($probeExit -ne 0){
    Write-Host "AIR_DISCOVERY_WARNING root=$root exit=$probeExit output=$ver"
    continue
  }
  if($ver -match '(\d+)\.(\d+)'){
    $major=[int]$matches[1];$minor=[int]$matches[2]
    $airChoices+=[pscustomobject]@{Root=$root;Adt=$adt;Version=$ver;Major=$major;Minor=$minor;Score=($major*1000+$minor)}
    Write-Host "AIR_DISCOVERED root=$root version=$ver"
  }else{
    Write-Host "AIR_DISCOVERY_WARNING root=$root exit=0 reason=version_unparseable output=$ver"
  }
}
if($airChoices.Count -eq 0){throw 'AIR_SDK=FAIL no usable adt.bat found'}
$air=$airChoices|Sort-Object Score -Descending|Select-Object -First 1
$harmanAndroid=($air.Major -ge 50)
$airNamespace=if($harmanAndroid){"$($air.Major).$($air.Minor)"}else{'32.0'}
$targetApi=if($air.Major -eq 50){33}elseif($air.Major -ge 51){36}else{27}
$targetBuildTools=if($air.Major -eq 50){'33.0.2'}elseif($air.Major -ge 51){'36.0.0'}else{$null}
Write-Host "AIR_SDK=PASS root=$($air.Root) version=$($air.Version) harman_android=$harmanAndroid namespace=$airNamespace target_api=$targetApi"
if($harmanAndroid){
  $sdkmanager=Get-ChildItem -LiteralPath $androidSdk -Recurse -File -Filter 'sdkmanager.bat' -ErrorAction SilentlyContinue|Sort-Object FullName|Select-Object -First 1
  $platform=Join-Path $androidSdk "platforms\android-$targetApi"
  $buildToolsPath=Join-Path $androidSdk "build-tools\$targetBuildTools"
  if((-not (Test-Path -LiteralPath $platform) -or -not (Test-Path -LiteralPath $buildToolsPath)) -and $sdkmanager){
    Write-Host "ANDROID_SDK_COMPONENTS=INSTALLING api=$targetApi build_tools=$targetBuildTools"
    1..30|ForEach-Object{'y'}|& $sdkmanager.FullName --sdk_root=$androidSdk 'platform-tools' "platforms;android-$targetApi" "build-tools;$targetBuildTools"
    if($LASTEXITCODE -ne 0){throw "ANDROID_SDK_COMPONENTS=FAIL exit=$LASTEXITCODE"}
  }
  if(-not (Test-Path -LiteralPath $platform)){throw "ANDROID_PLATFORM=FAIL api=$targetApi"}
  if(-not (Test-Path -LiteralPath $buildToolsPath)){throw "ANDROID_BUILD_TOOLS=FAIL version=$targetBuildTools"}
  Write-Host "ANDROID_SDK_COMPONENTS=PASS api=$targetApi build_tools=$targetBuildTools"
}
$seedZip=Join-Path $AndroidBuildRoot 'Inputs\code-army-client\upstream\v23\AA23_release_windows.zip'
$seedUrl='https://github.com/Michielvde1253/army-client/releases/download/v23/AA23_release_windows.zip'
$seedSize=64812856
$seedSha='e449206435d02797f9c509fc604706274614f21e805581be254f20f2a0d02093'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $seedZip)|Out-Null
$needSeed=$true
if(Test-Path -LiteralPath $seedZip){if((Get-Item $seedZip).Length -eq $seedSize -and (Get-FileHash $seedZip -Algorithm SHA256).Hash.ToLowerInvariant() -eq $seedSha){$needSeed=$false}}
if($needSeed){
  $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
  if($curl){& $curl.Source -L --fail --retry 3 --retry-delay 2 -o $seedZip $seedUrl;if($LASTEXITCODE -ne 0){throw "V23_DOWNLOAD=FAIL exit=$LASTEXITCODE"}}
  else{Invoke-WebRequest -Uri $seedUrl -OutFile $seedZip -UseBasicParsing}
}
if((Get-Item $seedZip).Length -ne $seedSize){throw 'V23_SEED=FAIL size'}
if((Get-FileHash $seedZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $seedSha){throw 'V23_SEED=FAIL sha256'}
Write-Host "V23_SEED=PASS zip=$seedZip sha256=$seedSha"
$buildRoot=Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\android"
$seedExtract=Join-Path $buildRoot 'v23'
$stage=Join-Path $buildRoot 'stage'
foreach($p in @($seedExtract,$stage)){if(Test-Path $p){Remove-Item $p -Recurse -Force};New-Item -ItemType Directory -Force -Path $p|Out-Null}
Expand-Archive -LiteralPath $seedZip -DestinationPath $seedExtract -Force
$sourceRoot=Join-Path $seedExtract '23'
$seedSwf=Join-Path $sourceRoot 'iArmyAirOfflineSavingv21_2.swf'
$expectedSwfSha='4b7b09398779c33879f6aff337b57eca6dcc3ad637348a35d22bf2858005f3fc'
if(-not (Test-Path $seedSwf)){throw "BINARY_SEED=FAIL missing_swf=$seedSwf"}
$swfSha=(Get-FileHash $seedSwf -Algorithm SHA256).Hash.ToLowerInvariant()
if($swfSha -ne $expectedSwfSha){throw "BINARY_SEED=FAIL expected=$expectedSwfSha actual=$swfSha"}
Copy-Item -LiteralPath $seedSwf -Destination (Join-Path $stage 'iArmyAirOfflineSavingv21_2.swf') -Force
foreach($name in @('data','config')){
  $base=Join-Path $sourceRoot $name;$dest=Join-Path $stage $name
  Copy-Item -LiteralPath $base -Destination $dest -Recurse -Force
  $head=Join-Path (Join-Path $RepoRoot 'src') $name
  foreach($child in Get-ChildItem -LiteralPath $head -Force){Copy-Item -LiteralPath $child.FullName -Destination $dest -Recurse -Force}
  Write-Host "ANDROID_CONTENT_OVERLAY=PASS component=$name"
}
Copy-Item -LiteralPath (Join-Path $RepoRoot 'src\AppIconsForPublish') -Destination (Join-Path $stage 'AppIconsForPublish') -Recurse -Force
$objectiveIcons=Join-Path $stage 'data\icons\mission_icons\objective_icons'
$invalidSeedAssets=@(Get-ChildItem -LiteralPath $objectiveIcons -File -Filter '*obrazovky (397).png' -ErrorAction SilentlyContinue)
if($invalidSeedAssets.Count -gt 1){throw "ANDROID_STAGE_SANITIZE=FAIL ambiguous_invalid_asset count=$($invalidSeedAssets.Count)"}
if($invalidSeedAssets.Count -eq 1){
  $asset=$invalidSeedAssets[0]
  $needle=$asset.Name
  $refs=Get-ChildItem -LiteralPath $stage -Recurse -File -Include '*.json','*.xml','*.csv','*.txt','*.as' -ErrorAction SilentlyContinue | Select-String -SimpleMatch $needle -List -ErrorAction SilentlyContinue
  if($refs){throw "ANDROID_STAGE_SANITIZE=FAIL referenced_invalid_asset name=$needle refs=$($refs.Path -join ',')"}
  Write-Host "ANDROID_STAGE_SANITIZE=PASS removed_unreferenced_invalid_asset path=$($asset.FullName) size=$($asset.Length)"
  Remove-Item -LiteralPath $asset.FullName -Force
}
$namespace=$airNamespace
$descriptor=Join-Path $buildRoot 'ArmyAttack-android-app.xml'
$xml=@"
<?xml version="1.0" encoding="utf-8"?>
<application xmlns="http://ns.adobe.com/air/application/$namespace">
  <id>army.attack</id>
  <versionNumber>23.0.0</versionNumber>
  <versionLabel>23-android-$($ExpectedSha.Substring(0,8))</versionLabel>
  <filename>ArmyAttack</filename>
  <name>Army Attack</name>
  <initialWindow>
    <content>iArmyAirOfflineSavingv21_2.swf</content>
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
        <uses-feature android:glEsVersion="0x00020000" android:required="true"/>
        <application android:hardwareAccelerated="true" android:usesCleartextTraffic="false"/>
      </manifest>
    ]]></manifestAdditions>
  </android>
</application>
"@
$xml|Set-Content -LiteralPath $descriptor -Encoding UTF8
Write-Host "ANDROID_DESCRIPTOR=PASS namespace=$namespace permissions=none discord_ane=excluded"
$cert=Join-Path $buildRoot 'android-ci-signing.p12'
$certPass='ArmyAttackLocalCI'
if(Test-Path $cert){Remove-Item $cert -Force}
$certArgs=@('-certificate','-cn','ArmyAttackAndroidCI','-ou','Dev','-o','ValverdeLocalBuild','-c','PE','2048-RSA',$cert,$certPass)
$p=Start-Process -FilePath $air.Adt -ArgumentList $certArgs -WorkingDirectory $buildRoot -NoNewWindow -PassThru -Wait
if($p.ExitCode -ne 0 -or -not (Test-Path $cert)){throw "ANDROID_CERT=FAIL exit=$($p.ExitCode)"}
Write-Host "ANDROID_CERT=PASS"
$tier=if($air.Major -eq 50){'HARMAN_AIR50_ARM64'}elseif($air.Major -ge 51){'MODERN_ARM64'}else{'LEGACY_AIR32_TEST'}
$apkName=if($harmanAndroid){'ArmyAttack-android-arm64.apk'}else{'ArmyAttack-android-legacy.apk'}
$apkPath=Join-Path $buildRoot $apkName
if(Test-Path $apkPath){Remove-Item $apkPath -Force}
$packageArgs=@('-package','-target','apk-captive-runtime')
if($harmanAndroid){$packageArgs+=@('-arch','armv8')}
$packageArgs+=@('-storetype','pkcs12','-keystore',$cert,'-storepass',$certPass,$apkPath,$descriptor,'-C',$stage,'.')
if($harmanAndroid){$packageArgs+=@('-platformsdk',$androidSdk)}
$stdout=Join-Path $buildRoot 'adt-android.out.log';$stderr=Join-Path $buildRoot 'adt-android.err.log'
$p2=Start-Process -FilePath $air.Adt -ArgumentList $packageArgs -WorkingDirectory $buildRoot -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
if($p2.ExitCode -ne 0 -or -not (Test-Path $apkPath)){
  Write-Host "ANDROID_PACKAGE=FAIL exit=$($p2.ExitCode) tier=$tier stdout=$stdout stderr=$stderr"
  if(Test-Path $stdout){Get-Content $stdout|Select-Object -Last 80|ForEach-Object{Write-Host $_}}
  if(Test-Path $stderr){Get-Content $stderr|Select-Object -Last 80|ForEach-Object{Write-Host $_}}
  throw 'BUILD=FAIL android_package'
}
$apk=Get-Item $apkPath;$apkSha=(Get-FileHash $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$prov=[ordered]@{repository='Valverde-101/code-army-client';tested_sha=$ExpectedSha;build_tier=$tier;air_sdk=$air.Version;air_sdk_root=$air.Root;air_namespace=$namespace;java_home=$env:JAVA_HOME;java_major=$javaMajor;android_sdk=$androidSdk;target_android_api=$targetApi;target_abi=if($harmanAndroid){'arm64-v8a'}else{'armeabi-v7a'};binary_seed_release='v23';binary_seed_source_sha='324c29b6c9e0e32f61183bf52725662a2bd8aab9';swf_sha256=$swfSha;overlays=@('src/data','src/config');descriptor=$descriptor;removed_permissions=@('WRITE_EXTERNAL_STORAGE','MANAGE_EXTERNAL_STORAGE');excluded_extensions=@('fi.joniaromaa.adobeair.discordrpc');apk_path=$apkPath;apk_size=$apk.Length;apk_sha256=$apkSha}
$provPath=Join-Path $buildRoot 'BUILD-PROVENANCE.json'
$prov|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $provPath -Encoding UTF8
$toolchain=[ordered]@{
  tested_sha=$ExpectedSha
  java_home=$env:JAVA_HOME
  java_major=$javaMajor
  air_sdk=$air.Version
  air_sdk_root=$air.Root
  air_namespace=$namespace
  android_sdk=$androidSdk
  android_api=$targetApi
  android_build_tools=$targetBuildTools
  target_abi=if($harmanAndroid){'arm64-v8a'}else{'armeabi-v7a'}
}
$toolchainPath=Join-Path $buildRoot 'TOOLCHAIN.json'
$toolchain|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $toolchainPath -Encoding UTF8
Remove-Item -LiteralPath $cert -Force -ErrorAction SilentlyContinue
Write-Host "BUILD=PASS platform=android tier=$tier"
Write-Host "APK_GENERATED=PASS"
Write-Host "APK_PATH=$apkPath"
Write-Host "APK_SIZE=$($apk.Length)"
Write-Host "APK_SHA256=$apkSha"
Write-Host "SWF_SHA256=$swfSha"
Write-Host "AIR_VERSION=$($air.Version)"
$playReady=if($harmanAndroid){'CANDIDATE'}else{'NO_LEGACY_TOOLCHAIN'}
Write-Host "PLAY_READY=$playReady"
Write-Host "PROVENANCE_MANIFEST=$provPath"`nWrite-Host "TOOLCHAIN_MANIFEST=$toolchainPath"
