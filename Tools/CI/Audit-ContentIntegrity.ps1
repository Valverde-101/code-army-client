param(
  [Parameter(Mandatory=$true)][string]$CandidateRoot,
  [Parameter(Mandatory=$true)][string]$BaselineRoot,
  [Parameter(Mandatory=$true)][string]$ReportPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $CandidateRoot)) {
  throw "CONTENT_INTEGRITY_PRECHECK=FAIL candidate_root_missing=$CandidateRoot"
}
if (-not (Test-Path -LiteralPath $BaselineRoot)) {
  throw "CONTENT_INTEGRITY_PRECHECK=FAIL baseline_root_missing=$BaselineRoot"
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
$baselineMissingRefs = @()
$aliasResolvedRefs = @()
$references = New-Object 'System.Collections.Generic.HashSet[string]'

Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$serializer.MaxJsonLength = [int]::MaxValue
$serializer.RecursionLimit = 2048

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
    # Windows PowerShell ConvertFrom-Json rejects case-distinct keys such as ID/id.
    # JavaScriptSerializer follows JSON's case-sensitive object-key semantics.
    $obj = $serializer.DeserializeObject($raw)
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
    if ($rows.Count -eq 0) { throw 'empty CSV' }

    $numericRows = 0
    $maxColumns = 0
    $invalidTokens = @()
    foreach ($row in $rows) {
      if ([string]::IsNullOrWhiteSpace($row)) { continue }
      $tokens = @($row -split ',',-1)
      $maxColumns = [Math]::Max($maxColumns,$tokens.Count)
      $rowHasNumeric = $false
      foreach ($token in $tokens) {
        $trimmed = $token.Trim()
        if ($trimmed -eq '') { continue }
        $parsed = 0
        if ([int]::TryParse($trimmed,[ref]$parsed)) {
          $rowHasNumeric = $true
        } else {
          $invalidTokens += $trimmed
        }
      }
      if ($rowHasNumeric) { $numericRows++ }
    }

    if ($numericRows -eq 0) { throw 'CSV contains no numeric map rows' }
    if ($invalidTokens.Count -gt 0) {
      throw "non-numeric map tokens: $((@($invalidTokens | Select-Object -Unique | Select-Object -First 10)) -join ',')"
    }

    Write-Host "CONFIG_CSV_SHAPE=PASS file=$($file.Name) rows=$($rows.Count) numeric_rows=$numericRows max_columns=$maxColumns"
  }
  catch {
    $csvFailures += [ordered]@{ file=$file.FullName; error=$_.Exception.Message }
    Write-Host "CONFIG_CSV_SHAPE=FAIL file=$($file.Name) error=$($_.Exception.Message)"
  }
}

$candidateFiles = @(Get-ChildItem -LiteralPath $CandidateRoot -Recurse -File -Force)
$baselineFiles = @(Get-ChildItem -LiteralPath $BaselineRoot -Recurse -File -Force)

function Resolve-LocalReference([string]$Root,[string]$Ref,[object[]]$AllFiles) {
  $normalized = $Ref.Replace('/','\').TrimStart('\')
  $paths = @(
    (Join-Path $Root $normalized),
    (Join-Path (Join-Path $Root 'data') $normalized),
    (Join-Path (Join-Path $Root 'config') $normalized)
  )
  foreach ($path in $paths) {
    if (Test-Path -LiteralPath $path) {
      return [ordered]@{ found=$true; mode='exact'; path=$path }
    }
  }

  $leaf = [System.IO.Path]::GetFileName($normalized)
  $matches = @($AllFiles | Where-Object { $_.Name -ieq $leaf })
  if ($matches.Count -eq 1) {
    return [ordered]@{ found=$true; mode='unique-basename'; path=$matches[0].FullName }
  }
  return [ordered]@{ found=$false; mode='missing'; path=$null; basename_matches=$matches.Count }
}

foreach ($ref in $references) {
  $candidateResolution = Resolve-LocalReference $CandidateRoot $ref $candidateFiles
  if ($candidateResolution.found) {
    if ($candidateResolution.mode -eq 'unique-basename') {
      $aliasResolvedRefs += [ordered]@{ ref=$ref; resolved=$candidateResolution.path }
      Write-Host "CONTENT_REFERENCE=ALIAS_RESOLVED ref=$ref path=$($candidateResolution.path)"
    }
    continue
  }

  $baselineResolution = Resolve-LocalReference $BaselineRoot $ref $baselineFiles
  if ($baselineResolution.found) {
    $missingRefs += $ref
    Write-Host "CONTENT_REFERENCE=REGRESSION_MISSING ref=$ref baseline=$($baselineResolution.path)"
  } else {
    $baselineMissingRefs += $ref
    Write-Host "CONTENT_REFERENCE=BASELINE_MISSING ref=$ref"
  }
}

$report = [ordered]@{
  schema = 1
  candidate_root = $CandidateRoot
  baseline_root = $BaselineRoot
  active_json_count = $activeJson.Count
  active_csv_count = $activeCsv.Count
  referenced_local_assets = $references.Count
  json_failures = $jsonFailures
  csv_failures = $csvFailures
  missing_references = @($missingRefs | Sort-Object -Unique)
  baseline_missing_references = @($baselineMissingRefs | Sort-Object -Unique)
  alias_resolved_references = $aliasResolvedRefs
}
$parent = Split-Path -Parent $ReportPath
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Host "CONTENT_INTEGRITY_REPORT=$ReportPath"
Write-Host "CONTENT_INTEGRITY_SUMMARY json=$($activeJson.Count) csv=$($activeCsv.Count) refs=$($references.Count) json_failures=$($jsonFailures.Count) csv_failures=$($csvFailures.Count) regression_missing_refs=$($missingRefs.Count) baseline_missing_refs=$($baselineMissingRefs.Count) alias_resolved=$($aliasResolvedRefs.Count)"

if ($jsonFailures.Count -gt 0 -or $csvFailures.Count -gt 0) {
  throw "CONTENT_INTEGRITY=FAIL syntax_or_shape json_failures=$($jsonFailures.Count) csv_failures=$($csvFailures.Count)"
}
if ($missingRefs.Count -gt 0) {
  throw "CONTENT_INTEGRITY=FAIL regression_missing_references=$($missingRefs.Count)"
}
if ($baselineMissingRefs.Count -gt 0) {
  Write-Host "CONTENT_INTEGRITY_DEBT=OBSERVED baseline_missing_references=$($baselineMissingRefs.Count)"
}
Write-Host "CONTENT_INTEGRITY=PASS"
