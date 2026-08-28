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

function Invoke-Download([string]$Uri,[string]$Destination){
  $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
  if($curl){
    & $curl.Source -L --fail --retry 3 --retry-delay 2 -o $Destination $Uri
    if($LASTEXITCODE -ne 0){throw "HARMAN_AIR_DOWNLOAD=FAIL exit=$LASTEXITCODE"}
  } else {
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
  }
}

function Select-ModernJava {
  $candidates=@(
    (Join-Path $AndroidBuildRoot 'Tools\Java\jdk-21\bin\java.exe'),
    (Join-Path $AndroidBuildRoot 'Tools\Java\jdk-17\bin\java.exe')
  )
  $cmd=Get-Command java.exe -ErrorAction SilentlyContinue
  if($cmd){$candidates+=$cmd.Source}
  foreach($candidate in $candidates){
    if(-not $candidate -or -not (Test-Path -LiteralPath $candidate)){continue}
    $out=Join-Path $probeRoot ("harman-java-"+[Guid]::NewGuid().ToString('N')+".out.log")
    $err=Join-Path $probeRoot ("harman-java-"+[Guid]::NewGuid().ToString('N')+".err.log")
    $p=Start-Process -FilePath $candidate -ArgumentList @('-XshowSettings:properties','-version') -NoNewWindow -PassThru -Wait -RedirectStandardOutput $out -RedirectStandardError $err
    $lines=@()
    foreach($file in @($out,$err)){if(Test-Path -LiteralPath $file){$lines+=@(Get-Content -LiteralPath $file)}}
    $text=($lines -join [Environment]::NewLine)
    if($p.ExitCode -ne 0){continue}
    $major=0
    if($text -match 'version\s+"(?<major>\d+)(?:\.(?<minor>\d+))?'){
      $major=[int]$matches['major']
      if($major -eq 1 -and $matches['minor']){$major=[int]$matches['minor']}
    }
    $javaHome=$null
    if($text -match '(?m)^\s*java\.home\s*=\s*(?<home>.+?)\s*$'){$javaHome=$matches['home'].Trim()}
    if(-not $javaHome){
      $derived=Split-Path -Parent (Split-Path -Parent $candidate)
      if(Test-Path -LiteralPath (Join-Path $derived 'bin\java.exe')){$javaHome=$derived}
    }
    if($major -ge 11 -and $javaHome -and (Test-Path -LiteralPath (Join-Path $javaHome 'bin\java.exe'))){
      return [pscustomobject]@{Exe=(Join-Path $javaHome 'bin\java.exe');Home=$javaHome;Major=$major;VersionText=$text}
    }
  }
  throw 'HARMAN_AIR_JAVA=FAIL requires_jdk_11_or_newer_with_valid_home'
}

function Probe-Air([string]$Root,[string]$ExpectedVersion,[pscustomobject]$JavaInfo){
  $adt=Join-Path $Root 'bin\adt.bat'
  if(-not (Test-Path -LiteralPath $adt)){return $null}
  $oldJavaHome=$env:JAVA_HOME
  $oldPath=$env:PATH
  try{
    $env:JAVA_HOME=$JavaInfo.Home
    $env:PATH="$(Join-Path $JavaInfo.Home 'bin');$oldPath"
    $previous=$ErrorActionPreference
    try{
      $ErrorActionPreference='Continue'
      $lines=@(& $adt -version 2>&1 | ForEach-Object {$_.ToString()})
      $exit=$LASTEXITCODE
    } finally {$ErrorActionPreference=$previous}
  } finally {
    $env:JAVA_HOME=$oldJavaHome
    $env:PATH=$oldPath
  }
  $text=($lines -join [Environment]::NewLine).Trim()
  if($exit -ne 0){return $null}
  if($text -notmatch [regex]::Escape($ExpectedVersion)){return $null}
  return [pscustomobject]@{Adt=$adt;VersionText=$text;ExitCode=$exit}
}

$java=Select-ModernJava
Write-Host "HARMAN_AIR_JAVA=PASS path=$($java.Exe) home=$($java.Home) major=$($java.Major)"
$probe=Probe-Air $installRoot $version $java

if(-not $probe){
  if(-not (Test-Path -LiteralPath $archivePath)){
    Write-Host "HARMAN_AIR_DOWNLOAD=START version=$version"
    Invoke-Download $downloadUrl $archivePath
  }

  $archive=Get-Item -LiteralPath $archivePath
  if($archive.Length -lt 1000000){throw "HARMAN_AIR_ARCHIVE=FAIL suspicious_size=$($archive.Length)"}
  $archiveSha=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()

  if(Test-Path -LiteralPath $archiveHashPath){
    $pinned=(Get-Content -LiteralPath $archiveHashPath -Raw).Trim().ToLowerInvariant()
    if($pinned -match '^[0-9a-f]{64}$' -and $pinned -ne $archiveSha){
      throw "HARMAN_AIR_ARCHIVE=FAIL cached_sha_changed expected=$pinned actual=$archiveSha"
    }
  } else {
    $archiveSha | Set-Content -LiteralPath $archiveHashPath -Encoding ASCII
  }
  Write-Host "HARMAN_AIR_ARCHIVE=PASS size=$($archive.Length) sha256=$archiveSha"

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip=[System.IO.Compression.ZipFile]::OpenRead($archivePath)
  try{
    $adtEntry=$zip.Entries | Where-Object {$_.FullName -match '(^|/)bin/adt\.bat$'} | Select-Object -First 1
    $jarEntry=$zip.Entries | Where-Object {$_.FullName -match '(^|/)lib/adt\.jar$'} | Select-Object -First 1
    if(-not $adtEntry -or -not $jarEntry){throw 'HARMAN_AIR_ARCHIVE=FAIL missing_adt_payload'}
  } finally {$zip.Dispose()}

  $temp=Join-Path (Split-Path -Parent $installRoot) (".extract-air-"+[Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  try{
    Expand-Archive -LiteralPath $archivePath -DestinationPath $temp -Force
    $adtFile=Get-ChildItem -LiteralPath $temp -Recurse -File -Filter 'adt.bat' -ErrorAction Stop |
      Where-Object {$_.FullName -match '\\bin\\adt\.bat$'} | Sort-Object FullName | Select-Object -First 1
    if(-not $adtFile){throw 'HARMAN_AIR_EXTRACT=FAIL adt_not_found'}
    $sourceRoot=Split-Path -Parent (Split-Path -Parent $adtFile.FullName)
    if(Test-Path -LiteralPath $installRoot){Remove-Item -LiteralPath $installRoot -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    Get-ChildItem -LiteralPath $sourceRoot -Force | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $installRoot -Recurse -Force
    }
  } finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }

  $probe=Probe-Air $installRoot $version $java
  if(-not $probe){throw "HARMAN_AIR=FAIL adt_probe version=$version path=$installRoot"}
}

$archiveSha=''
$archiveSize=0
if(Test-Path -LiteralPath $archivePath){
  $archiveSha=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $archiveSize=(Get-Item -LiteralPath $archivePath).Length
}

$env:AIR_HOME=$installRoot
$env:JAVA_HOME=$java.Home
$javaBin=Join-Path $java.Home 'bin'
$env:PATH="$javaBin;$env:PATH"
if($env:GITHUB_ENV){
  "AIR_HOME=$installRoot" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "JAVA_HOME=$($java.Home)" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "HARMAN_AIR_VERSION=$version" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  "HARMAN_AIR_ARCHIVE_SHA256=$archiveSha" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
}
if($env:GITHUB_PATH){$javaBin | Out-File $env:GITHUB_PATH -Encoding utf8 -Append}

$state=[ordered]@{
  version=$version
  air_home=$installRoot
  adt=$probe.Adt
  java_home=$java.Home
  java_major=$java.Major
  archive_path=$archivePath
  archive_size=$archiveSize
  archive_sha256=$archiveSha
  source='HARMAN AIR SDK download API'
}
$statePath=Join-Path $probeRoot 'harman-air-50.2.3.6.json'
$state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

Write-Host "HARMAN_AIR=PASS version=$version root=$installRoot adt=$($probe.Adt)"
Write-Host "HARMAN_AIR_ARCHIVE_SHA256=$archiveSha"
Write-Host "HARMAN_AIR_STATE=$statePath"