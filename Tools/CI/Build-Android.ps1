param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [ValidateSet('gpu','direct')][string]$RenderMode='gpu'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$renderMode=$RenderMode.ToLowerInvariant()
Write-Host "RENDER_MODE_REQUEST=PASS mode=$renderMode"
$gitCandidates=@((Join-Path $AndroidBuildRoot 'Tools\Git\cmd\git.exe'),(Join-Path $AndroidBuildRoot 'PortableGit\cmd\git.exe'))
$gitCmd=Get-Command git.exe -ErrorAction SilentlyContinue
if($gitCmd){$gitCandidates=@($gitCmd.Source)+$gitCandidates}
$git=$gitCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
if(-not $git){throw 'PRECHECK_GIT=FAIL'}
Push-Location $RepoRoot
try{$actual=(& $git rev-parse HEAD).Trim();if($actual -ne $ExpectedSha){throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$actual"}}finally{Pop-Location}
Write-Host "EXACT_HEAD=PASS sha=$ExpectedSha"
$publishedExpectedSha='306bccc7db5b1ce34dd68a3bc80093648c9224bd'
$publishedRoot=Join-Path $RepoRoot 'vendor\Test_army_attack'
if(-not (Test-Path -LiteralPath $publishedRoot)){throw "PUBLISHED_CONTENT=FAIL submodule_missing=$publishedRoot"}
$publishedActualSha=(& $git -C $publishedRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $publishedActualSha -ne $publishedExpectedSha){throw "PUBLISHED_CONTENT=FAIL expected_sha=$publishedExpectedSha actual=$publishedActualSha"}
$publishedVersions=Get-Content -LiteralPath (Join-Path $publishedRoot 'launcher\versions.json') -Raw|ConvertFrom-Json
$publishedGame23=@($publishedVersions.game|Where-Object{[string]$_.id -eq '23'})|Select-Object -First 1
if(-not $publishedGame23 -or [string]$publishedGame23.latestVersion -ne '23.2'){throw "PUBLISHED_CONTENT=FAIL expected_version=23.2"}
$publishedVersion=[string]$publishedGame23.latestVersion
$publishedGameRoot=Join-Path $publishedRoot 'armyattack'
$publishedSwf=Join-Path $publishedGameRoot 'assets\iArmyAirOfflineSavingv23.swf'
if(-not (Test-Path -LiteralPath $publishedSwf)){throw "PUBLISHED_SWF=FAIL missing=$publishedSwf"}
$publishedSwfInfo=Get-Item -LiteralPath $publishedSwf
$publishedSwfSha=(Get-FileHash -LiteralPath $publishedSwf -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "PUBLISHED_CONTENT=PASS sha=$publishedActualSha version=$publishedVersion"
Write-Host "PUBLISHED_SWF=PASS size=$($publishedSwfInfo.Length) sha256=$publishedSwfSha"

$androidSdk=Join-Path $AndroidBuildRoot 'AndroidSDK'
if(-not (Test-Path -LiteralPath $androidSdk)){throw "ANDROID_SDK=FAIL path=$androidSdk"}
Write-Host "ANDROID_SDK=PASS path=$androidSdk"
Write-Host "ADB=SKIPPED_WITH_REASON manual_physical_validation_policy"
$javaCandidates=@()
if($env:JAVA_HOME){$javaCandidates+=(Join-Path $env:JAVA_HOME 'bin\java.exe')}
$javaCandidates+=@((Join-Path $AndroidBuildRoot 'Tools\Java\jdk-21\bin\java.exe'),(Join-Path $AndroidBuildRoot 'Tools\Java\jdk-17\bin\java.exe'))
$javaCmd=Get-Command java.exe -ErrorAction SilentlyContinue
if($javaCmd){$javaCandidates+=$javaCmd.Source}
$java=$javaCandidates|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
if(-not $java){throw 'JAVA=FAIL'}
$env:JAVA_HOME=Split-Path -Parent (Split-Path -Parent $java)
$javaBin=Join-Path $env:JAVA_HOME 'bin'
$env:PATH=$javaBin+';'+$env:PATH
$resolvedJava=(Get-Command java.exe -ErrorAction Stop).Source
if(-not $resolvedJava.StartsWith($javaBin,[System.StringComparison]::OrdinalIgnoreCase)){throw "JAVA_PATH_PIN=FAIL expected_root=$javaBin actual=$resolvedJava"}
Write-Host "JAVA=PASS path=$java"
Write-Host "JAVA_PATH_PIN=PASS path=$resolvedJava"
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
if($air.Major -lt 50 -and $javaMajor -ge 9){
  $legacyExports=@(
    '--add-exports=java.base/sun.security.x509=ALL-UNNAMED',
    '--add-exports=java.base/sun.security.pkcs=ALL-UNNAMED'
  )
  $existing=[string]$env:JAVA_TOOL_OPTIONS
  foreach($legacyExport in $legacyExports){if($existing -notlike "*$legacyExport*"){$existing=(($existing+' '+$legacyExport).Trim())}}
  $env:JAVA_TOOL_OPTIONS=$existing
  Write-Host "AIR_LEGACY_JAVA_COMPAT=PASS java_major=$javaMajor"
}else{
  Remove-Item Env:JAVA_TOOL_OPTIONS -ErrorAction SilentlyContinue
  Write-Host "AIR_MODERN_JAVA_COMPAT=PASS java_major=$javaMajor legacy_exports=disabled"
}
$harmanAndroid=($air.Major -ge 50)
$airNamespace=if($harmanAndroid){"$($air.Major).$($air.Minor)"}else{'32.0'}
$targetApi=if($air.Major -eq 50){33}elseif($air.Major -ge 51){36}else{27}
$targetBuildTools=if($air.Major -eq 50){'33.0.2'}elseif($air.Major -ge 51){'36.0.0'}else{$null}
$targetAbi=if($harmanAndroid){'arm64-v8a'}else{'armeabi-v7a'}
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
$packageAndroidSdk=$androidSdk
if($air.Major -eq 50){
  $packageAndroidSdk=Join-Path $AndroidBuildRoot "Tools\AndroidSDK-AIR50-api$targetApi"
  $sourcePlatform=Join-Path $androidSdk "platforms\android-$targetApi"
  $sourceBuildTools=Join-Path $androidSdk "build-tools\$targetBuildTools"
  $sourcePlatformTools=Join-Path $androidSdk 'platform-tools'
  $platformJar=Join-Path $sourcePlatform 'android.jar'
  $aapt2Source=Join-Path $sourceBuildTools 'aapt2.exe'
  if(-not (Test-Path -LiteralPath $platformJar)){throw "AIR50_PLATFORM_SDK=FAIL android_jar_missing=$platformJar"}
  if(-not (Test-Path -LiteralPath $aapt2Source)){throw "AIR50_PLATFORM_SDK=FAIL aapt2_missing=$aapt2Source"}
  $platformJarSha=(Get-FileHash -LiteralPath $platformJar -Algorithm SHA256).Hash.ToLowerInvariant()
  $aapt2Sha=(Get-FileHash -LiteralPath $aapt2Source -Algorithm SHA256).Hash.ToLowerInvariant()
  $markerPath=Join-Path $packageAndroidSdk 'AIR50-SDK-MANIFEST.json'
  $rebuildSdk=$true
  if(Test-Path -LiteralPath $markerPath){
    try{
      $marker=Get-Content -LiteralPath $markerPath -Raw|ConvertFrom-Json
      if([string]$marker.platform_jar_sha256 -eq $platformJarSha -and [string]$marker.aapt2_sha256 -eq $aapt2Sha -and [int]$marker.api -eq $targetApi -and [string]$marker.build_tools -eq $targetBuildTools){$rebuildSdk=$false}
    }catch{$rebuildSdk=$true}
  }
  if($rebuildSdk){
    if(Test-Path -LiteralPath $packageAndroidSdk){Remove-Item -LiteralPath $packageAndroidSdk -Recurse -Force}
    New-Item -ItemType Directory -Force -Path (Join-Path $packageAndroidSdk 'platforms'),(Join-Path $packageAndroidSdk 'build-tools')|Out-Null
    Copy-Item -LiteralPath $sourcePlatform -Destination (Join-Path $packageAndroidSdk 'platforms') -Recurse -Force
    Copy-Item -LiteralPath $sourceBuildTools -Destination (Join-Path $packageAndroidSdk 'build-tools') -Recurse -Force
    if(Test-Path -LiteralPath $sourcePlatformTools){Copy-Item -LiteralPath $sourcePlatformTools -Destination $packageAndroidSdk -Recurse -Force}
    $licenses=Join-Path $androidSdk 'licenses'
    if(Test-Path -LiteralPath $licenses){Copy-Item -LiteralPath $licenses -Destination $packageAndroidSdk -Recurse -Force}
    [ordered]@{
      api=$targetApi
      build_tools=$targetBuildTools
      source_sdk=$androidSdk
      platform_jar_sha256=$platformJarSha
      aapt2_sha256=$aapt2Sha
      purpose='HARMAN AIR 50.2 isolated packaging SDK'
    }|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $markerPath -Encoding UTF8
  }
  $isolatedPlatforms=@(Get-ChildItem -LiteralPath (Join-Path $packageAndroidSdk 'platforms') -Directory -ErrorAction Stop)
  if($isolatedPlatforms.Count -ne 1 -or $isolatedPlatforms[0].Name -ne "android-$targetApi"){
    throw "AIR50_PLATFORM_SDK=FAIL expected_only=android-$targetApi actual=$($isolatedPlatforms.Name -join ',')"
  }
  Write-Host "AIR50_PLATFORM_SDK=PASS root=$packageAndroidSdk api=$targetApi build_tools=$targetBuildTools platform_jar_sha256=$platformJarSha"
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
$fallbackSeedSwf=Join-Path $sourceRoot 'iArmyAirOfflineSavingv21_2.swf'
$fallbackExpectedSwfSha='4b7b09398779c33879f6aff337b57eca6dcc3ad637348a35d22bf2858005f3fc'
if(-not (Test-Path $fallbackSeedSwf)){throw "BINARY_SEED_FALLBACK=FAIL missing_swf=$fallbackSeedSwf"}
$fallbackSwfSha=(Get-FileHash $fallbackSeedSwf -Algorithm SHA256).Hash.ToLowerInvariant()
if($fallbackSwfSha -ne $fallbackExpectedSwfSha){throw "BINARY_SEED_FALLBACK=FAIL expected=$fallbackExpectedSwfSha actual=$fallbackSwfSha"}
Write-Host "BINARY_SEED_FALLBACK=PASS release=v23 sha256=$fallbackSwfSha"

$appContentSwf='iArmyAirOfflineSavingv23.swf'
$canonicalSwfSha='99a7e8c219610eabbe97aee74228d52ded1532b4c2d4310432d15082b2ff11c4'
$swfSha=$publishedSwfSha
$swfSize=$publishedSwfInfo.Length
if($swfSha -ne $canonicalSwfSha){throw "SWF_ORIGINAL=FAIL expected=$canonicalSwfSha actual=$swfSha"}
Copy-Item -LiteralPath $publishedSwf -Destination (Join-Path $stage $appContentSwf) -Force
$stagedSwf=Join-Path $stage $appContentSwf
$stagedSwfSha=(Get-FileHash -LiteralPath $stagedSwf -Algorithm SHA256).Hash.ToLowerInvariant()
if($stagedSwfSha -ne $canonicalSwfSha){throw "SWF_ORIGINAL=FAIL staged expected=$canonicalSwfSha actual=$stagedSwfSha"}
Write-Host "SWF_ORIGINAL=PASS sha256=$canonicalSwfSha size=$swfSize bytecode_modified=false"
Write-Host "BINARY_SEED=PASS source=published_v23_2 repository=Valverde-101/Test_army_attack source_sha=$publishedActualSha swf_sha256=$swfSha size=$swfSize"

$extensionsDir=Join-Path $buildRoot 'extensions'
if(Test-Path -LiteralPath $extensionsDir){Remove-Item -LiteralPath $extensionsDir -Recurse -Force}
New-Item -ItemType Directory -Force -Path $extensionsDir|Out-Null
$aneBuilder=Join-Path $RepoRoot 'Tools\CI\Build-AndroidDiagnosticsAne.ps1'
if(-not (Test-Path -LiteralPath $aneBuilder)){throw "NATIVE_PERF_OVERLAY=FAIL ane_builder_missing=$aneBuilder"}
$aneResult=@(& $aneBuilder -RepoRoot $RepoRoot -AirRoot $air.Root -AndroidSdkRoot $androidSdk -OutputDirectory $extensionsDir -RootSwfPath $publishedSwf | ForEach-Object{$_.ToString()})
$diagnosticsAne=($aneResult|Where-Object{$_ -like '*.ane'}|Select-Object -Last 1)
if(-not $diagnosticsAne -or -not (Test-Path -LiteralPath $diagnosticsAne)){throw "NATIVE_PERF_OVERLAY=FAIL ane_missing output=$($aneResult -join ';')"}
$diagnosticsAneSha=(Get-FileHash -LiteralPath $diagnosticsAne -Algorithm SHA256).Hash.ToLowerInvariant()
$diagnosticsAneSize=(Get-Item -LiteralPath $diagnosticsAne).Length
Write-Host "NATIVE_PERF_OVERLAY_ANE=PASS path=$diagnosticsAne sha256=$diagnosticsAneSha size=$diagnosticsAneSize"

foreach($name in @('data','config')){
  $base=Join-Path $sourceRoot $name
  $dest=Join-Path $stage $name
  Copy-Item -LiteralPath $base -Destination $dest -Recurse -Force

  $publishedBase=Join-Path $publishedGameRoot $name
  if(-not (Test-Path -LiteralPath $publishedBase)){throw "PUBLISHED_CONTENT=FAIL missing_component=$name"}
  foreach($child in @(Get-ChildItem -LiteralPath $publishedBase -Force)){
    Copy-Item -LiteralPath $child.FullName -Destination $dest -Recurse -Force
  }
  Write-Host "ANDROID_CONTENT_OVERLAY=PASS source=published_v23_2 component=$name"

  $owned=Join-Path (Join-Path $RepoRoot 'src') $name
  foreach($child in @(Get-ChildItem -LiteralPath $owned -Force)){
    Copy-Item -LiteralPath $child.FullName -Destination $dest -Recurse -Force
  }
  Write-Host "ANDROID_CONTENT_OVERLAY=PASS source=principal_repo component=$name"
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
  <versionNumber>23.2.0</versionNumber>
  <versionLabel>23.2-android-$($ExpectedSha.Substring(0,8))</versionLabel>
  <filename>ArmyAttack</filename>
  <name>Army Attack</name>
  <initialWindow>
    <content>$appContentSwf</content>
    <visible>true</visible>
    <fullScreen>true</fullScreen>
    <aspectRatio>landscape</aspectRatio>
    <renderMode>$renderMode</renderMode>
    <autoOrients>false</autoOrients>
  </initialWindow>
  <extensions>
    <extensionID>com.valverde.armyattack.diagnostics</extensionID>
  </extensions>
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
        <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="$targetApi"/>
        <uses-feature android:glEsVersion="0x00020000" android:required="true"/>
        <application android:hardwareAccelerated="true" android:usesCleartextTraffic="false">
          <provider android:name="com.valverde.armyattack.diagnostics.DiagnosticsProvider" android:authorities="air.army.attack.armyattackdiagnostics" android:exported="false" android:grantUriPermissions="true"/>
          <meta-data android:name="armyattack.tested_sha" android:value="$ExpectedSha"/>
          <meta-data android:name="armyattack.render_mode" android:value="$renderMode"/>
          <meta-data android:name="armyattack.perf_overlay" android:value="true"/>
        </application>
      </manifest>
    ]]></manifestAdditions>
  </android>
</application>
"@
$xml|Set-Content -LiteralPath $descriptor -Encoding UTF8
Write-Host "ANDROID_DESCRIPTOR=PASS namespace=$namespace permissions=none discord_ane=excluded render_mode=$renderMode native_perf_overlay=true"
$cert=Join-Path $buildRoot 'android-ci-signing.p12'
$certPass='ArmyAttackLocalCI'
if(Test-Path $cert){Remove-Item $cert -Force}
$tier=if($air.Major -eq 50){'HARMAN_AIR50_ARM64'}elseif($air.Major -ge 51){'MODERN_ARM64'}else{'LEGACY_AIR32_TEST'}
$apkName=if($harmanAndroid){"ArmyAttack-android-arm64-$renderMode.apk"}else{"ArmyAttack-android-legacy-$renderMode.apk"}
$apkPath=Join-Path $buildRoot $apkName
$stdout=Join-Path $buildRoot 'adt-android.out.log';$stderr=Join-Path $buildRoot 'adt-android.err.log'
try{
  $certArgs=@('-certificate','-cn','ArmyAttackAndroidCI','-ou','Dev','-o','ValverdeLocalBuild','-c','PE','2048-RSA',$cert,$certPass)
  $p=Start-Process -FilePath $air.Adt -ArgumentList $certArgs -WorkingDirectory $buildRoot -NoNewWindow -PassThru -Wait
  if($p.ExitCode -ne 0 -or -not (Test-Path $cert)){throw "ANDROID_CERT=FAIL exit=$($p.ExitCode)"}
  Write-Host "ANDROID_CERT=PASS"
  if(Test-Path $apkPath){Remove-Item $apkPath -Force}
  $packageArgs=@('-package','-target','apk-captive-runtime')
  if($harmanAndroid){$packageArgs+=@('-arch','armv8')}
  $packageArgs+=@('-storetype','pkcs12','-keystore',$cert,'-storepass',$certPass,$apkPath,$descriptor,'-extdir',$extensionsDir,'-C',$stage,'.')
  if($harmanAndroid){$packageArgs+=@('-platformsdk',$packageAndroidSdk)}
  $p2=Start-Process -FilePath $air.Adt -ArgumentList $packageArgs -WorkingDirectory $buildRoot -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  if($p2.ExitCode -ne 0 -or -not (Test-Path $apkPath)){
    Write-Host "ANDROID_PACKAGE=FAIL exit=$($p2.ExitCode) tier=$tier stdout=$stdout stderr=$stderr"
    if(Test-Path $stdout){Get-Content $stdout|Select-Object -Last 80|ForEach-Object{Write-Host $_}}
    if(Test-Path $stderr){Get-Content $stderr|Select-Object -Last 80|ForEach-Object{Write-Host $_}}
    throw 'BUILD=FAIL android_package'
  }
}finally{
  Remove-Item -LiteralPath $cert -Force -ErrorAction SilentlyContinue
  Write-Host "ANDROID_CERT_CLEANUP=PASS"
}
$apk=Get-Item $apkPath;$apkSha=(Get-FileHash $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$prov=[ordered]@{
  repository='Valverde-101/code-army-client'
  tested_sha=$ExpectedSha
  build_tier=$tier
  air_sdk=$air.Version
  air_sdk_root=$air.Root
  air_namespace=$namespace
  java_home=$env:JAVA_HOME
  java_major=$javaMajor
  android_sdk=$androidSdk
  packaging_android_sdk=$packageAndroidSdk
  target_android_api=$targetApi
  target_abi=$targetAbi
  game_version='23.2'
  binary_seed='published_v23_2'
  binary_seed_source_repository='Valverde-101/Test_army_attack'
  binary_seed_source_sha=$publishedActualSha
  binary_seed_source_path='armyattack/assets/iArmyAirOfflineSavingv23.swf'
  app_content_swf=$appContentSwf
  swf_source_size=$swfSize
  swf_source_sha256=$swfSha
  swf_size=$swfSize
  swf_sha256=$swfSha
  swf_performance_patched=$false
  performance_patch_version='none'
  render_mode=$renderMode
  native_performance_overlay=$true
  native_performance_overlay_mode='test-low-overhead-v2'
  native_performance_overlay_sample_ms=1000
  native_performance_overlay_heavy_sample_ms=5000
  physical_validation_method='manual'
  adb_validation_enabled=$false
  native_performance_overlay_metrics=@('process_cpu','pss','java_heap','native_heap','gc_count','gc_time','thermal','vsync_jank')
  diagnostics_ane_sha256=$diagnosticsAneSha
  fallback_binary_seed_release='v23'
  fallback_binary_seed_source_sha='324c29b6c9e0e32f61183bf52725662a2bd8aab9'
  fallback_swf_sha256=$fallbackSwfSha
  overlays=@(
    'verified-v23-release:data,config',
    'vendor/Test_army_attack@306bccc7:armyattack/data,armyattack/config',
    'src/data,src/config'
  )
  content_mode='base-only-modern-v23.2'
  mods_source_path='vendor/Test_army_attack/mods'
  mods_packaged_by_default=$false
  selector_packaged=$false
  diagnostics_ane_packaged=$true
  descriptor=$descriptor
  removed_permissions=@('WRITE_EXTERNAL_STORAGE','MANAGE_EXTERNAL_STORAGE')
  excluded_extensions=@('fi.joniaromaa.adobeair.discordrpc')
  apk_path=$apkPath
  apk_size=$apk.Length
  apk_sha256=$apkSha
}
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
  packaging_android_sdk=$packageAndroidSdk
  android_api=$targetApi
  android_build_tools=$targetBuildTools
  target_abi=$targetAbi
}
$toolchainPath=Join-Path $buildRoot 'TOOLCHAIN.json'
$toolchain|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $toolchainPath -Encoding UTF8
Write-Host "BASE_ONLY_BUILD=PASS version=23.2 root_swf=$appContentSwf mods=false selector=false diagnostics_ane=true swf_original=true native_perf_overlay=true render_mode=$renderMode"
Write-Host "BUILD=PASS platform=android tier=$tier"
Write-Host "APK_GENERATED=PASS"
Write-Host "APK_PATH=$apkPath"
Write-Host "APK_SIZE=$($apk.Length)"
Write-Host "APK_SHA256=$apkSha"
Write-Host "SWF_SOURCE_SHA256=$swfSha"
Write-Host "SWF_SHA256=$swfSha"
Write-Host "SWF_SIZE=$swfSize"
Write-Host "NATIVE_PERF_OVERLAY=PASS buttons=PERF,INICIAR,MARCAR_LAG,DETENER,ZIP render_mode=$renderMode profiler=low_overhead_v2 ane_sha256=$diagnosticsAneSha"
Write-Host "PUBLISHED_SOURCE_SHA=$publishedActualSha"
Write-Host "GAME_VERSION=$publishedVersion"
Write-Host "AIR_VERSION=$($air.Version)"
$playReady=if($harmanAndroid){'CANDIDATE'}else{'NO_LEGACY_TOOLCHAIN'}
Write-Host "PLAY_READY=$playReady"
Write-Host "PROVENANCE_MANIFEST=$provPath"
Write-Host "TOOLCHAIN_MANIFEST=$toolchainPath"
