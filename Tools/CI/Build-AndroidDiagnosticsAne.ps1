param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$AirRoot,
  [Parameter(Mandatory=$true)][string]$AndroidSdkRoot,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
$air=(Resolve-Path -LiteralPath $AirRoot).Path
$sdk=(Resolve-Path -LiteralPath $AndroidSdkRoot).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory|Out-Null
$out=(Resolve-Path -LiteralPath $OutputDirectory).Path

$compc=Join-Path $air 'bin\compc.bat'
$adt=Join-Path $air 'bin\adt.bat'
$androidJar=Join-Path $sdk 'platforms\android-33\android.jar'
$javaHome=$env:JAVA_HOME
if(-not $javaHome){throw 'DIAGNOSTICS_ANE=FAIL JAVA_HOME_missing'}
$javac=Join-Path $javaHome 'bin\javac.exe'
$jarTool=Join-Path $javaHome 'bin\jar.exe'
foreach($required in @($compc,$adt,$androidJar,$javac,$jarTool)){
  if(-not (Test-Path -LiteralPath $required)){throw "DIAGNOSTICS_ANE=FAIL missing=$required"}
}

$freJarCandidates=@(
  (Join-Path $air 'lib\android\FlashRuntimeExtensions.jar'),
  (Join-Path $air 'lib\FlashRuntimeExtensions.jar')
)
$freJar=$freJarCandidates|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1
if(-not $freJar){
  $freJar=Get-ChildItem -LiteralPath $air -Recurse -File -Filter 'FlashRuntimeExtensions.jar' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if(-not $freJar){throw 'DIAGNOSTICS_ANE=FAIL FlashRuntimeExtensions.jar_not_found'}

$srcRoot=Join-Path $repo 'android\native\diagnostics'
$as3Root=Join-Path $srcRoot 'as3'
$javaRoot=Join-Path $srcRoot 'java'
foreach($required in @($as3Root,$javaRoot)){
  if(-not (Test-Path -LiteralPath $required)){throw "DIAGNOSTICS_ANE=FAIL source_missing=$required"}
}

$work=Join-Path $out 'diagnostics-ane-build'
if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
$classes=Join-Path $work 'classes'
$arm=Join-Path $work 'Android-ARM'
$arm64=Join-Path $work 'Android-ARM64'
New-Item -ItemType Directory -Force -Path $work,$classes,$arm,$arm64|Out-Null

$swc=Join-Path $work 'ArmyAttackDiagnostics.swc'
$compcArgs=@("-source-path+=$as3Root",'-include-classes=com.valverde.armyattack.diagnostics.DiagnosticsMarker',"-output=$swc")
& $compc @compcArgs
if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $swc)){throw "DIAGNOSTICS_ANE=FAIL compc_exit=$LASTEXITCODE"}
Write-Host "DIAGNOSTICS_ANE_SWC=PASS path=$swc"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$swcZip=[IO.Compression.ZipFile]::OpenRead($swc)
try{
  $swcNames=@($swcZip.Entries|ForEach-Object{$_.FullName})
  if(-not ($swcNames -contains 'library.swf')){throw 'DIAGNOSTICS_ANE=FAIL swc_library_missing'}
  $libraryEntry=@($swcZip.Entries|Where-Object{$_.FullName -eq 'library.swf'})|Select-Object -First 1
  if(-not $libraryEntry){throw 'DIAGNOSTICS_ANE=FAIL swc_library_entry_missing'}
  foreach($platformRoot in @($arm,$arm64)){
    $platformLibrary=Join-Path $platformRoot 'library.swf'
    [IO.Compression.ZipFileExtensions]::ExtractToFile($libraryEntry,$platformLibrary,$true)
    if(-not (Test-Path -LiteralPath $platformLibrary)){throw "DIAGNOSTICS_ANE=FAIL platform_library_missing=$platformLibrary"}
    $platformLibrarySha=(Get-FileHash -LiteralPath $platformLibrary -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "DIAGNOSTICS_ANE_LIBRARY_STAGE=PASS platform=$(Split-Path -Leaf $platformRoot) sha256=$platformLibrarySha path=$platformLibrary"
  }
}finally{$swcZip.Dispose()}
$swcSha=(Get-FileHash -LiteralPath $swc -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "DIAGNOSTICS_ANE_SWC_VALIDATE=PASS library_swF=true sha256=$swcSha"

$javaFiles=@(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java'|Select-Object -ExpandProperty FullName)
if($javaFiles.Count -lt 2){throw "DIAGNOSTICS_ANE=FAIL java_source_count=$($javaFiles.Count)"}
$classPath=$freJar+';'+$androidJar
& $javac '-source' '8' '-target' '8' '-encoding' 'UTF-8' '-classpath' $classPath '-d' $classes @javaFiles
if($LASTEXITCODE -ne 0){throw "DIAGNOSTICS_ANE=FAIL javac_exit=$LASTEXITCODE"}
Write-Host "DIAGNOSTICS_ANE_JAVA=PASS source_count=$($javaFiles.Count)"

$nativeJar=Join-Path $work 'armyattack-diagnostics.jar'
& $jarTool 'cf' $nativeJar '-C' $classes '.'
if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $nativeJar)){throw "DIAGNOSTICS_ANE=FAIL jar_exit=$LASTEXITCODE"}
$jarEntries=@(& $jarTool 'tf' $nativeJar 2>&1|ForEach-Object{$_.ToString()})
if($LASTEXITCODE -ne 0){throw "DIAGNOSTICS_ANE=FAIL jar_list_exit=$LASTEXITCODE"}
foreach($requiredClass in @(
  'com/valverde/armyattack/diagnostics/DiagnosticsExtension.class',
  'com/valverde/armyattack/diagnostics/DiagnosticsProvider.class'
)){
  if(-not ($jarEntries -contains $requiredClass)){throw "DIAGNOSTICS_ANE=FAIL native_class_missing=$requiredClass"}
}
$nativeJarSha=(Get-FileHash -LiteralPath $nativeJar -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "DIAGNOSTICS_ANE_CLASSES=PASS extension=true provider=true jar_sha256=$nativeJarSha"
Copy-Item -LiteralPath $nativeJar -Destination (Join-Path $arm 'armyattack-diagnostics.jar') -Force
Copy-Item -LiteralPath $nativeJar -Destination (Join-Path $arm64 'armyattack-diagnostics.jar') -Force
$extensionXml=Join-Path $work 'extension.xml'
$xml=@'
<?xml version="1.0" encoding="utf-8"?>
<extension xmlns="http://ns.adobe.com/air/extension/50.2">
  <id>com.valverde.armyattack.diagnostics</id>
  <versionNumber>1.0.0</versionNumber>
  <platforms>
    <platform name="Android-ARM">
      <applicationDeployment>
        <nativeLibrary>armyattack-diagnostics.jar</nativeLibrary>
        <initializer>com.valverde.armyattack.diagnostics.DiagnosticsExtension</initializer>
        <finalizer>com.valverde.armyattack.diagnostics.DiagnosticsExtension</finalizer>
      </applicationDeployment>
    </platform>
    <platform name="Android-ARM64">
      <applicationDeployment>
        <nativeLibrary>armyattack-diagnostics.jar</nativeLibrary>
        <initializer>com.valverde.armyattack.diagnostics.DiagnosticsExtension</initializer>
        <finalizer>com.valverde.armyattack.diagnostics.DiagnosticsExtension</finalizer>
      </applicationDeployment>
    </platform>
  </platforms>
</extension>
'@
$xml|Set-Content -LiteralPath $extensionXml -Encoding UTF8
if($xml -match 'platform name="default"'){throw 'DIAGNOSTICS_ANE=FAIL unexpected_default_platform'}
if($xml -notmatch 'platform name="Android-ARM"' -or $xml -notmatch 'platform name="Android-ARM64"'){
  throw 'DIAGNOSTICS_ANE=FAIL android_platform_contract'
}
Write-Host 'DIAGNOSTICS_ANE_PLATFORM_CONTRACT=PASS platforms=Android-ARM,Android-ARM64 default=false'

$ane=Join-Path $out 'ArmyAttackDiagnostics.ane'
if(Test-Path -LiteralPath $ane){Remove-Item -LiteralPath $ane -Force}
$aneArgs=@('-package','-target','ane',$ane,$extensionXml,'-swc',$swc,'-platform','Android-ARM','-C',$arm,'.','-platform','Android-ARM64','-C',$arm64,'.')
$adtLog=Join-Path $work 'adt-ane.log'
$adtLines=@(& $adt @aneArgs 2>&1|ForEach-Object{$_.ToString()})
$adtExit=$LASTEXITCODE
$adtLines|Set-Content -LiteralPath $adtLog -Encoding UTF8
if($adtExit -ne 0 -or -not (Test-Path -LiteralPath $ane)){
  $adtLines|Select-Object -Last 80|ForEach-Object{Write-Host $_}
  throw "DIAGNOSTICS_ANE=FAIL adt_exit=$adtExit log=$adtLog"
}
Write-Host "DIAGNOSTICS_ANE_ADT=PASS log=$adtLog"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($ane)
try{
  $names=@($zip.Entries|ForEach-Object{$_.FullName})
  foreach($required in @(
    'META-INF/ANE/extension.xml',
    'META-INF/ANE/Android-ARM/library.swf',
    'META-INF/ANE/Android-ARM/armyattack-diagnostics.jar',
    'META-INF/ANE/Android-ARM64/library.swf',
    'META-INF/ANE/Android-ARM64/armyattack-diagnostics.jar'
  )){
    if(-not ($names -contains $required)){throw "DIAGNOSTICS_ANE=FAIL packaged_entry_missing=$required"}
  }
}finally{$zip.Dispose()}

$sha=(Get-FileHash -LiteralPath $ane -Algorithm SHA256).Hash.ToLowerInvariant()
$size=(Get-Item -LiteralPath $ane).Length
Write-Host "DIAGNOSTICS_ANE=PASS path=$ane size=$size sha256=$sha fre_jar=$freJar"
Write-Output $ane
