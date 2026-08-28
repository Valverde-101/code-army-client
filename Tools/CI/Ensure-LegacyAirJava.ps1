param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$releaseTag='jdk8u292-b10'
$asset='OpenJDK8U-jdk_x64_windows_hotspot_8u292b10.zip'
$baseUrl="https://github.com/AdoptOpenJDK/openjdk8-binaries/releases/download/$releaseTag"
$archiveUrl="$baseUrl/$asset"
$checksumUrl="$archiveUrl.sha256.txt"
$javaRoot=Join-Path $AndroidBuildRoot 'Tools\Java'
$cacheRoot=Join-Path $AndroidBuildRoot 'Downloads\Java'
$installRoot=Join-Path $javaRoot 'adoptopenjdk8u292-b10'
$archivePath=Join-Path $cacheRoot $asset
$checksumPath="$archivePath.sha256.txt"
$probeRoot=Join-Path $AndroidBuildRoot 'Builds\code-army-client\toolchain-probes'

foreach($dir in @($javaRoot,$cacheRoot,$probeRoot)){
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

function Invoke-Download([string]$Uri,[string]$Destination){
  $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
  if($curl){
    & $curl.Source -L --fail --retry 3 --retry-delay 2 -o $Destination $Uri
    if($LASTEXITCODE -ne 0){throw "TOOLCHAIN_DOWNLOAD=FAIL uri=$Uri exit=$LASTEXITCODE"}
  }else{
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
  }
}

function Get-Java8Probe([string]$Home){
  $exe=Join-Path $Home 'bin\java.exe'
  if(-not (Test-Path -LiteralPath $exe)){return $null}
  $stamp=[Guid]::NewGuid().ToString('N')
  $out=Join-Path $probeRoot "java8-$stamp.out.log"
  $err=Join-Path $probeRoot "java8-$stamp.err.log"
  $p=Start-Process -FilePath $exe -ArgumentList '-version' -NoNewWindow -PassThru -Wait -RedirectStandardOutput $out -RedirectStandardError $err
  $lines=@()
  foreach($file in @($out,$err)){if(Test-Path -LiteralPath $file){$lines+=@(Get-Content -LiteralPath $file)}}
  $text=($lines -join "`n")
  if($p.ExitCode -ne 0){return $null}
  if($text -notmatch 'version\s+"1\.8\.0_292"'){return $null}
  return [pscustomobject]@{Exe=$exe;VersionText=$text;ExitCode=$p.ExitCode}
}

$probe=Get-Java8Probe $installRoot
if(-not $probe){
  $needDownload=$true
  if((Test-Path -LiteralPath $archivePath) -and (Test-Path -LiteralPath $checksumPath)){
    $expected=((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($expected -match '^[0-9a-f]{64}$' -and $actual -eq $expected){$needDownload=$false}
  }
  if($needDownload){
    Remove-Item -LiteralPath $archivePath,$checksumPath -Force -ErrorAction SilentlyContinue
    Write-Host "AIR_LEGACY_JAVA_DOWNLOAD=START tag=$releaseTag asset=$asset"
    Invoke-Download $archiveUrl $archivePath
    Invoke-Download $checksumUrl $checksumPath
  }
  $expected=((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
  if($expected -notmatch '^[0-9a-f]{64}$'){throw 'AIR_LEGACY_JAVA_CHECKSUM=FAIL invalid_sidecar'}
  $actual=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if($actual -ne $expected){throw "AIR_LEGACY_JAVA_CHECKSUM=FAIL expected=$expected actual=$actual"}
  Write-Host "AIR_LEGACY_JAVA_CHECKSUM=PASS sha256=$actual"

  $temp=Join-Path $javaRoot (".extract-java8-"+[Guid]::NewGuid().ToString('N'))
  if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  try{
    Expand-Archive -LiteralPath $archivePath -DestinationPath $temp -Force
    $javaExe=Get-ChildItem -LiteralPath $temp -Recurse -File -Filter 'java.exe' -ErrorAction Stop |
      Where-Object { $_.FullName -match '\\bin\\java\.exe$' } |
      Sort-Object FullName | Select-Object -First 1
    if(-not $javaExe){throw 'AIR_LEGACY_JAVA_EXTRACT=FAIL java.exe_not_found'}
    $sourceHome=Split-Path -Parent (Split-Path -Parent $javaExe.FullName)
    if(Test-Path -LiteralPath $installRoot){Remove-Item -LiteralPath $installRoot -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceHome '*') -Destination $installRoot -Recurse -Force
  }finally{
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
  $probe=Get-Java8Probe $installRoot
  if(-not $probe){throw "AIR_LEGACY_JAVA=FAIL installed_java8_probe path=$installRoot"}
}

$archiveSha=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
$env:JAVA_HOME=$installRoot
$env:JAVA_TOOL_OPTIONS=''
if($env:GITHUB_ENV){
  "JAVA_HOME=$installRoot" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
  'JAVA_TOOL_OPTIONS=' | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
}
Write-Host "AIR_LEGACY_JAVA=PASS path=$installRoot version=1.8.0_292"
if($archiveSha){Write-Host "AIR_LEGACY_JAVA_ARCHIVE_SHA256=$($archiveSha.ToLowerInvariant())"}
Write-Host "AIR_LEGACY_JAVA_SOURCE=$archiveUrl"
