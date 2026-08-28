param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Find-FirstExisting([string[]]$Candidates) {
  foreach ($candidate in $Candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }
  return $null
}

function Find-CommandPath([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Find-AirTool([string]$Name) {
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($env:AIR_HOME) { $candidates.Add((Join-Path $env:AIR_HOME "bin\$Name")) }
  $fromPath = Find-CommandPath $Name
  if ($fromPath) { $candidates.Add($fromPath) }

  foreach ($base in @(
    (Join-Path $AndroidBuildRoot 'Tools'),
    (Join-Path $AndroidBuildRoot 'SDKs'),
    (Join-Path $AndroidBuildRoot 'AIR'),
    (Join-Path $AndroidBuildRoot 'AIRSDK')
  )) {
    if (-not (Test-Path -LiteralPath $base)) { continue }
    Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $candidates.Add((Join-Path $_.FullName "bin\$Name"))
    }
    $candidates.Add((Join-Path $base "bin\$Name"))
  }

  return Find-FirstExisting $candidates
}

function Find-Animate {
  $candidates = New-Object System.Collections.Generic.List[string]
  $programRoots = @(
    $env:ProgramFiles,
    [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  )
  foreach ($programRoot in $programRoots) {
    if (-not $programRoot) { continue }
    $adobe = Join-Path $programRoot 'Adobe'
    if (-not (Test-Path -LiteralPath $adobe)) { continue }
    Get-ChildItem -LiteralPath $adobe -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'Adobe Animate*' -or $_.Name -like 'Adobe Flash*' } |
      ForEach-Object {
        $candidates.Add((Join-Path $_.FullName 'Animate.exe'))
        $candidates.Add((Join-Path $_.FullName 'Flash.exe'))
      }
  }
  return Find-FirstExisting $candidates
}


function Ensure-AirSdk32 {
  $sdkRoot = Join-Path $AndroidBuildRoot 'Tools\AIRSDK-32'
  $compiler = Join-Path $sdkRoot 'bin\amxmlc.bat'
  $adtTool = Join-Path $sdkRoot 'bin\adt.bat'
  if ((Test-Path -LiteralPath $compiler) -and (Test-Path -LiteralPath $adtTool)) {
    Write-Host "AIRSDK_BOOTSTRAP=PASS existing=$sdkRoot"
    return $sdkRoot
  }

  $toolsRoot = Join-Path $AndroidBuildRoot 'Tools'
  New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null
  $zipPath = Join-Path $toolsRoot 'AIRSDK_Compiler_32.0.zip'
  $extractRoot = Join-Path $toolsRoot 'AIRSDK-32.extract'
  $url = 'https://airdownload.adobe.com/air/win/download/32.0/AIRSDK_Compiler.zip'

  if (-not (Test-Path -LiteralPath $zipPath) -or (Get-Item -LiteralPath $zipPath).Length -lt 100MB) {
    Write-Host "AIRSDK_DOWNLOAD=START url=$url path=$zipPath"
    $curl = Find-CommandPath 'curl.exe'
    if ($curl) {
      & $curl -L --fail --retry 3 --retry-delay 2 -o $zipPath $url
      if ($LASTEXITCODE -ne 0) { throw "AIRSDK_DOWNLOAD=FAIL curl_exit=$LASTEXITCODE" }
    }
    else {
      Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
    }
  }

  $zipInfo = Get-Item -LiteralPath $zipPath
  if ($zipInfo.Length -lt 100MB) {
    throw "AIRSDK_DOWNLOAD=FAIL unexpected_size=$($zipInfo.Length)"
  }
  $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Host "AIRSDK_ZIP_SIZE=$($zipInfo.Length)"
  Write-Host "AIRSDK_ZIP_SHA256=$zipHash"

  if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
  if (Test-Path -LiteralPath $sdkRoot) { Remove-Item -LiteralPath $sdkRoot -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $extractRoot, $sdkRoot | Out-Null
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

  $rootCompiler = Join-Path $extractRoot 'bin\amxmlc.bat'
  if (Test-Path -LiteralPath $rootCompiler) {
    Get-ChildItem -LiteralPath $extractRoot -Force | Copy-Item -Destination $sdkRoot -Recurse -Force
  }
  else {
    $nested = Get-ChildItem -LiteralPath $extractRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\amxmlc.bat') } |
      Select-Object -First 1
    if (-not $nested) {
      throw "AIRSDK_BOOTSTRAP=FAIL compiler_not_found_after_extract root=$extractRoot"
    }
    Get-ChildItem -LiteralPath $nested.FullName -Force | Copy-Item -Destination $sdkRoot -Recurse -Force
  }

  if (-not (Test-Path -LiteralPath $compiler) -or -not (Test-Path -LiteralPath $adtTool)) {
    throw "AIRSDK_BOOTSTRAP=FAIL tools_missing sdk=$sdkRoot"
  }

  Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "AIRSDK_BOOTSTRAP=PASS installed=$sdkRoot"
  return $sdkRoot
}

$git = Find-CommandPath 'git.exe'
if (-not $git) {
  $git = Find-FirstExisting @(
    (Join-Path $AndroidBuildRoot 'Tools\Git\cmd\git.exe'),
    (Join-Path $AndroidBuildRoot 'PortableGit\cmd\git.exe')
  )
}
if (-not $git) { throw 'PRECHECK_GIT=FAIL' }

Push-Location $RepoRoot
try {
  $actual = (& $git rev-parse HEAD).Trim()
  if ($actual -ne $ExpectedSha) {
    throw "EXACT_HEAD=FAIL expected=$ExpectedSha actual=$actual"
  }
  Write-Host "EXACT_HEAD=PASS sha=$actual"
}
finally {
  Pop-Location
}

$java = Find-CommandPath 'java.exe'
if (-not $java) {
  $javaCandidates = @()
  foreach ($base in @(
    (Join-Path $AndroidBuildRoot 'Tools\Java'),
    (Join-Path $AndroidBuildRoot 'Java'),
    (Join-Path $AndroidBuildRoot 'JDK')
  )) {
    if (Test-Path -LiteralPath $base) {
      $javaCandidates += Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'bin\java.exe' }
      $javaCandidates += (Join-Path $base 'bin\java.exe')
    }
  }
  $java = Find-FirstExisting $javaCandidates
}

$amxmlc = Find-AirTool 'amxmlc.bat'
if (-not $amxmlc) { $amxmlc = Find-AirTool 'amxmlc' }
$adt = Find-AirTool 'adt.bat'
if (-not $adt) { $adt = Find-AirTool 'adt' }
$adl = Find-AirTool 'adl.exe'
if (-not $adl) { $adl = Find-AirTool 'adl' }
$animate = Find-Animate

if (-not $amxmlc -or -not $adt) {
  $airHome = Ensure-AirSdk32
  $env:AIR_HOME = $airHome
  $amxmlc = Find-AirTool 'amxmlc.bat'
  if (-not $amxmlc) { $amxmlc = Find-AirTool 'amxmlc' }
  $adt = Find-AirTool 'adt.bat'
  if (-not $adt) { $adt = Find-AirTool 'adt' }
  $adl = Find-AirTool 'adl.exe'
  if (-not $adl) { $adl = Find-AirTool 'adl' }
}

Write-Host "JAVA=$java"
Write-Host "AMXMLC=$amxmlc"
Write-Host "ADT=$adt"
Write-Host "ADL=$adl"
Write-Host "ANIMATE=$animate"

if ($java) {
  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $javaVersion = & $java -version 2>&1
  $ErrorActionPreference = $savedPreference
  $javaVersion | Select-Object -First 4 | ForEach-Object { Write-Host "JAVA_VERSION=$_" }
}
if ($adt) {
  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $airVersion = & $adt -version 2>&1
  $ErrorActionPreference = $savedPreference
  $airVersion | Select-Object -First 5 | ForEach-Object { Write-Host "AIR_VERSION=$_" }
}

$src = Join-Path $RepoRoot 'src'
$mainAs = Join-Path $src 'iArmyAir.as'
$primaryFla = Join-Path $src 'iArmyAirOfflineSavingv22_1.fla'
$sourceDescriptor = Join-Path $src 'iArmyAirOfflineSavingv22_1-app.xml'

foreach ($required in @($mainAs, $primaryFla, $sourceDescriptor)) {
  if (-not (Test-Path -LiteralPath $required)) {
    throw "SOURCE_VALIDATION=FAIL missing=$required"
  }
}

$buildRoot = Join-Path $AndroidBuildRoot ("Builds\code-army-client\$ExpectedSha\windows")
$stageRoot = Join-Path $buildRoot 'stage'
$bundleRoot = Join-Path $buildRoot 'ArmyAttack'
$logRoot = Join-Path $buildRoot 'logs'
New-Item -ItemType Directory -Force -Path $stageRoot, $logRoot | Out-Null

if (Test-Path -LiteralPath $bundleRoot) {
  Remove-Item -LiteralPath $bundleRoot -Recurse -Force
}

$swfName = 'iArmyAirOfflineSavingv22_1.swf'
$swfOut = Join-Path $stageRoot ("bin\$swfName")
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $swfOut) | Out-Null

$compileSucceeded = $false
$compileMethod = $null

if ($amxmlc) {
  Write-Host 'COMPILE_METHOD=AMXMLC_ATTEMPT'
  $compilerLog = Join-Path $logRoot 'amxmlc.log'
  $compilerErr = Join-Path $logRoot 'amxmlc.err.log'
  $args = @(
    '-debug=false',
    '-warnings=false',
    '-source-path', $src,
    '-define=CONFIG::USE_DISCORD_RPC,false',
    "-output=$swfOut",
    '--',
    $mainAs
  )

  $p = Start-Process -FilePath $amxmlc -ArgumentList $args -WorkingDirectory $RepoRoot -NoNewWindow -PassThru -Wait -RedirectStandardOutput $compilerLog -RedirectStandardError $compilerErr
  if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $swfOut)) {
    $compileSucceeded = $true
    $compileMethod = 'amxmlc'
    Write-Host "SWF_COMPILE=PASS method=amxmlc path=$swfOut"
  }
  else {
    Write-Host "SWF_COMPILE_AMXMLC=FAIL exit=$($p.ExitCode) log=$compilerLog"
    if (Test-Path -LiteralPath $compilerLog) {
      Write-Host '--- AMXMLC STDOUT HEAD ---'
      Get-Content -LiteralPath $compilerLog -TotalCount 180 | ForEach-Object { Write-Host $_ }
      Write-Host '--- AMXMLC STDOUT TAIL ---'
      Get-Content -LiteralPath $compilerLog -Tail 180 | ForEach-Object { Write-Host $_ }
    }
    if (Test-Path -LiteralPath $compilerErr) {
      Write-Host '--- AMXMLC STDERR HEAD ---'
      Get-Content -LiteralPath $compilerErr -TotalCount 180 | ForEach-Object { Write-Host $_ }
      Write-Host '--- AMXMLC STDERR TAIL ---'
      Get-Content -LiteralPath $compilerErr -Tail 180 | ForEach-Object { Write-Host $_ }
    }
  }
}

if (-not $compileSucceeded -and $animate) {
  Write-Host 'COMPILE_METHOD=ANIMATE_JSFL_ATTEMPT'
  $jsfl = Join-Path $logRoot 'publish-army.jsfl'
  $resultFile = Join-Path $logRoot 'animate-result.txt'
  $flaEsc = $primaryFla.Replace('\','\\').Replace("'","\'")
  $swfEsc = $swfOut.Replace('\','\\').Replace("'","\'")
  $resultEsc = $resultFile.Replace('\','\\').Replace("'","\'")

  @"
var flaPath = '$flaEsc';
var swfPath = '$swfEsc';
var resultPath = '$resultEsc';
try {
  var flaUri = FLfile.platformPathToURI(flaPath);
  var swfUri = FLfile.platformPathToURI(swfPath);
  var resultUri = FLfile.platformPathToURI(resultPath);
  var doc = fl.openDocument(flaUri);
  if (!doc) throw new Error('openDocument returned null');
  var ok = doc.exportSWF(swfUri, true);
  FLfile.write(resultUri, 'EXPORT=' + ok + '\nSWF=' + swfPath);
  fl.closeDocument(doc, false);
} catch (e) {
  try { FLfile.write(FLfile.platformPathToURI(resultPath), 'ERROR=' + e); } catch (ignored) {}
}
"@ | Set-Content -LiteralPath $jsfl -Encoding UTF8

  $proc = Start-Process -FilePath $animate -ArgumentList @($jsfl, '-AlwaysRunJSFL') -PassThru
  if (-not $proc.WaitForExit(180000)) {
    try { $proc.Kill() } catch {}
    Write-Host 'ANIMATE_EXPORT=FAIL reason=timeout'
  }
  Start-Sleep -Seconds 3

  if (Test-Path -LiteralPath $resultFile) {
    Get-Content -LiteralPath $resultFile | ForEach-Object { Write-Host "ANIMATE_RESULT=$_" }
  }
  if (Test-Path -LiteralPath $swfOut) {
    $compileSucceeded = $true
    $compileMethod = 'animate-jsfl'
    Write-Host "SWF_COMPILE=PASS method=animate-jsfl path=$swfOut"
  }
}

if (-not $compileSucceeded) {
  if (-not $amxmlc -and -not $animate) {
    throw "TOOLCHAIN=FAIL no AIR amxmlc and no Adobe Animate found"
  }
  throw "BUILD=FAIL unable to generate SWF; inspect logs=$logRoot"
}

$swfInfo = Get-Item -LiteralPath $swfOut
$swfHash = (Get-FileHash -LiteralPath $swfOut -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "SWF_SIZE=$($swfInfo.Length)"
Write-Host "SWF_SHA256=$swfHash"

Copy-Item -LiteralPath (Join-Path $src 'data') -Destination (Join-Path $stageRoot 'data') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $src 'config') -Destination (Join-Path $stageRoot 'config') -Recurse -Force
if (Test-Path -LiteralPath (Join-Path $src 'AppIconsForPublish')) {
  Copy-Item -LiteralPath (Join-Path $src 'AppIconsForPublish') -Destination (Join-Path $stageRoot 'AppIconsForPublish') -Recurse -Force
}

$descriptor = Join-Path $stageRoot 'ArmyAttack-app.xml'
$descriptorText = Get-Content -LiteralPath $sourceDescriptor -Raw
$descriptorText = $descriptorText -replace 'http://ns.adobe.com/air/application/51\.2', 'http://ns.adobe.com/air/application/32.0'
$descriptorText = [regex]::Replace($descriptorText, '(?s)<android>.*?</android>', '')
$descriptorText = [regex]::Replace($descriptorText, '(?s)<iPhone>.*?</iPhone>', '')
$descriptorText = [regex]::Replace($descriptorText, '(?s)<extensions>.*?</extensions>', '')
$descriptorText = $descriptorText -replace '<content>.*?</content>', "<content>bin/$swfName</content>"
$descriptorText | Set-Content -LiteralPath $descriptor -Encoding UTF8

if (-not $adt) {
  throw "TOOLCHAIN=FAIL SWF generated but ADT not found; cannot create Windows bundle"
}

Write-Host "PACKAGE_METHOD=AIR_BUNDLE"
$packageLog = Join-Path $logRoot 'adt-package.log'
$packageErr = Join-Path $logRoot 'adt-package.err.log'
$packageArgs = @(
  '-package',
  '-target', 'bundle',
  $bundleRoot,
  $descriptor,
  '-C', $stageRoot, '.'
)

$p2 = Start-Process -FilePath $adt -ArgumentList $packageArgs -WorkingDirectory $stageRoot -NoNewWindow -PassThru -Wait -RedirectStandardOutput $packageLog -RedirectStandardError $packageErr
if ($p2.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $bundleRoot)) {
  Write-Host "WINDOWS_PACKAGE=FAIL exit=$($p2.ExitCode) log=$packageLog"
  if (Test-Path -LiteralPath $packageLog) { Get-Content -LiteralPath $packageLog -Tail 120 | ForEach-Object { Write-Host $_ } }
  if (Test-Path -LiteralPath $packageErr) { Get-Content -LiteralPath $packageErr -Tail 120 | ForEach-Object { Write-Host $_ } }
  throw 'BUILD=FAIL AIR bundle packaging failed'
}

$exe = Get-ChildItem -LiteralPath $bundleRoot -Recurse -File -Filter '*.exe' |
  Sort-Object Length -Descending |
  Select-Object -First 1
if (-not $exe) {
  throw "EXECUTABLE_VALIDATE=FAIL no exe found under $bundleRoot"
}

$exeHash = (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "BUILD=PASS"
Write-Host "WINDOWS_BUNDLE=PASS path=$bundleRoot"
Write-Host "EXE_PATH=$($exe.FullName)"
Write-Host "EXE_SIZE=$($exe.Length)"
Write-Host "EXE_SHA256=$exeHash"
Write-Host "COMPILE_METHOD=$compileMethod"

$launch = Start-Process -FilePath $exe.FullName -WorkingDirectory $bundleRoot -PassThru
Start-Sleep -Seconds 12
if ($launch.HasExited) {
  throw "START=FAIL process exited early code=$($launch.ExitCode) exe=$($exe.FullName)"
}
Write-Host "START=PASS pid=$($launch.Id)"
try { Stop-Process -Id $launch.Id -Force -ErrorAction SilentlyContinue } catch {}
Write-Host "SMOKE=PASS criterion=process_alive_12s"
Write-Host "FINAL_VALIDATION=PASS scope=windows_build_and_process_smoke"
