param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$version='50.2.3.6'
$asset='AIRSDK_Windows.zip'
$downloadUrl="https://airsdk.harman.com/api/versions/$version/sdks/${asset}?license=accepted"
$downloadRoot=Join-Path $AndroidBuildRoot 'Downloads\AIR'
$archivePath=Join-Path $downloadRoot "AIRSDK_Windows_$version.zip"
$archiveHashPath="$archivePath.sha256.local"
$installRoot=Join-Path $AndroidBuildRoot "Tools\AIRSDK-$version"
$probeRoot=Join-Path $AndroidBuildRoot 'Builds\code-army-client\toolchain-probes'
New-Item -ItemType Directory -Force -Path $downloadRoot,$probeRoot,(Split-Path -Parent $installRoot) | Out-Null

# AIR 50.2.3.6 invokes Gradle 7.5 for Android packaging. Gradle 7.5 cannot run on Java 22
# (class-file major 66), so use a pinned portable Java 17 runtime for the AIR/Gradle path.
& (Join-Path $PSScriptRoot 'Ensure-PortableJdk17.ps1') -AndroidBuildRoot $AndroidBuildRoot
$javaHome=Join-Path $AndroidBuildRoot 'Tools\Java\jdk-17'
$javaExe=Join-Path $javaHome 'bin\java.exe'
if(-not (Test-Path -LiteralPath $javaExe)){throw 'HARMAN_AIR_JAVA=FAIL portable_jdk17_missing'}
$javaProbeOut=Join-Path $probeRoot 'java17-properties.out.log'
$javaProbeErr=Join-Path $probeRoot 'java17-properties.err.log'
$pJava=Start-Process -FilePath $javaExe -ArgumentList @('-XshowSettings:properties','-version') -NoNewWindow -PassThru -Wait -RedirectStandardOutput $javaProbeOut -RedirectStandardError $javaProbeErr
$javaLines=@()
foreach($probeFile in @($javaProbeOut,$javaProbeErr)){if(Test-Path -LiteralPath $probeFile){$javaLines+=@(Get-Content -LiteralPath $probeFile)}}
$javaText=($javaLines -join [Environment]::NewLine)
if($pJava.ExitCode -ne 0 -or $javaText -notmatch 'version "17\.'){throw "HARMAN_AIR_JAVA=FAIL expected_java17 exit=$($pJava.ExitCode)"}
$env:JAVA_HOME=$javaHome
$env:PATH="$(Join-Path $javaHome 'bin');$env:PATH"
if($env:GITHUB_ENV){"JAVA_HOME=$javaHome"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append}
if($env:GITHUB_PATH){(Join-Path $javaHome 'bin')|Out-File $env:GITHUB_PATH -Encoding utf8 -Append}
Write-Host "HARMAN_AIR_JAVA=PASS path=$javaExe home=$javaHome major=17 gradle_compat=7.5"

function Invoke-Download([string]$Uri,[string]$Destination){
  $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
  if($curl){
    & $curl.Source -L --fail --retry 3 --retry-delay 2 -o $Destination $Uri
    if($LASTEXITCODE -ne 0){throw "HARMAN_AIR_DOWNLOAD=FAIL exit=$LASTEXITCODE"}
  } else {Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing}
}

function Probe-Air([string]$Root){
  $adt=Join-Path $Root 'bin\adt.bat'
  if(-not (Test-Path -LiteralPath $adt)){return $null}
  $out=Join-Path $probeRoot 'adt-version.out.log';$err=Join-Path $probeRoot 'adt-version.err.log'
  $p=Start-Process -FilePath $adt -ArgumentList @('-version') -NoNewWindow -PassThru -Wait -RedirectStandardOutput $out -RedirectStandardError $err
  $text=@()
  if(Test-Path $out){$text+=Get-Content $out}
  if(Test-Path $err){$text+=Get-Content $err}
  $joined=($text -join [Environment]::NewLine).Trim()
  if($p.ExitCode -ne 0 -or $joined -notmatch [regex]::Escape($version)){return $null}
  return [pscustomobject]@{Adt=$adt;VersionText=$joined;ExitCode=$p.ExitCode}
}

$probe=Probe-Air $installRoot
if(-not $probe){
  if(-not (Test-Path -LiteralPath $archivePath)){Write-Host "HARMAN_AIR_DOWNLOAD=START version=$version";Invoke-Download $downloadUrl $archivePath}
  $archive=Get-Item -LiteralPath $archivePath
  if($archive.Length -lt 1000000){throw "HARMAN_AIR_ARCHIVE=FAIL suspicious_size=$($archive.Length)"}
  $archiveSha=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if(Test-Path -LiteralPath $archiveHashPath){
    $pinned=(Get-Content -LiteralPath $archiveHashPath -Raw).Trim().ToLowerInvariant()
    if($pinned -match '^[0-9a-f]{64}$' -and $pinned -ne $archiveSha){throw "HARMAN_AIR_ARCHIVE=FAIL cached_sha_changed expected=$pinned actual=$archiveSha"}
  } else {$archiveSha|Set-Content -LiteralPath $archiveHashPath -Encoding ASCII}
  $temp=Join-Path (Split-Path -Parent $installRoot) ('.extract-air-'+[Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $temp|Out-Null
  try {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $temp -Force
    $adtFile=Get-ChildItem -LiteralPath $temp -Recurse -File -Filter adt.bat|Where-Object{$_.FullName -match '\\bin\\adt\.bat$'}|Select-Object -First 1
    if(-not $adtFile){throw 'HARMAN_AIR_EXTRACT=FAIL adt_not_found'}
    $sourceRoot=Split-Path -Parent (Split-Path -Parent $adtFile.FullName)
    if(Test-Path -LiteralPath $installRoot){Remove-Item -LiteralPath $installRoot -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $installRoot|Out-Null
    Get-ChildItem -LiteralPath $sourceRoot -Force|ForEach-Object{Copy-Item -LiteralPath $_.FullName -Destination $installRoot -Recurse -Force}
  } finally {Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
  $probe=Probe-Air $installRoot
  if(-not $probe){throw 'HARMAN_AIR=FAIL adt_probe'}
}

$archiveSha='';$archiveSize=0
if(Test-Path -LiteralPath $archivePath){$archiveSha=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant();$archiveSize=(Get-Item $archivePath).Length}
$env:AIR_HOME=$installRoot
if($env:GITHUB_ENV){
  "AIR_HOME=$installRoot"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "JAVA_HOME=$javaHome"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "HARMAN_AIR_VERSION=$version"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "HARMAN_AIR_ARCHIVE_SHA256=$archiveSha"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append
}
$state=[ordered]@{version=$version;air_home=$installRoot;adt=$probe.Adt;java_home=$javaHome;java_major=17;gradle_runtime_compat='7.5';archive_path=$archivePath;archive_size=$archiveSize;archive_sha256=$archiveSha;source='HARMAN AIR SDK download API'}
$statePath=Join-Path $probeRoot 'harman-air-50.2.3.6.json'
$state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $statePath -Encoding UTF8
Write-Host "HARMAN_AIR=PASS version=$version root=$installRoot adt=$($probe.Adt)"
Write-Host "HARMAN_AIR_ARCHIVE_SHA256=$archiveSha"
Write-Host "HARMAN_AIR_STATE=$statePath"
