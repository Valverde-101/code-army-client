param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "SNOW_CAMPAIGN_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "SNOW_CAMPAIGN_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$donorRepo=Join-Path $RepoRoot 'vendor\Test_army_attack'
$donorRoot=Join-Path $donorRepo 'armyattack\config'
$targetRoot=Join-Path $RepoRoot 'src\config'
$donorConfigPath=Join-Path $donorRoot 'army_config_base.json'
$targetConfigPath=Join-Path $targetRoot 'army_config_base.json'
$donorTilePath=Join-Path $donorRoot 'tile_map_snow.csv'
$targetTilePath=Join-Path $targetRoot 'tile_map_snow.csv'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\snow-campaign-overlay\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
$expectedDonorSha='306bccc7db5b1ce34dd68a3bc80093648c9224bd'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Clone-JsonValue($Value){(($Value|ConvertTo-Json -Depth 100 -Compress)|ConvertFrom-Json)}
function Set-JsonProperty($Target,[string]$Name,$Value){
  $existing=$Target.PSObject.Properties[$Name]
  if($null -ne $existing){$existing.Value=$Value}else{$Target|Add-Member -MemberType NoteProperty -Name $Name -Value $Value}
}
function Remove-JsonProperty($Target,[string]$Name){if($null -ne $Target.PSObject.Properties[$Name]){$Target.PSObject.Properties.Remove($Name)}}
function Test-SnowEntry([string]$Name,$Value){
  if($Name -match '(?i)(snow|polar|nordur)'){return $true}
  try{$text=$Value|ConvertTo-Json -Depth 40 -Compress}catch{return $false}
  return ($text -match '(?i)(snow|polar|nordur)')
}
function Get-NormalizedTileCellCount([string]$Path){
  $raw=Get-Content -LiteralPath $Path -Raw;$count=0
  foreach($token in ($raw -split ',')){
    $value=(($token -replace "[\r\n]",'').Trim()).TrimStart([char]0xFEFF)
    if($value.Length -gt 0){$count++}
  }
  return $count
}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){Write-Host "SNOW_CAMPAIGN_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha";return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  $configBackup=Join-Path $backupRoot ([string]$manifest.config_backup)
  if(-not(Test-Path -LiteralPath $configBackup -PathType Leaf)){throw "SNOW_CAMPAIGN_OVERLAY=FAIL restore_config_backup_missing=$configBackup"}
  Copy-Item -LiteralPath $configBackup -Destination $targetConfigPath -Force
  if((Get-Sha256 $targetConfigPath) -ne [string]$manifest.config_sha256){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL restore_config_hash'}
  if([bool]$manifest.tile_existed){
    $tileBackup=Join-Path $backupRoot ([string]$manifest.tile_backup)
    if(-not(Test-Path -LiteralPath $tileBackup -PathType Leaf)){throw "SNOW_CAMPAIGN_OVERLAY=FAIL restore_tile_backup_missing=$tileBackup"}
    Copy-Item -LiteralPath $tileBackup -Destination $targetTilePath -Force
    if((Get-Sha256 $targetTilePath) -ne [string]$manifest.tile_sha256){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL restore_tile_hash'}
  }elseif(Test-Path -LiteralPath $targetTilePath){Remove-Item -LiteralPath $targetTilePath -Force}
  & $GitPath -C $RepoRoot diff --quiet -- 'src/config/army_config_base.json'
  if($LASTEXITCODE -ne 0){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL restore_config_not_exact'}
  $trackedTile=@(& $GitPath -C $RepoRoot ls-files --error-unmatch -- 'src/config/tile_map_snow.csv' 2>$null)
  $tileTracked=($LASTEXITCODE -eq 0 -and $trackedTile.Count -gt 0)
  if($tileTracked){
    & $GitPath -C $RepoRoot diff --quiet -- 'src/config/tile_map_snow.csv'
    if($LASTEXITCODE -ne 0){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL restore_tile_not_exact'}
  }elseif(Test-Path -LiteralPath $targetTilePath){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL restore_untracked_tile_leftover'}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "SNOW_CAMPAIGN_OVERLAY=PASS mode=restore exact_source_restored=true sha=$ExpectedSha"
  return
}

# Snow is sourced from the exact pinned v23 submodule. Materialize it here as well
# so Windows candidates never depend on a previous Android run having populated it.
& $GitPath -C $RepoRoot submodule sync -- 'vendor/Test_army_attack' | Out-Host
if($LASTEXITCODE -ne 0){throw "SNOW_DONOR=FAIL operation=submodule_sync exit=$LASTEXITCODE"}
& $GitPath -C $RepoRoot submodule update --init --recursive -- 'vendor/Test_army_attack' | Out-Host
if($LASTEXITCODE -ne 0){throw "SNOW_DONOR=FAIL operation=submodule_update exit=$LASTEXITCODE"}
if(-not(Test-Path -LiteralPath $donorRepo -PathType Container)){throw "SNOW_DONOR=FAIL missing=$donorRepo"}
$donorSha=(& $GitPath -C $donorRepo rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $donorSha -ne $expectedDonorSha){throw "SNOW_DONOR=FAIL expected_sha=$expectedDonorSha actual=$donorSha"}
foreach($required in @($donorConfigPath,$targetConfigPath,$donorTilePath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "SNOW_CAMPAIGN_OVERLAY=FAIL required_missing=$required"}}
Write-Host "SNOW_DONOR=PASS sha=$donorSha config=$donorConfigPath tilemap=$donorTilePath"

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$configBackup='army_config_base.original.json'
Copy-Item -LiteralPath $targetConfigPath -Destination (Join-Path $backupRoot $configBackup) -Force
$tileExisted=Test-Path -LiteralPath $targetTilePath -PathType Leaf
$tileBackup=$null;$tileSha=$null
if($tileExisted){$tileBackup='tile_map_snow.original.csv';Copy-Item -LiteralPath $targetTilePath -Destination (Join-Path $backupRoot $tileBackup) -Force;$tileSha=Get-Sha256 $targetTilePath}
[ordered]@{schema='armyattack-snow-campaign-overlay/v2';source_sha=$ExpectedSha;donor_sha=$donorSha;config_backup=$configBackup;config_sha256=(Get-Sha256 $targetConfigPath);tile_existed=$tileExisted;tile_backup=$tileBackup;tile_sha256=$tileSha}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $donor=Get-Content -LiteralPath $donorConfigPath -Raw|ConvertFrom-Json
  $target=Get-Content -LiteralPath $targetConfigPath -Raw|ConvertFrom-Json
  if($null -eq $donor.MapSetup -or $null -eq $donor.MapSetup.Snow){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL donor_mapsetup_snow_missing'}
  if($null -eq $donor.MapArea){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL donor_maparea_missing'}

  # Keep the published Snow campaign semantics, but remove only entry gating for test builds.
  $snow=Clone-JsonValue $donor.MapSetup.Snow
  Set-JsonProperty $snow 'UnlockLevel' '0'
  Set-JsonProperty $snow 'ZoomLevelsMobile' '120, 180'
  Remove-JsonProperty $snow 'UnlockMission'
  Remove-JsonProperty $snow 'RequiredMission'
  Set-JsonProperty $target.MapSetup 'Snow' $snow

  $snowAreas=0
  foreach($areaProperty in @($donor.MapArea.PSObject.Properties)){
    $area=$areaProperty.Value
    if($null -ne $area -and [string]$area.MapID -eq 'Snow'){Set-JsonProperty $target.MapArea $areaProperty.Name (Clone-JsonValue $area);$snowAreas++}
  }
  if($snowAreas -lt 9){throw "SNOW_CAMPAIGN_OVERLAY=FAIL snow_areas expected_min=9 actual=$snowAreas"}

  # Bring every direct v23 config entry explicitly tied to Snow/Polar/Nordurland.
  # Existing 23.2 entries unrelated to the campaign are never overwritten.
  $mergedEntries=0
  foreach($sectionProperty in @($donor.PSObject.Properties)){
    $sectionName=[string]$sectionProperty.Name
    if($sectionName -in @('MapSetup','MapArea')){continue}
    $donorSection=$sectionProperty.Value
    if($null -eq $donorSection -or $donorSection -is [System.Array] -or $donorSection -is [string] -or $donorSection -is [ValueType]){continue}
    $matching=@($donorSection.PSObject.Properties|Where-Object{Test-SnowEntry ([string]$_.Name) $_.Value})
    if($matching.Count -eq 0){continue}
    $targetSectionProperty=$target.PSObject.Properties[$sectionName]
    if($null -eq $targetSectionProperty){$targetSection=[pscustomobject]@{};Set-JsonProperty $target $sectionName $targetSection}else{$targetSection=$targetSectionProperty.Value}
    if($null -eq $targetSection -or $targetSection -is [System.Array] -or $targetSection -is [string] -or $targetSection -is [ValueType]){continue}
    foreach($entry in $matching){Set-JsonProperty $targetSection ([string]$entry.Name) (Clone-JsonValue $entry.Value);$mergedEntries++}
  }

  $target|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $targetConfigPath -Encoding UTF8
  Copy-Item -LiteralPath $donorTilePath -Destination $targetTilePath -Force

  $verify=Get-Content -LiteralPath $targetConfigPath -Raw|ConvertFrom-Json
  $snowVerify=$verify.MapSetup.Snow
  if($null -eq $snowVerify){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL verify_map_missing'}
  if([string]$snowVerify.ID -ne 'Snow'){throw "SNOW_CAMPAIGN_OVERLAY=FAIL verify_id=$($snowVerify.ID)"}
  if([string]$snowVerify.Type -ne '#MapType.Snow'){throw "SNOW_CAMPAIGN_OVERLAY=FAIL verify_type=$($snowVerify.Type)"}
  if([int]$snowVerify.Width -ne 51 -or [int]$snowVerify.Height -ne 51){throw "SNOW_CAMPAIGN_OVERLAY=FAIL verify_dimensions=$($snowVerify.Width)x$($snowVerify.Height)"}
  if([string]$snowVerify.TilemapFileName -ne 'tile_map_snow.csv'){throw "SNOW_CAMPAIGN_OVERLAY=FAIL verify_tilemap=$($snowVerify.TilemapFileName)"}
  if([string]$snowVerify.MusicFile -ne 'music/army_mus_polarbear.mp3'){throw "SNOW_CAMPAIGN_OVERLAY=FAIL verify_music=$($snowVerify.MusicFile)"}
  if([string]$snowVerify.UnlockLevel -ne '0'){throw "SNOW_CAMPAIGN_OVERLAY=FAIL verify_unlock_level=$($snowVerify.UnlockLevel)"}
  if($null -ne $snowVerify.PSObject.Properties['UnlockMission'] -or $null -ne $snowVerify.PSObject.Properties['RequiredMission']){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL verify_entry_mission_gate_present'}
  if([string]$snowVerify.ZoomLevelsMobile -ne '120, 180'){throw "SNOW_CAMPAIGN_OVERLAY=FAIL verify_mobile_zoom=$($snowVerify.ZoomLevelsMobile)"}
  $logicalSwfs=@($snowVerify.SWFFile)
  if($logicalSwfs.Count -ne 1 -or [string]$logicalSwfs[0] -ne 'swf/new_backgroud_01'){throw "SNOW_CAMPAIGN_OVERLAY=FAIL verify_single_swf_contract actual=$($logicalSwfs -join ',')"}
  $areaVerify=@($verify.MapArea.PSObject.Properties|Where-Object{$null -ne $_.Value -and [string]$_.Value.MapID -eq 'Snow'})
  if($areaVerify.Count -lt 9){throw "SNOW_CAMPAIGN_OVERLAY=FAIL verify_areas=$($areaVerify.Count)"}
  $tileCells=Get-NormalizedTileCellCount $targetTilePath
  if($tileCells -lt 2601){throw "SNOW_CAMPAIGN_OVERLAY=FAIL tile_cells expected_min=2601 actual=$tileCells"}
  $snowMapTypes=@($verify.MapType.PSObject.Properties|Where-Object{Test-SnowEntry ([string]$_.Name) $_.Value})
  if($snowMapTypes.Count -lt 1){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL snow_maptype_missing'}
  $polarEntries=0
  foreach($sectionProperty in @($verify.PSObject.Properties)){
    $section=$sectionProperty.Value
    if($null -eq $section -or $section -is [System.Array] -or $section -is [string] -or $section -is [ValueType]){continue}
    $polarEntries+=@($section.PSObject.Properties|Where-Object{Test-SnowEntry ([string]$_.Name) $_.Value}).Count
  }
  if($polarEntries -lt 10){throw "SNOW_CAMPAIGN_OVERLAY=FAIL polar_content_too_small count=$polarEntries"}

  Write-Host "SNOW_MAP_SETUP=PASS id=Snow type=$($snowVerify.Type) size=$($snowVerify.Width)x$($snowVerify.Height) tilemap=$($snowVerify.TilemapFileName) music=$($snowVerify.MusicFile)"
  Write-Host "SNOW_UNLOCK=PASS level=$($snowVerify.UnlockLevel) mission_gate=none test_access=immediate"
  Write-Host "SNOW_AREAS=PASS count=$($areaVerify.Count)"
  Write-Host "SNOW_TILEMAP=PASS normalized_cells=$tileCells expected=2601"
  Write-Host "SNOW_CONTENT_MERGE=PASS donor_sha=$donorSha merged_entries=$mergedEntries polar_related_entries=$polarEntries"
  Write-Host "SNOW_SINGLE_SWF=PASS logical_resource=$($logicalSwfs[0]) physical_extra_swf=false"
  Write-Host "SNOW_CAMPAIGN_OVERLAY=PASS mode=apply sha=$ExpectedSha donor_sha=$donorSha"
}catch{
  $failure=$_
  try{& $PSCommandPath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "SNOW_CAMPAIGN_OVERLAY_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
