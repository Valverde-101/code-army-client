param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$version='17.0.19_10'
$tag='jdk-17.0.19%2B10'
$asset="OpenJDK17U-jdk_x64_windows_hotspot_$version.zip"
$base="https://github.com/adoptium/temurin17-binaries/releases/download/$tag"
$downloadRoot=Join-Path $AndroidBuildRoot 'Downloads\Java'
$archive=Join-Path $downloadRoot $asset
$checksumFile="$archive.sha256.txt"
$installRoot=Join-Path $AndroidBuildRoot 'Tools\Java\jdk-17'
New-Item -ItemType Directory -Force -Path $downloadRoot,(Split-Path -Parent $installRoot) | Out-Null

function Download([string]$url,[string]$dest){
  $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
  if($curl){
    & $curl.Source -L --fail --retry 3 --retry-delay 2 -o $dest $url
    if($LASTEXITCODE -ne 0){throw "JDK17_DOWNLOAD=FAIL exit=$LASTEXITCODE url=$url"}
  } else {
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
  }
}

if(-not (Test-Path -LiteralPath $archive)){Download "$base/$asset" $archive}
if(-not (Test-Path -LiteralPath $checksumFile)){Download "$base/$asset.sha256.txt" $checksumFile}
$expected=((Get-Content -LiteralPath $checksumFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
if($expected -notmatch '^[0-9a-f]{64}$'){throw 'JDK17_CHECKSUM=FAIL invalid_official_checksum'}
$actual=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if($actual -ne $expected){throw "JDK17_CHECKSUM=FAIL expected=$expected actual=$actual"}
Write-Host "JDK17_ARCHIVE=PASS sha256=$actual"

$javaExe=Join-Path $installRoot 'bin\java.exe'
if(-not (Test-Path -LiteralPath $javaExe)){
  $temp=Join-Path (Split-Path -Parent $installRoot) ('.extract-jdk17-'+[Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  try {
    Expand-Archive -LiteralPath $archive -DestinationPath $temp -Force
    $found=Get-ChildItem -LiteralPath $temp -Recurse -File -Filter java.exe | Where-Object {$_.FullName -match '\\bin\\java\.exe$'} | Select-Object -First 1
    if(-not $found){throw 'JDK17_EXTRACT=FAIL java_not_found'}
    $root=Split-Path -Parent (Split-Path -Parent $found.FullName)
    if(Test-Path -LiteralPath $installRoot){Remove-Item -LiteralPath $installRoot -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    Get-ChildItem -LiteralPath $root -Force | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination $installRoot -Recurse -Force}
  } finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$probeRoot=Join-Path $AndroidBuildRoot 'Builds\code-army-client\toolchain-probes'
New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
$probeOut=Join-Path $probeRoot 'jdk17-version.out.log'
$probeErr=Join-Path $probeRoot 'jdk17-version.err.log'
$p=Start-Process -FilePath $javaExe -ArgumentList '-version' -NoNewWindow -PassThru -Wait -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr
$probeLines=@()
foreach($probeFile in @($probeOut,$probeErr)){if(Test-Path -LiteralPath $probeFile){$probeLines+=@(Get-Content -LiteralPath $probeFile)}}
$probeText=($probeLines -join [Environment]::NewLine)
if($p.ExitCode -ne 0 -or $probeText -notmatch 'version "17\.'){throw "JDK17_PROBE=FAIL exit=$($p.ExitCode)"}
$env:JAVA_HOME=$installRoot
$env:PATH="$(Join-Path $installRoot 'bin');$env:PATH"
if($env:GITHUB_ENV){"JAVA_HOME=$installRoot"|Out-File $env:GITHUB_ENV -Encoding utf8 -Append}
if($env:GITHUB_PATH){(Join-Path $installRoot 'bin')|Out-File $env:GITHUB_PATH -Encoding utf8 -Append}
Write-Host "JDK17=PASS version=17.0.19+10 home=$installRoot sha256=$actual source=Eclipse_Temurin"
