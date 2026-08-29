param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$root=(Resolve-Path -LiteralPath $RepositoryRoot).Path
$targets=@(
  Get-ChildItem -LiteralPath (Join-Path $root 'Tools\CI') -File -Filter '*.ps1' -ErrorAction Stop
  Get-ChildItem -LiteralPath (Join-Path $root 'Tools\SWF') -File -Filter '*.ps1' -ErrorAction SilentlyContinue
)
$targets=@($targets|Sort-Object FullName -Unique)
if($targets.Count -eq 0){throw 'POWERSHELL_SYNTAX=FAIL no_scripts'}

$totalErrors=0
foreach($file in $targets){
  $tokens=$null
  $errors=$null
  [System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null
  if($errors.Count -gt 0){
    foreach($err in $errors){
      Write-Host "POWERSHELL_SYNTAX_ERROR file=$($file.FullName) line=$($err.Extent.StartLineNumber) column=$($err.Extent.StartColumnNumber) message=$($err.Message)"
    }
    $totalErrors+=$errors.Count
  }
}
if($totalErrors -gt 0){throw "POWERSHELL_SYNTAX=FAIL errors=$totalErrors"}
Write-Host "POWERSHELL_SYNTAX=PASS scripts=$($targets.Count)"
