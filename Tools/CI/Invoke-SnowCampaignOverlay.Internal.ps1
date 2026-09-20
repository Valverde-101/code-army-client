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
$sourceTargets=@(
  'src\game\states\GameState.as',
  'src\game\gui\popups\WorldMapWindow.as',
  'src\game\isometric\IsometricScene.as'
)
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
function Replace-OneRegex([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "SNOW_CAMPAIGN_OVERLAY=FAIL source_patch=$Name matches=$($matches.Count)"}
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}

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
  }elseif(Test-Path -LiteralPath $targetTilePath){
    Remove-Item -LiteralPath $targetTilePath -Force
  }
  foreach($entry in @($manifest.source_files)){
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    $target=Join-Path $RepoRoot ([string]$entry.path)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "SNOW_CAMPAIGN_OVERLAY=FAIL restore_source_backup_missing=$backup"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne [string]$entry.sha256){throw "SNOW_CAMPAIGN_OVERLAY=FAIL restore_source_hash path=$($entry.path)"}
  }
  foreach($tracked in @('src/config/army_config_base.json')+$sourceTargets){
    & $GitPath -C $RepoRoot diff --quiet -- $tracked
    if($LASTEXITCODE -ne 0){throw "SNOW_CAMPAIGN_OVERLAY=FAIL restore_not_exact path=$tracked"}
  }
  $tileStatus=@(& $GitPath -C $RepoRoot status --porcelain -- 'src/config/tile_map_snow.csv')
  if($LASTEXITCODE -ne 0){throw "SNOW_CAMPAIGN_OVERLAY=FAIL restore_tile_status exit=$LASTEXITCODE"}
  if($tileStatus.Count -gt 0){throw "SNOW_CAMPAIGN_OVERLAY=FAIL restore_tile_not_exact status=$($tileStatus -join ';')"}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "SNOW_CAMPAIGN_OVERLAY=PASS mode=restore exact_source_restored=true sha=$ExpectedSha"
  return
}

& $GitPath -C $RepoRoot submodule sync -- 'vendor/Test_army_attack' | Out-Host
if($LASTEXITCODE -ne 0){throw "SNOW_DONOR=FAIL operation=submodule_sync exit=$LASTEXITCODE"}
& $GitPath -C $RepoRoot submodule update --init --recursive -- 'vendor/Test_army_attack' | Out-Host
if($LASTEXITCODE -ne 0){throw "SNOW_DONOR=FAIL operation=submodule_update exit=$LASTEXITCODE"}
if(-not(Test-Path -LiteralPath $donorRepo -PathType Container)){throw "SNOW_DONOR=FAIL missing=$donorRepo"}
$donorSha=(& $GitPath -C $donorRepo rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $donorSha -ne $expectedDonorSha){throw "SNOW_DONOR=FAIL expected_sha=$expectedDonorSha actual=$donorSha"}
foreach($required in @($donorConfigPath,$targetConfigPath,$donorTilePath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "SNOW_CAMPAIGN_OVERLAY=FAIL required_missing=$required"}}
foreach($rel in $sourceTargets){if(-not(Test-Path -LiteralPath (Join-Path $RepoRoot $rel) -PathType Leaf)){throw "SNOW_CAMPAIGN_OVERLAY=FAIL source_missing=$rel"}}
Write-Host "SNOW_DONOR=PASS sha=$donorSha config=$donorConfigPath tilemap=$donorTilePath"

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$configBackup='army_config_base.original.json'
Copy-Item -LiteralPath $targetConfigPath -Destination (Join-Path $backupRoot $configBackup) -Force
$tileExisted=Test-Path -LiteralPath $targetTilePath -PathType Leaf
$tileBackup=$null;$tileSha=$null
if($tileExisted){$tileBackup='tile_map_snow.original.csv';Copy-Item -LiteralPath $targetTilePath -Destination (Join-Path $backupRoot $tileBackup) -Force;$tileSha=Get-Sha256 $targetTilePath}
$sourceManifest=@()
foreach($rel in $sourceTargets){
  $src=Join-Path $RepoRoot $rel
  $backup=($rel -replace '[\\/]','__')+'.original'
  Copy-Item -LiteralPath $src -Destination (Join-Path $backupRoot $backup) -Force
  $sourceManifest+=@([ordered]@{path=$rel;backup=$backup;sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-snow-campaign-overlay/v4';source_sha=$ExpectedSha;donor_sha=$donorSha;config_backup=$configBackup;config_sha256=(Get-Sha256 $targetConfigPath);tile_existed=$tileExisted;tile_backup=$tileBackup;tile_sha256=$tileSha;source_files=$sourceManifest}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $donor=Get-Content -LiteralPath $donorConfigPath -Raw|ConvertFrom-Json
  $target=Get-Content -LiteralPath $targetConfigPath -Raw|ConvertFrom-Json
  if($null -eq $donor.MapSetup -or $null -eq $donor.MapSetup.Snow){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL donor_mapsetup_snow_missing'}
  if($null -eq $donor.MapArea){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL donor_maparea_missing'}

  $snow=Clone-JsonValue $donor.MapSetup.Snow
  Set-JsonProperty $snow 'UnlockLevel' '0'
  Set-JsonProperty $snow 'ZoomLevelsMobile' '120, 180'
  Remove-JsonProperty $snow 'UnlockMission'
  Remove-JsonProperty $snow 'RequiredMission'
  Set-JsonProperty $target.MapSetup 'Snow' $snow

  $pvpZoomMaps=0
  foreach($mapProperty in @($target.MapSetup.PSObject.Properties)){
    if([string]$mapProperty.Name -like 'pvp_*'){
      Set-JsonProperty $mapProperty.Value 'ZoomLevelsMobile' '40, 75, 100'
      $pvpZoomMaps++
    }
  }
  if($pvpZoomMaps -lt 1){throw 'SNOW_CAMPAIGN_OVERLAY=FAIL pvp_mapsetup_missing'}

  $snowAreas=0
  foreach($areaProperty in @($donor.MapArea.PSObject.Properties)){
    $area=$areaProperty.Value
    if($null -ne $area -and [string]$area.MapID -eq 'Snow'){Set-JsonProperty $target.MapArea $areaProperty.Name (Clone-JsonValue $area);$snowAreas++}
  }
  if($snowAreas -lt 9){throw "SNOW_CAMPAIGN_OVERLAY=FAIL snow_areas expected_min=9 actual=$snowAreas"}

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

  $gamePath=Join-Path $RepoRoot 'src\game\states\GameState.as'
  $game=[IO.File]::ReadAllText($gamePath)
  $game=Replace-OneRegex $game 'public static const GRAPHICS_MAP_ID_LIST:\s*Array\s*=\s*\["Home",\s*"Desert"\];' 'public static const GRAPHICS_MAP_ID_LIST: Array = ["Home", "Desert", "Snow"];' 'game_map_registry'
  Write-Utf8Bom $gamePath $game

  $worldPath=Join-Path $RepoRoot 'src\game\gui\popups\WorldMapWindow.as'
  $world=[IO.File]::ReadAllText($worldPath)
  $world=Replace-OneRegex $world 'public static const WORLD_MAP_ID_LIST:\s*Array\s*=\s*\["Home",\s*"Desert",\s*""\];' 'public static const WORLD_MAP_ID_LIST: Array = ["Home", "Desert", "Snow"];' 'world_map_registry'
  $world=Replace-OneRegex $world '(?m)^\s*this\.setAreaAvailability\(2,\s*false\);\s*\r?\n?' '' 'world_map_snow_forced_disable'
  $world=Replace-OneRegex $world 'if \(Config\.OFFLINE_MODE && \(param1 == 0 \|\| param1 == 1\)\) \{' 'if (Config.OFFLINE_MODE) {' 'world_map_offline_availability'
  $snowTooltipReplacement='this.mCampaignTexts.push("Snow Campaign");'+"`r`n`t`t`t"+'this.mCampaignTexts.push("Enter the polar campaign.");'+"`r`n`t`t`t"+'this.mCampaignTexts.push(GameState.getText("MAP_TOOLTIP_LIBERY_LOCKED"));'
  $world=Replace-OneRegex $world 'this\.mCampaignTexts\.push\(GameState\.getText\("MAP_TOOLTIP_COMING_SOON"\)\);\s*this\.mCampaignTexts\.push\(""\);\s*this\.mCampaignTexts\.push\(""\);' $snowTooltipReplacement 'world_map_snow_tooltip'
  Write-Utf8Bom $worldPath $world

  $scenePath=Join-Path $RepoRoot 'src\game\isometric\IsometricScene.as'
  $scene=[IO.File]::ReadAllText($scenePath)
  $scene=Replace-OneRegex $scene 'import flash\.display\.DisplayObjectContainer;\s*' "import flash.display.DisplayObjectContainer;`r`n`timport flash.display.InteractiveObject;`r`n`t" 'interactive_object_import'
  $scene=Replace-OneRegex $scene 'var pvpButton:\s*DisplayObject\s*=\s*null;' 'var pvpButton: InteractiveObject = null;' 'pvp_button_type'
  $scene=Replace-OneRegex $scene 'var mapButton:\s*DisplayObject\s*=\s*null;' 'var mapButton: InteractiveObject = null;' 'map_button_type'
  $scene=Replace-OneRegex $scene 'pvpButton\s*=\s*bottom\.getChildByName\("Button_Pvp"\);' 'pvpButton = bottom.getChildByName("Button_Pvp") as InteractiveObject;' 'pvp_button_cast'
  $scene=Replace-OneRegex $scene 'mapButton\s*=\s*bottom\.getChildByName\("Button_Map"\);' 'mapButton = bottom.getChildByName("Button_Map") as InteractiveObject;' 'map_button_cast'
  Write-Utf8Bom $scenePath $scene

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
  foreach($pvp in @($verify.MapSetup.PSObject.Properties|Where-Object{[string]$_.Name -like 'pvp_*'})){
    if([string]$pvp.Value.ZoomLevelsMobile -ne '40, 75, 100'){throw "SNOW_CAMPAIGN_OVERLAY=FAIL pvp_mobile_zoom map=$($pvp.Name) actual=$($pvp.Value.ZoomLevelsMobile)"}
  }

  $allMapChecks=@('Home','Desert','Snow')
  foreach($mapName in $allMapChecks){
    $mapProperty=$verify.MapSetup.PSObject.Properties[$mapName]
    if($null -eq $mapProperty){throw "MAP_SYSTEM=FAIL mapsetup_missing=$mapName"}
    $mapSetup=$mapProperty.Value
    $tileName=[string]$mapSetup.TilemapFileName
    $tilePath=Join-Path $targetRoot $tileName
    if([string]::IsNullOrWhiteSpace($tileName) -or -not(Test-Path -LiteralPath $tilePath -PathType Leaf)){throw "MAP_SYSTEM=FAIL tilemap_missing map=$mapName file=$tileName"}
    $expectedCells=[int]$mapSetup.Width * [int]$mapSetup.Height
    $actualCells=Get-NormalizedTileCellCount $tilePath
    if($actualCells -lt $expectedCells){throw "MAP_SYSTEM=FAIL tilemap_cells map=$mapName expected_min=$expectedCells actual=$actualCells"}
    $mapSwfs=@($mapSetup.SWFFile)
    if($mapSwfs.Count -lt 1 -or @($mapSwfs|Where-Object{[string]::IsNullOrWhiteSpace([string]$_)}).Count -gt 0){throw "MAP_SYSTEM=FAIL logical_swf_missing map=$mapName"}
    Write-Host "MAP_TILE=PASS map=$mapName tile=$tileName expected=$expectedCells actual=$actualCells swfs=$($mapSwfs -join ',')"
  }
  $pvpEntries=@($verify.MapSetup.PSObject.Properties|Where-Object{[string]$_.Name -like 'pvp_*'})
  if($pvpEntries.Count -lt 1){throw 'MAP_SYSTEM=FAIL pvp_maps_missing'}
  foreach($pvp in $pvpEntries){
    if([string]$pvp.Value.ZoomLevelsMobile -ne '40, 75, 100'){throw "MAP_SYSTEM=FAIL pvp_mobile_zoom map=$($pvp.Name) actual=$($pvp.Value.ZoomLevelsMobile)"}
  }
  $firstPvp=$pvpEntries|Where-Object{[string]$_.Value.TilemapFileName}|Select-Object -First 1
  if($null -eq $firstPvp){throw 'MAP_SYSTEM=FAIL pvp_tilemap_reference_missing'}
  $pvpTileName=[string]$firstPvp.Value.TilemapFileName
  $pvpTilePath=Join-Path $targetRoot $pvpTileName
  if(-not(Test-Path -LiteralPath $pvpTilePath -PathType Leaf)){throw "MAP_SYSTEM=FAIL pvp_tilemap_missing map=$($firstPvp.Name) file=$pvpTileName"}
  $pvpExpected=[int]$firstPvp.Value.Width * [int]$firstPvp.Value.Height
  $pvpActual=Get-NormalizedTileCellCount $pvpTilePath
  if($pvpActual -lt $pvpExpected){throw "MAP_SYSTEM=FAIL pvp_tilemap_cells map=$($firstPvp.Name) expected_min=$pvpExpected actual=$pvpActual"}
  Write-Host "MAP_TILE=PASS map=$($firstPvp.Name) tile=$pvpTileName expected=$pvpExpected actual=$pvpActual"

  $gameVerify=[IO.File]::ReadAllText($gamePath)
  $worldVerify=[IO.File]::ReadAllText($worldPath)
  $sceneVerify=[IO.File]::ReadAllText($scenePath)
  $offlineVerify=[IO.File]::ReadAllText((Join-Path $RepoRoot 'src\game\utils\OfflineSave.as'))
  if($gameVerify -notmatch 'GRAPHICS_MAP_ID_LIST\s*:\s*Array\s*=\s*\[\s*"Home"\s*,\s*"Desert"\s*,\s*"Snow"\s*\]'){throw 'MAP_SYSTEM=FAIL graphics_map_registry'}
  if($worldVerify -notmatch 'WORLD_MAP_ID_LIST\s*:\s*Array\s*=\s*\[\s*"Home"\s*,\s*"Desert"\s*,\s*"Snow"\s*\]'){throw 'MAP_SYSTEM=FAIL world_map_registry'}
  if($worldVerify.Contains('this.setAreaAvailability(2, false);') -or $worldVerify.Contains('MAP_TOOLTIP_COMING_SOON')){throw 'MAP_SYSTEM=FAIL world_map_snow_disabled'}
  if($worldVerify -notmatch 'requestWorldMapSwitch\(param1\)'){throw 'MAP_SYSTEM=FAIL world_map_switch_route'}
  if($offlineVerify -notmatch 'savedata\["active_map_id"\]\s*=\s*map_id\.indexOf\("pvp_"\)\s*==\s*-1\s*\?\s*map_id\s*:\s*"Home"'){throw 'MAP_SYSTEM=FAIL offline_active_map_save'}
  if($offlineVerify -notmatch 'executeSwitchMap\(activeMapId,\s*null\)'){throw 'MAP_SYSTEM=FAIL offline_active_map_restore'}
  if($sceneVerify -notmatch 'import\s+flash\.display\.InteractiveObject\s*;' -or $sceneVerify -notmatch 'var\s+pvpButton\s*:\s*InteractiveObject' -or $sceneVerify -notmatch 'var\s+mapButton\s*:\s*InteractiveObject'){throw 'MAP_SYSTEM=FAIL interactive_button_compile_contract'}
  Write-Host 'MAP_REGISTRY=PASS ids=Home,Desert,Snow'
  Write-Host 'WORLD_MAP_ROUTING=PASS ids=Home,Desert,Snow switch=requestWorldMapSwitch'
  Write-Host 'OFFLINE_MAP_PERSISTENCE=PASS stable_maps=Home,Desert,Snow pvp_fallback=Home restore=executeSwitchMap'
  Write-Host 'WINDOWS_SOURCE_TYPE_FIX=PASS buttons=InteractiveObject'
  Write-Host "MAP_SYSTEM_REGRESSION=PASS campaign_maps=3 pvp_maps=$($pvpEntries.Count)"

  Write-Host "SNOW_MAP_SETUP=PASS id=Snow type=$($snowVerify.Type) size=$($snowVerify.Width)x$($snowVerify.Height) tilemap=$($snowVerify.TilemapFileName) music=$($snowVerify.MusicFile)"
  Write-Host "SNOW_UNLOCK=PASS level=$($snowVerify.UnlockLevel) mission_gate=none test_access=immediate"
  Write-Host "SNOW_AREAS=PASS count=$($areaVerify.Count)"
  Write-Host "SNOW_TILEMAP=PASS normalized_cells=$tileCells expected=2601"
  Write-Host "SNOW_CONTENT_MERGE=PASS donor_sha=$donorSha merged_entries=$mergedEntries polar_related_entries=$polarEntries"
  Write-Host "SNOW_SINGLE_SWF=PASS logical_resource=$($logicalSwfs[0]) physical_extra_swf=false"
  Write-Host "PVP_MOBILE_ZOOM=PASS maps=$pvpZoomMaps zoom=40,75,100"
  Write-Host 'MAP_RUNTIME_SOURCE_OVERLAY=PASS ids=Home,Desert,Snow persistence=generic world_map=enabled source_compile_fix=InteractiveObject'
  Write-Host "SNOW_CAMPAIGN_OVERLAY=PASS mode=apply sha=$ExpectedSha donor_sha=$donorSha"
}catch{
  $failure=$_
  try{& $PSCommandPath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "SNOW_CAMPAIGN_OVERLAY_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
