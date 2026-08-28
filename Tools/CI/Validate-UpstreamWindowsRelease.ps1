param(
  [Parameter(Mandatory=$true)][string]$AndroidBuildRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$releaseTag = 'v23'
$sourceBaseSha = '324c29b6c9e0e32f61183bf52725662a2bd8aab9'
$assetName = 'AA23_release_windows.zip'
$assetUrl = 'https://github.com/Michielvde1253/army-client/releases/download/v23/AA23_release_windows.zip'
$expectedAssetSha256 = 'e449206435d02797f9c509fc604706274614f21e805581be254f20f2a0d02093'
$expectedAssetSize = 64812856

$inputRoot = Join-Path $AndroidBuildRoot "Inputs\code-army-client\upstream\$releaseTag"
$zipPath = Join-Path $inputRoot $assetName
$extractRoot = Join-Path $AndroidBuildRoot "Builds\code-army-client\$ExpectedSha\windows-upstream-$releaseTag"
$logRoot = Join-Path $extractRoot 'validation-logs'
New-Item -ItemType Directory -Force -Path $inputRoot | Out-Null

Write-Host "UPSTREAM_RELEASE_TAG=$releaseTag"
Write-Host "UPSTREAM_SOURCE_SHA=$sourceBaseSha"
Write-Host "UPSTREAM_ASSET=$assetName"
Write-Host "UPSTREAM_EXPECTED_SHA256=$expectedAssetSha256"

$needsDownload = $true
if (Test-Path -LiteralPath $zipPath) {
  $existing = Get-Item -LiteralPath $zipPath
  if ($existing.Length -eq $expectedAssetSize) {
    $existingHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($existingHash -eq $expectedAssetSha256) {
      $needsDownload = $false
      Write-Host "UPSTREAM_DOWNLOAD=CACHED path=$zipPath"
    }
  }
}

if ($needsDownload) {
  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    & $curl.Source -L --fail --retry 3 --retry-delay 2 -o $zipPath $assetUrl
    if ($LASTEXITCODE -ne 0) { throw "UPSTREAM_DOWNLOAD=FAIL curl_exit=$LASTEXITCODE" }
  }
  else {
    Invoke-WebRequest -Uri $assetUrl -OutFile $zipPath -UseBasicParsing
  }
  Write-Host "UPSTREAM_DOWNLOAD=PASS path=$zipPath"
}

$zip = Get-Item -LiteralPath $zipPath
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "UPSTREAM_ZIP_SIZE=$($zip.Length)"
Write-Host "UPSTREAM_ZIP_SHA256=$zipHash"

if ($zip.Length -ne $expectedAssetSize) {
  throw "UPSTREAM_ASSET_VALIDATE=FAIL expected_size=$expectedAssetSize actual=$($zip.Length)"
}
if ($zipHash -ne $expectedAssetSha256) {
  throw "UPSTREAM_ASSET_VALIDATE=FAIL expected_sha=$expectedAssetSha256 actual=$zipHash"
}
Write-Host "UPSTREAM_ASSET_VALIDATE=PASS"

if (Test-Path -LiteralPath $extractRoot) {
  Remove-Item -LiteralPath $extractRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

$allFiles = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -ErrorAction Stop)
$totalBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
$swfs = @($allFiles | Where-Object { $_.Extension -ieq '.swf' })
$exes = @($allFiles | Where-Object { $_.Extension -ieq '.exe' })
$xmls = @($allFiles | Where-Object { $_.Extension -ieq '.xml' })
$jsons = @($allFiles | Where-Object { $_.Extension -ieq '.json' })

Write-Host "UPSTREAM_EXTRACT=PASS path=$extractRoot"
Write-Host "UPSTREAM_FILE_COUNT=$($allFiles.Count)"
Write-Host "UPSTREAM_TOTAL_BYTES=$totalBytes"
Write-Host "UPSTREAM_SWF_COUNT=$($swfs.Count)"
Write-Host "UPSTREAM_EXE_COUNT=$($exes.Count)"
Write-Host "UPSTREAM_XML_COUNT=$($xmls.Count)"
Write-Host "UPSTREAM_JSON_COUNT=$($jsons.Count)"

$inventoryPath = Join-Path $logRoot 'inventory.csv'
'relative_path,bytes,sha256' | Set-Content -LiteralPath $inventoryPath -Encoding UTF8
foreach ($file in $allFiles | Sort-Object FullName) {
  $rel = $file.FullName.Substring($extractRoot.Length).TrimStart('\').Replace('"','""')
  $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  ('"{0}",{1},{2}' -f $rel,$file.Length,$hash) | Add-Content -LiteralPath $inventoryPath -Encoding UTF8
}

Write-Host '--- UPSTREAM SWF INVENTORY ---'
foreach ($swf in $swfs | Sort-Object FullName) {
  $rel = $swf.FullName.Substring($extractRoot.Length).TrimStart('\')
  $hash = (Get-FileHash -LiteralPath $swf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Host "SWF=$rel size=$($swf.Length) sha256=$hash"
}

Write-Host '--- UPSTREAM EXE INVENTORY ---'
foreach ($exeFile in $exes | Sort-Object FullName) {
  $rel = $exeFile.FullName.Substring($extractRoot.Length).TrimStart('\')
  $hash = (Get-FileHash -LiteralPath $exeFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Host "EXE=$rel size=$($exeFile.Length) sha256=$hash"
}

$appExe = $exes |
  Where-Object {
    $_.Name -match '(?i)army.*attack|armyattack' -and
    $_.FullName -notmatch '(?i)Adobe AIR\\Versions'
  } |
  Sort-Object { $_.FullName.Split('\').Count }, Length |
  Select-Object -First 1

if (-not $appExe) {
  $rootLevelExes = $exes | Where-Object { $_.DirectoryName -eq $extractRoot }
  $appExe = $rootLevelExes | Sort-Object Length -Descending | Select-Object -First 1
}
if (-not $appExe) {
  throw "UPSTREAM_EXE_VALIDATE=FAIL no application exe found"
}

$appExeHash = (Get-FileHash -LiteralPath $appExe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "UPSTREAM_APP_EXE=$($appExe.FullName)"
Write-Host "UPSTREAM_APP_EXE_SIZE=$($appExe.Length)"
Write-Host "UPSTREAM_APP_EXE_SHA256=$appExeHash"
Write-Host "UPSTREAM_EXE_VALIDATE=PASS"

$preExisting = @{}
Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $preExisting[$_.Id] = $true }

$proc = Start-Process -FilePath $appExe.FullName -WorkingDirectory $appExe.DirectoryName -PassThru
Write-Host "UPSTREAM_START_ATTEMPT=pid=$($proc.Id)"
Start-Sleep -Seconds 15

$alive = $false
$alivePid = $null
if (-not $proc.HasExited) {
  $alive = $true
  $alivePid = $proc.Id
}
else {
  try {
    $rootEscaped = [regex]::Escape($extractRoot)
    $candidate = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath -match "^$rootEscaped" -and -not $preExisting.ContainsKey([int]$_.ProcessId)
      } |
      Select-Object -First 1
    if ($candidate) {
      $alive = $true
      $alivePid = [int]$candidate.ProcessId
    }
  } catch {}
}

if (-not $alive) {
  $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { 'unknown' }
  throw "UPSTREAM_START=FAIL parent_exit=$exitCode no_live_process_after_15s"
}

Write-Host "UPSTREAM_START=PASS pid=$alivePid"
Write-Host "UPSTREAM_SMOKE=PASS criterion=process_alive_15s"

try {
  Stop-Process -Id $alivePid -Force -ErrorAction SilentlyContinue
} catch {}
if (-not $proc.HasExited) {
  try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host "UPSTREAM_REFERENCE_VALIDATION=PASS"
Write-Host "UPSTREAM_REFERENCE_PATH=$extractRoot"
