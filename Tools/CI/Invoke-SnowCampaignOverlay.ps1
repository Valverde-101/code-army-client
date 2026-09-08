param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$internal=Join-Path $PSScriptRoot 'Invoke-SnowCampaignOverlay.Internal.ps1'
if(-not(Test-Path -LiteralPath $internal -PathType Leaf)){throw "SNOW_CAMPAIGN_OVERLAY=FAIL internal_missing=$internal"}

if($Mode -eq 'Restore'){
  & $internal -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  return
}

try {
  & $internal -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply

  # Windows PowerShell 5.1 ConvertTo-Json may emit two spaces after ':'.
  # Canonicalize only the PvP mobile-zoom property so text consumers stay
  # deterministic, while validating the actual JSON value semantically first.
  $configPath=Join-Path $RepoRoot 'src\config\army_config_base.json'
  $configRaw=[IO.File]::ReadAllText($configPath)
  $config=$configRaw|ConvertFrom-Json
  if($null -eq $config.MapSetup){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL canonical_mapsetup_missing'}
  $pvpMaps=@($config.MapSetup.PSObject.Properties|Where-Object{[string]$_.Name -like 'pvp_*'})
  if($pvpMaps.Count -lt 1){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL canonical_pvp_mapsetup_missing'}
  foreach($map in $pvpMaps){
    $zoom=[string]$map.Value.ZoomLevelsMobile
    $normalized=(($zoom -split ',')|ForEach-Object{$_.Trim()}) -join ','
    if($normalized -ne '40,75,100'){
      throw "SNOW_CAMPAIGN_OVERLAY=FAIL pvp_mobile_zoom_semantic map=$($map.Name) expected=40,75,100 actual=$zoom"
    }
  }
  $pattern='"ZoomLevelsMobile"\s*:\s*"40, 75, 100"'
  $matches=[regex]::Matches($configRaw,$pattern)
  if($matches.Count -lt $pvpMaps.Count){throw "SNOW_CAMPAIGN_OVERLAY=FAIL pvp_mobile_zoom_text_count expected_min=$($pvpMaps.Count) actual=$($matches.Count)"}
  $canonical=[regex]::Replace($configRaw,$pattern,'"ZoomLevelsMobile": "40, 75, 100"')
  [IO.File]::WriteAllText($configPath,$canonical,(New-Object Text.UTF8Encoding($true)))
  $verify=[IO.File]::ReadAllText($configPath)
  if(-not $verify.Contains('"ZoomLevelsMobile": "40, 75, 100"')){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL pvp_mobile_zoom_canonical_text'}
  Write-Host "PVP_MOBILE_ZOOM_CANONICAL=PASS maps=$($pvpMaps.Count) semantic=true value=40,75,100 powershell_json_spacing=normalized"
  Write-Host "SNOW_CAMPAIGN_OVERLAY_WRAPPER=PASS mode=apply sha=$ExpectedSha deterministic_json=true"
} catch {
  $failure=$_
  try { & $internal -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore } catch { Write-Host "SNOW_CAMPAIGN_OVERLAY_WRAPPER_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)" }
  throw $failure
}
