param(
  [Parameter(Mandatory=$true)][string]$CandidateRoot,
  [Parameter(Mandatory=$true)][string]$ReportPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $CandidateRoot)) {
  throw "CONTENT_INTEGRITY_PRECHECK=FAIL candidate_root_missing=$CandidateRoot"
}

$configRoot = Join-Path $CandidateRoot 'config'
$dataRoot = Join-Path $CandidateRoot 'data'
if (-not (Test-Path -LiteralPath $configRoot)) { throw "CONTENT_INTEGRITY_PRECHECK=FAIL config_missing=$configRoot" }
if (-not (Test-Path -LiteralPath $dataRoot)) { throw "CONTENT_INTEGRITY_PRECHECK=FAIL data_missing=$dataRoot" }

$activeJson = @(Get-ChildItem -LiteralPath $configRoot -File -Filter '*.json' -Force)
$activeCsv = @(Get-ChildItem -LiteralPath $configRoot -File -Filter '*.csv' -Force)
$jsonFailures = @()
$csvFailures = @()
$missingRefs = @()
$references = New-Object 'System.Collections.Generic.HashSet[string]'

function Visit-JsonValue($value) {
  if ($null -eq $value) { return }

  if ($value -is [string]) {
    $s = [string]$value
    if ($s -match '(?i)\.(png|jpg|jpeg|gif|mp3|wav|xml|csv|swf|json)$' -and
        $s -notmatch '^(?i)(https?|file):' -and
        $s -notmatch '^[A-Za-z]:\\') {
      [void]$references.Add($s)
    }
    return
  }

  if ($value -is [System.Collections.IDictionary]) {
    foreach ($key in $value.Keys) { Visit-JsonValue $value[$key] }
    return
  }

  if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
    foreach ($item in $value) { Visit-JsonValue $item }
    return
  }

  $props = @($value.PSObject.Properties)
  foreach ($prop in $props) { Visit-JsonValue $prop.Value }
}

foreach ($file in $activeJson) {
  try {
    $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty JSON' }
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    Visit-JsonValue $obj
    Write-Host "CONFIG_JSON_PARSE=PASS file=$($file.Name) bytes=$($file.Length)"
  }
  catch {
    $jsonFailures += [ordered]@{ file=$file.FullName; error=$_.Exception.Message }
    Write-Host "CONFIG_JSON_PARSE=FAIL file=$($file.Name) error=$($_.Exception.Message)"
  }
}

foreach ($file in $activeCsv) {
  try {
    $rows = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)
    $nonEmpty = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($nonEmpty.Count -eq 0) { throw 'empty CSV' }
    $widths = @($nonEmpty | ForEach-Object { ($_ -split ',',-1).Count } | Sort-Object -Unique)
    if ($widths.Count -gt 1) {
      throw "inconsistent comma-column counts: $($widths -join ',')"
    }
    Write-Host "CONFIG_CSV_SHAPE=PASS file=$($file.Name) rows=$($nonEmpty.Count) columns=$($widths[0])"
  }
  catch {
    $csvFailures += [ordered]@{ file=$file.FullName; error=$_.Exception.Message }
    Write-Host "CONFIG_CSV_SHAPE=FAIL file=$($file.Name) error=$($_.Exception.Message)"
  }
}

foreach ($ref in $references) {
  $normalized = $ref.Replace('/','\').TrimStart('\')
  $candidates = @(
    (Join-Path $CandidateRoot $normalized),
    (Join-Path $dataRoot $normalized),
    (Join-Path $configRoot $normalized)
  )
  $exists = $false
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { $exists = $true; break }
  }
  if (-not $exists) {
    $missingRefs += $ref
    Write-Host "CONTENT_REFERENCE=MISSING ref=$ref"
  }
}

$report = [ordered]@{
  schema = 1
  candidate_root = $CandidateRoot
  active_json_count = $activeJson.Count
  active_csv_count = $activeCsv.Count
  referenced_local_assets = $references.Count
  json_failures = $jsonFailures
  csv_failures = $csvFailures
  missing_references = @($missingRefs | Sort-Object -Unique)
}
$parent = Split-Path -Parent $ReportPath
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Host "CONTENT_INTEGRITY_REPORT=$ReportPath"
Write-Host "CONTENT_INTEGRITY_SUMMARY json=$($activeJson.Count) csv=$($activeCsv.Count) refs=$($references.Count) json_failures=$($jsonFailures.Count) csv_failures=$($csvFailures.Count) missing_refs=$($missingRefs.Count)"

if ($jsonFailures.Count -gt 0 -or $csvFailures.Count -gt 0) {
  throw "CONTENT_INTEGRITY=FAIL syntax_or_shape json_failures=$($jsonFailures.Count) csv_failures=$($csvFailures.Count)"
}
if ($missingRefs.Count -gt 0) {
  throw "CONTENT_INTEGRITY=FAIL missing_references=$($missingRefs.Count)"
}
Write-Host "CONTENT_INTEGRITY=PASS"
