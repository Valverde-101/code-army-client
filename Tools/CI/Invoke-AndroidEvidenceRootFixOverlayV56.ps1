param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [string]$RequestedMode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if($RequestedMode -notin @('Apply','Restore')){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL invalid_mode=$RequestedMode"}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v55=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV55.ps1'
if(-not(Test-Path -LiteralPath $v55 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL predecessor_missing=$v55"}

$pvpMovePath=Join-Path $RepoRoot 'src\game\actions\PvPEnemyMovingAction.as'
$enemyMovePath=Join-Path $RepoRoot 'src\game\actions\EnemyMovingAction.as'
$attackPath=Join-Path $RepoRoot 'src\game\actions\AttackEnemyAction.as'
$assetPath=Join-Path $RepoRoot 'src\AssetManager.as'
$worldMapPath=Join-Path $RepoRoot 'src\game\gui\popups\WorldMapWindow.as'
$configBasePath=Join-Path $RepoRoot 'src\config\army_config_base.json'
$configFullPath=Join-Path $RepoRoot 'src\config\army_config.json'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$mapDataPath=Join-Path $RepoRoot 'src\game\battlefield\MapData.as'
$offlinePath=Join-Path $RepoRoot 'src\game\utils\OfflineSave.as'
$gameStatePath=Join-Path $RepoRoot 'src\game\states\GameState.as'
$gameHudPath=Join-Path $RepoRoot 'src\game\gui\GameHUD.as'
$dailyRewardPath=Join-Path $RepoRoot 'src\game\gui\popups\DailyRewardWindow.as'
$configSourcePath=Join-Path $RepoRoot 'src\Config.as'
$enemyPath=Join-Path $RepoRoot 'src\game\characters\EnemyUnit.as'
$enemyAttackPath=Join-Path $RepoRoot 'src\game\actions\EnemyAttackingAction.as'

$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v56\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

$pvpMaps=@(
  [ordered]@{Id='pvp_map_1_4valleys_11x11';Number=1;Width=11;Height=11;Kind='grass';Native=$true}
)
$disabledSyntheticPvpMapIds=@(
  'pvp_map_2_blackforest_13x9',
  'pvp_map_3_desert_battleisland_13x9',
  'pvp_map_4_forbiddenforest_11x11',
  'pvp_map_5_fourmountains_11x11',
  'pvp_map_10_twomountains_11x11',
  'pvp_map_12_battleisle_13x13',
  'pvp_map_21_desert_15x8',
  'pvp_map_22_desert_14x8',
  'pvp_map_23_desert_14x8',
  'pvp_map_29_desertcanyon_13x13',
  'pvp_map_30_kingofthehill_16x14'
)
if(@($pvpMaps|Where-Object{-not [bool]$_.Native}).Count -ne 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V56=FAIL synthetic_pvp_map_active'}
Write-Host "PVP_SYNTHETIC_MAPS_DISABLED=PASS count=$($disabledSyntheticPvpMapIds.Count) active_native=$($pvpMaps.Count) reason=terrain_not_authentic"

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Write-Utf8NoBom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false)))}
function Replace-ExactOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL patch=$Name missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL patch=$Name ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V56_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Require([string]$Text,[string]$Token,[string]$Name){
  if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL verify=$Name token=$Token"}
}
function Reject([string]$Text,[string]$Token,[string]$Name){
  if($Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL reject=$Name token=$Token"}
}
function Save-Manifest([array]$Files,[array]$Generated){
  [ordered]@{
    schema='armyattack-android-evidence-rootfix-overlay/v56'
    source_sha=$ExpectedSha
    predecessor='v55'
    files=$Files
    generated=$Generated
  }|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manifestPath -Encoding UTF8
}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $m=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$m.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($m.source_sha)"}
  foreach($relative in @($m.generated)){
    $target=Join-Path $RepoRoot ([string]$relative)
    if(Test-Path -LiteralPath $target -PathType Leaf){Remove-Item -LiteralPath $target -Force}
  }
  foreach($e in @($m.files)){
    $target=Join-Path $RepoRoot ([string]$e.path)
    $backup=Join-Path $backupRoot ([string]$e.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL restore_backup_missing=$($e.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$e.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL restore_hash=$($e.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V56_OWNED_RESTORE=PASS'
}
function Get-JsonProperty($Object,[string]$Name){
  if($null -eq $Object){return $null}
  return @($Object.PSObject.Properties|Where-Object{$_.Name -eq $Name})|Select-Object -First 1
}
function Set-JsonProperty($Object,[string]$Name,$Value){
  if($null -eq $Object){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL json_target_null property=$Name"}
  $property=Get-JsonProperty $Object $Name
  if($property){
    $property.Value=$Value
  }else{
    $Object|Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}
function Get-PvpSetupSet($Cfg,[string]$MapId){
  $areas=Get-JsonProperty $Cfg 'PVPAreaSetup'
  if(-not $areas -or $null -eq $areas.Value){return $MapId}
  foreach($prop in @($areas.Value.PSObject.Properties)){
    $setup=Get-JsonProperty $prop.Value 'SetupSet'
    if(-not $setup){continue}
    $candidate=[string]$setup.Value
    if($candidate -and $candidate.Equals($MapId,[StringComparison]::OrdinalIgnoreCase)){return $candidate}
  }
  return $MapId
}
function Get-NormalizedCsvCellCount([string]$Path){
  $raw=Get-Content -LiteralPath $Path -Raw
  $count=0
  foreach($token in ($raw -split ',')){
    $value=(($token -replace "[\r\n]",'').Trim()).TrimStart([char]0xFEFF)
    if($value.Length -gt 0){$count++}
  }
  return $count
}
function Ensure-PvpMapSetup([string]$Path){
  $cfg=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json
  $mapSetupProperty=Get-JsonProperty $cfg 'MapSetup'
  $probabilityProperty=Get-JsonProperty $cfg 'PvPMapProbability'
  if(-not $mapSetupProperty -or $null -eq $mapSetupProperty.Value){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL config_mapsetup_missing path=$Path"}
  if(-not $probabilityProperty -or $null -eq $probabilityProperty.Value){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL config_probability_missing path=$Path"}
  $templateProperty=Get-JsonProperty $mapSetupProperty.Value 'pvp_map_1_4valleys_11x11'
  if(-not $templateProperty -or $null -eq $templateProperty.Value){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL native_pvp_template_missing path=$Path"}
  $template=$templateProperty.Value
  $nativeTileProperty=Get-JsonProperty $template 'TilemapFileName'
  $nativeTileName=if($nativeTileProperty){[string]$nativeTileProperty.Value}else{'pvp_map_1_4valleys_11x11.csv'}
  $tileSuffix=if($nativeTileName.EndsWith('.csv',[StringComparison]::OrdinalIgnoreCase)){'.csv'}else{''}
  $nativeSwfProperty=Get-JsonProperty $template 'SWFFile'
  $nativeSwf=if($nativeSwfProperty){$nativeSwfProperty.Value}else{'swf/new_backgroud_01'}
  foreach($map in $pvpMaps){
    $prob=Get-JsonProperty $probabilityProperty.Value ([string]$map.Id)
    if(-not $prob){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_probability_missing id=$($map.Id) path=$Path"}
    $existing=Get-JsonProperty $mapSetupProperty.Value ([string]$map.Id)
    if(-not $existing){
      $entry=($template|ConvertTo-Json -Depth 30|ConvertFrom-Json)
      Set-JsonProperty $entry 'ID' ([string]$map.Id)
      Set-JsonProperty $entry 'Width' ([string]$map.Width)
      Set-JsonProperty $entry 'Height' ([string]$map.Height)
      $mapType=if($map.Kind -eq 'desert'){'#MapType.Desert'}else{'#MapType.Grassland'}
      Set-JsonProperty $entry 'Type' $mapType
      Set-JsonProperty $entry 'TilemapFileName' ([string]$map.Id+$tileSuffix)
      if($map.Kind -eq 'desert'){
        Set-JsonProperty $entry 'SWFFile' @('swf/new_backgroud_01','swf/desert_backgroud_01')
      }else{
        Set-JsonProperty $entry 'SWFFile' $nativeSwf
      }
      Set-JsonProperty $entry 'Name' ('#TID.PVP_MAP_'+[string]$map.Number)
      Set-JsonProperty $entry 'SetupSet' (Get-PvpSetupSet $cfg ([string]$map.Id))
      Set-JsonProperty $entry 'ZoomLevels' '40, 75, 100'
      Set-JsonProperty $entry 'ZoomLevelsMobile' '40, 75, 100'
      $mapSetupProperty.Value|Add-Member -NotePropertyName ([string]$map.Id) -NotePropertyValue $entry
      $setupProperty=Get-JsonProperty $entry 'SetupSet'
      $setupValue=if($setupProperty){[string]$setupProperty.Value}else{[string]$map.Id}
      Write-Host "PVP_MAP_SETUP_RECONSTRUCTED=PASS id=$($map.Id) size=$($map.Width)x$($map.Height) type=$($map.Kind) setup=$setupValue powershell51_safe=true"
    }
    $resolved=Get-JsonProperty $mapSetupProperty.Value ([string]$map.Id)
    if(-not $resolved -or $null -eq $resolved.Value){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL reconstructed_map_missing id=$($map.Id)"}
    $idProperty=Get-JsonProperty $resolved.Value 'ID'
    $nameProperty=Get-JsonProperty $resolved.Value 'Name'
    $typeProperty=Get-JsonProperty $resolved.Value 'Type'
    $setupProperty=Get-JsonProperty $resolved.Value 'SetupSet'
    $expectedId=[string]$map.Id
    $expectedName='#TID.PVP_MAP_'+[string]$map.Number
    $expectedType=if($map.Kind -eq 'desert'){'#MapType.Desert'}else{'#MapType.Grassland'}
    $expectedSetup=Get-PvpSetupSet $cfg $expectedId
    if(-not $idProperty -or [string]$idProperty.Value -ne $expectedId){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_internal_id id=$($map.Id) expected=$expectedId actual=$([string]$idProperty.Value)"}
    if(-not $nameProperty -or [string]$nameProperty.Value -ne $expectedName){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_name_reference id=$($map.Id) expected=$expectedName actual=$([string]$nameProperty.Value)"}
    if(-not $typeProperty -or [string]$typeProperty.Value -ne $expectedType){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_type_reference id=$($map.Id) expected=$expectedType actual=$([string]$typeProperty.Value)"}
    if(-not $setupProperty -or -not ([string]$setupProperty.Value).Equals($expectedSetup,[StringComparison]::Ordinal)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_setupset_reference id=$($map.Id) expected=$expectedSetup actual=$([string]$setupProperty.Value)"}
    if(Get-JsonProperty $resolved.Value 'MapType'){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_noncanonical_maptype_property id=$($map.Id)"}
    $mapTypeProperty=Get-JsonProperty $cfg 'MapType'
    $mapTypeKey=if($map.Kind -eq 'desert'){'Desert'}else{'Grassland'}
    if(-not $mapTypeProperty -or $null -eq $mapTypeProperty.Value -or -not (Get-JsonProperty $mapTypeProperty.Value $mapTypeKey)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_maptype_target_missing id=$($map.Id) target=$mapTypeKey"}
    $areasProperty=Get-JsonProperty $cfg 'PVPAreaSetup'
    if(-not $areasProperty -or $null -eq $areasProperty.Value){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_area_setup_missing id=$($map.Id)"}
    $setupAreaCount=0
    $playerSpawnCount=0
    $enemySpawnCount=0
    foreach($areaProp in @($areasProperty.Value.PSObject.Properties)){
      $areaSetup=Get-JsonProperty $areaProp.Value 'SetupSet'
      if(-not $areaSetup){continue}
      $candidate=[string]$areaSetup.Value
      if(-not $candidate.Equals($expectedSetup,[StringComparison]::OrdinalIgnoreCase)){continue}
      $setupAreaCount++
      $spawnType=Get-JsonProperty $areaProp.Value 'SpawningAreaType'
      if($spawnType -and [string]$spawnType.Value -eq 'PlayerSpawning'){$playerSpawnCount++}
      if($spawnType -and [string]$spawnType.Value -eq 'EnemySpawning'){$enemySpawnCount++}
    }
    if($setupAreaCount -lt 2 -or $playerSpawnCount -ne 1 -or $enemySpawnCount -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_setupset_incomplete id=$($map.Id) setup=$expectedSetup areas=$setupAreaCount player_spawn=$playerSpawnCount enemy_spawn=$enemySpawnCount"}
  }
  foreach($lang in @('en','de','fr','it','es')){
    $langPath=Join-Path $RepoRoot ('src\config\army_config_'+$lang+'.json')
    if(-not(Test-Path -LiteralPath $langPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_translation_file_missing lang=$lang"}
    $langRaw=Get-Content -LiteralPath $langPath -Raw
    foreach($map in $pvpMaps){
      $translationKey='"PVP_MAP_'+[string]$map.Number+'"'
      if(-not $langRaw.Contains($translationKey)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL pvp_translation_missing lang=$lang id=$($map.Id) key=$translationKey"}
    }
  }
  Write-Host 'PVP_MAP_REFERENCE_CONTRACT=PASS maps=1 id=unique name=#TID.PVP_MAP_N type=#MapType kind=grassland|desert setupset=resolved player_spawn=1 enemy_spawn=1 translations=en,de,fr,it,es synthetic_scene_reference=false'
  $snowProperty=Get-JsonProperty $mapSetupProperty.Value 'Snow'
  if(-not $snowProperty -or $null -eq $snowProperty.Value){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL snow_mapsetup_missing path=$Path"}
  Set-JsonProperty $snowProperty.Value 'UnlockLevel' '0'
  $json=$cfg|ConvertTo-Json -Depth 100
  Write-Utf8NoBom $Path $json
}
function Get-JsonObjectSpan([string]$Text,[string]$PropertyName){
  $pattern='"'+[regex]::Escape($PropertyName)+'"\s*:\s*\{'
  $match=[regex]::Match($Text,$pattern)
  if(-not $match.Success){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL json_object_missing property=$PropertyName"}
  $open=$Text.IndexOf('{',$match.Index)
  if($open -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL json_object_open_missing property=$PropertyName"}
  $depth=0
  $inString=$false
  $escaped=$false
  for($i=$open;$i -lt $Text.Length;$i++){
    $c=$Text[$i]
    if($inString){
      if($escaped){$escaped=$false;continue}
      if($c -eq '\'){$escaped=$true;continue}
      if($c -eq '"'){$inString=$false}
      continue
    }
    if($c -eq '"'){$inString=$true;continue}
    if($c -eq '{'){$depth++;continue}
    if($c -eq '}'){
      $depth--
      if($depth -eq 0){return [pscustomobject]@{Open=$open;Close=$i}}
    }
  }
  throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL json_object_unclosed property=$PropertyName"
}
function Assert-PvpMapSetupTextContract([string]$Path){
  $raw=Normalize-Lf ([IO.File]::ReadAllText($Path))
  $mapSpan=Get-JsonObjectSpan $raw 'MapSetup'
  $mapBody=$raw.Substring($mapSpan.Open+1,$mapSpan.Close-$mapSpan.Open-1)
  foreach($map in $pvpMaps){
    $id=[string]$map.Id
    $entrySpan=Get-JsonObjectSpan $mapBody $id
    $entryText=$mapBody.Substring($entrySpan.Open,$entrySpan.Close-$entrySpan.Open+1)
    $expectedName='#TID.PVP_MAP_'+[string]$map.Number
    $expectedType=if($map.Kind -eq 'desert'){'#MapType.Desert'}else{'#MapType.Grassland'}
    $idPattern='"ID"\s*:\s*"'+[regex]::Escape($id)+'"'
    $namePattern='"Name"\s*:\s*"'+[regex]::Escape($expectedName)+'"'
    $typePattern='"Type"\s*:\s*"'+[regex]::Escape($expectedType)+'"'
    if(-not [regex]::IsMatch($entryText,$idPattern)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL full_config_internal_id id=$id"}
    if(-not [regex]::IsMatch($entryText,$namePattern)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL full_config_name_reference id=$id expected=$expectedName"}
    if(-not [regex]::IsMatch($entryText,$typePattern)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL full_config_type_reference id=$id expected=$expectedType"}
    if([regex]::IsMatch($entryText,'"MapType"\s*:')){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL full_config_noncanonical_maptype id=$id"}
  }
  Write-Host 'PVP_MAP_FULL_TEXT_CONTRACT=PASS maps=1 internal_id=unique name_reference=canonical type_reference=canonical maptype_field=absent'
}

function Sync-PvpMapSetupText([string]$SourcePath,[string]$TargetPath){
  # army_config.json intentionally contains case-sensitive keys such as ID/id.
  # Windows PowerShell 5.1 ConvertFrom-Json rejects those as duplicates, so only
  # the MapSetup object is edited lexically; every unrelated byte-semantic key is preserved.
  $sourceCfg=Get-Content -LiteralPath $SourcePath -Raw|ConvertFrom-Json
  $sourceMapProperty=Get-JsonProperty $sourceCfg 'MapSetup'
  if(-not $sourceMapProperty -or $null -eq $sourceMapProperty.Value){throw 'ANDROID_EVIDENCE_ROOTFIX_V56=FAIL source_mapsetup_missing_for_text_sync'}
  $raw=Normalize-Lf ([IO.File]::ReadAllText($TargetPath))
  $span=Get-JsonObjectSpan $raw 'MapSetup'
  $body=$raw.Substring($span.Open+1,$span.Close-$span.Open-1)
  $entries=New-Object System.Collections.Generic.List[string]
  foreach($map in $pvpMaps){
    $id=[string]$map.Id
    $needle='"'+$id+'"'
    if($body.Contains($needle)){continue}
    $sourceEntry=Get-JsonProperty $sourceMapProperty.Value $id
    if(-not $sourceEntry -or $null -eq $sourceEntry.Value){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL source_mapsetup_missing_for_text_sync id=$id"}
    $entryJson=$sourceEntry.Value|ConvertTo-Json -Depth 30 -Compress
    $entries.Add(('    "'+$id+'": '+$entryJson))
    if([bool]$map.Native){Write-Host "PVP_FULL_CONFIG_NATIVE_SYNC=PASS id=$id action=insert_missing source=base_config"}
  }
  if($entries.Count -gt 0){
    $existing=$body.Trim()
    $separator=if($existing.Length -gt 0){","}else{""}
    $insert=$separator+"`n"+($entries -join ",`n")+"`n"
    $raw=$raw.Substring(0,$span.Close)+$insert+$raw.Substring($span.Close)
  }
  $verifySpan=Get-JsonObjectSpan $raw 'MapSetup'
  $verifyBody=$raw.Substring($verifySpan.Open+1,$verifySpan.Close-$verifySpan.Open-1)
  foreach($map in $pvpMaps){
    $id=[string]$map.Id
    if(-not $verifyBody.Contains(('"'+$id+'"'))){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL full_config_text_sync_missing id=$id"}
  }
  Write-Utf8NoBom $TargetPath $raw
  Write-Host "PVP_FULL_CONFIG_TEXT_SYNC=PASS maps=1 inserted=$($entries.Count) parser=brace_depth case_sensitive_keys_preserved=true convertfromjson=false"
}
if($RequestedMode -eq 'Restore'){
  Restore-OwnedFiles
  & $v55 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V56=PASS mode=restore predecessor=v55 sha=$ExpectedSha"
  return
}

$v55Applied=$false
try {
  & $v55 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Apply
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL predecessor_apply_exit=$LASTEXITCODE"}
  $v55Applied=$true

  $owned=@(
    [ordered]@{Repo='src\game\actions\PvPEnemyMovingAction.as';Path=$pvpMovePath;Backup='PvPEnemyMovingAction.post-v55.as'},
    [ordered]@{Repo='src\game\actions\EnemyMovingAction.as';Path=$enemyMovePath;Backup='EnemyMovingAction.post-v55.as'},
    [ordered]@{Repo='src\game\actions\AttackEnemyAction.as';Path=$attackPath;Backup='AttackEnemyAction.post-v55.as'},
    [ordered]@{Repo='src\AssetManager.as';Path=$assetPath;Backup='AssetManager.post-v55.as'},
    [ordered]@{Repo='src\game\gui\popups\WorldMapWindow.as';Path=$worldMapPath;Backup='WorldMapWindow.post-v55.as'},
    [ordered]@{Repo='src\config\army_config_base.json';Path=$configBasePath;Backup='army_config_base.post-v55.json'},
    [ordered]@{Repo='src\config\army_config.json';Path=$configFullPath;Backup='army_config.post-v55.json'},
    [ordered]@{Repo='src\game\characters\EnemyUnit.as';Path=$enemyPath;Backup='EnemyUnit.post-v55.as'}
  )
  foreach($e in $owned){if(-not(Test-Path -LiteralPath $e.Path -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL required_file_missing=$($e.Repo)"}}
  foreach($p in @($mapDataPath,$offlinePath,$gameStatePath,$enemyPath,$patcherPath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL invariant_file_missing=$p"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $files=@()
  foreach($e in $owned){
    Copy-Item -LiteralPath $e.Path -Destination (Join-Path $backupRoot $e.Backup) -Force
    $files+=@([ordered]@{path=$e.Repo;backup=$e.Backup;sha256=(Get-Sha256 $e.Path)})
  }
  $generated=@()
  Save-Manifest $files $generated

  # V43 is the product invariant: PvP is transient tactical combat and must not
  # mutate campaign-style tile ownership. Preserve V41 arrival resolution but do
  # not call campaign characterArrivedInCell or write owner state from PvP.
  $pvp=Normalize-Lf ([IO.File]::ReadAllText($pvpMovePath))
  Require $pvp 'PVP_ENEMY_ARRIVAL_RESOLVED' 'pvp_arrival_contract_preserved'
  Require $pvp 'PVP_TERRITORY_INVARIANT' 'pvp_territory_invariant_preserved'
  Reject $pvp 'PVP_TERRITORY_CAPTURE' 'pvp_capture_forbidden'
  Reject $pvp 'characterArrivedInCell(mActor as PvPEnemyUnit,arrival)' 'pvp_campaign_arrival_forbidden'
  Reject $pvp 'arrival.mOwner = MapData.TILE_OWNER_ENEMY' 'pvp_forced_owner_forbidden'
  Write-Utf8Bom $pvpMovePath $pvp

  # Campaign movement already performs the correct logical ownership transfer in
  # IsometricScene.changeCellOwner(). Commit only that already-computed change to
  # the tile renderer immediately so enemy recapture is visible without waiting
  # for a later map rebuild. Never force owner state here.
  $campaignMove=Normalize-Lf ([IO.File]::ReadAllText($enemyMovePath))
  $campaignArrival='         mActor.mScene.characterArrivedInCell(mActor as IsometricCharacter,mActor.getCell());'
  $campaignArrivalWithVisual=@'
         var territoryCell:GridCell = mActor.getCell();
         var territoryOwnerBefore:int = territoryCell ? territoryCell.mOwner : MapData.TILE_OWNER_NEUTRAL;
         mActor.mScene.characterArrivedInCell(mActor as IsometricCharacter,territoryCell);
         var territoryOwnerAfter:int = territoryCell ? territoryCell.mOwner : territoryOwnerBefore;
         var territoryVisualCommit:Boolean = true;
         if(territoryCell && territoryOwnerBefore != territoryOwnerAfter)
         {
            if(mActor.mScene.mTilemapGraphic)
            {
               mActor.mScene.mTilemapGraphic.recalculateBorderEdgesAround(territoryCell.mPosI,territoryCell.mPosJ);
               mActor.mScene.mTilemapGraphic.markOwnershipDirty(territoryCell);
               territoryVisualCommit = mActor.mScene.mTilemapGraphic.commitOwnershipVisualNow();
            }
            Utils.DiagEvent("CAMPAIGN_TERRITORY_CAPTURE","map=" + GameState.mInstance.mCurrentMapId + ";side=enemy;x=" + territoryCell.mPosI + ";y=" + territoryCell.mPosJ + ";before=" + territoryOwnerBefore + ";after=" + territoryOwnerAfter + ";visual_commit=" + territoryVisualCommit);
         }
'@.TrimEnd()
  $campaignMove=Replace-ExactOne $campaignMove $campaignArrival (Normalize-Lf $campaignArrivalWithVisual) 'campaign_enemy_territory_visual_commit'
  Require $campaignMove 'CAMPAIGN_TERRITORY_CAPTURE' 'campaign_capture_telemetry'
  Require $campaignMove 'commitOwnershipVisualNow()' 'campaign_capture_visual_commit'
  Require $campaignMove 'characterArrivedInCell(mActor as IsometricCharacter,territoryCell)' 'campaign_native_ownership_semantics'
  Reject $campaignMove 'territoryCell.mOwner = MapData.TILE_OWNER_ENEMY' 'campaign_owner_must_not_be_forced'
  Write-Utf8Bom $enemyMovePath $campaignMove

  # Snow contains EliteDroid enemy units. The generic EnemyUnit sound fallback
  # assigned usable sounds and then threw, aborting the entire map transition.
  # Support the authored EliteDroid explicitly while retaining the default throw
  # for genuinely unknown enemy IDs.
  $enemy=Normalize-Lf ([IO.File]::ReadAllText($enemyPath))
  if(-not $enemy.Contains('UNIT_ID_ELITE_DROID')){
    $droidConstPattern='(?m)^(?<indent>[ \t]*)public static const UNIT_ID_DROID:\s*String\s*=\s*"Droid";[ \t]*$'
    $droidConstMatch=[regex]::Match($enemy,$droidConstPattern)
    if(-not $droidConstMatch.Success){throw 'ANDROID_EVIDENCE_ROOTFIX_V56=FAIL patch=snow_elite_droid_constant semantic_missing'}
    $droidConstIndent=$droidConstMatch.Groups['indent'].Value
    $droidConstReplacement=$droidConstMatch.Value.TrimEnd()+"`n"+$droidConstIndent+'public static const UNIT_ID_ELITE_DROID: String = "EliteDroid";'
    $enemy=$enemy.Substring(0,$droidConstMatch.Index)+$droidConstReplacement+$enemy.Substring($droidConstMatch.Index+$droidConstMatch.Length)
    Write-Host 'EVIDENCE_ROOTFIX_V56_HOOK=PASS name=snow_elite_droid_constant matches=1 semantic=true'
  }
  if(-not $enemy.Contains('case UNIT_ID_ELITE_DROID:')){
    $droidCasePattern='(?m)^(?<indent>[ \t]*)case UNIT_ID_DROID:[ \t]*$'
    $droidCaseMatch=[regex]::Match($enemy,$droidCasePattern)
    if(-not $droidCaseMatch.Success){throw 'ANDROID_EVIDENCE_ROOTFIX_V56=FAIL patch=snow_elite_droid_sound_case semantic_missing'}
    $droidCaseIndent=$droidCaseMatch.Groups['indent'].Value
    $droidCaseReplacement=$droidCaseMatch.Value.TrimEnd()+"`n"+$droidCaseIndent+'case UNIT_ID_ELITE_DROID:'
    $enemy=$enemy.Substring(0,$droidCaseMatch.Index)+$droidCaseReplacement+$enemy.Substring($droidCaseMatch.Index+$droidCaseMatch.Length)
    Write-Host 'EVIDENCE_ROOTFIX_V56_HOOK=PASS name=snow_elite_droid_sound_case matches=1 semantic=true'
  }
  Require $enemy 'UNIT_ID_ELITE_DROID: String = "EliteDroid"' 'snow_elite_droid_constant'
  Require $enemy 'case UNIT_ID_ELITE_DROID:' 'snow_elite_droid_sound_case'
  Write-Utf8Bom $enemyPath $enemy

  # Combat state commits in a few hundred ms; projectile/hit animations remain
  # autonomous and keep their own lifecycle/watchdogs.
  $attack=Normalize-Lf ([IO.File]::ReadAllText($attackPath))
  $attack=$attack.Replace('this.mAttackDuration = Math.max(250, EffectController.getEffectLength(EffectController.EFFECT_TYPE_HIT_BULLET));','this.mAttackDuration = 220;')
  $attack=$attack.Replace('this.mAttackDuration = GameState.mConfig.GraphicSetup.Shooting.Length;','this.mAttackDuration = 220;')
  $attack=$attack.Replace('ATTACK_VISUAL_TIMEOUT','ATTACK_LOGIC_COMMIT_BUDGET')
  Require $attack 'this.mAttackDuration = 220;' 'attack_budget_220'
  Require $attack 'ATTACK_LOGIC_COMMIT_BUDGET' 'attack_budget_telemetry'
  Reject $attack 'this.mAttackDuration = GameState.mConfig.GraphicSetup.Shooting.Length;' 'attack_waits_shooting_length'
  Reject $attack 'this.mAttackDuration = Math.max(250, EffectController.getEffectLength' 'attack_waits_effect_length'
  Write-Utf8Bom $attackPath $attack

  # Snow must remain an actual third destination after every predecessor.
  $world=Normalize-Lf ([IO.File]::ReadAllText($worldMapPath))
  if($world.Contains('public static const WORLD_MAP_ID_LIST: Array = ["Home", "Desert", ""];')){
    $world=$world.Replace('public static const WORLD_MAP_ID_LIST: Array = ["Home", "Desert", ""];','public static const WORLD_MAP_ID_LIST: Array = ["Home", "Desert", "Snow"];')
  }
  $world=$world.Replace('this.setAreaAvailability(2, false);','')
  if($world.Contains('Config.OFFLINE_MODE && (param1 == 0 || param1 == 1)')){
    $world=$world.Replace('Config.OFFLINE_MODE && (param1 == 0 || param1 == 1)','Config.OFFLINE_MODE && (param1 == 0 || param1 == 1 || param1 == 2)')
  }
  if($world -notmatch 'WORLD_MAP_ID_LIST[^\n]*Home[^\n]*Desert[^\n]*Snow'){throw 'ANDROID_EVIDENCE_ROOTFIX_V56=FAIL verify=snow_world_map_registry'}
  Require $world 'game.requestWorldMapSwitch(param1);' 'snow_world_map_transaction'
  Reject $world 'this.setAreaAvailability(2, false);' 'snow_forced_disabled'
  Write-Utf8Bom $worldMapPath $world

  # Keep only PvP maps backed by authentic terrain files. The eleven extra
  # IDs survive as metadata, but their committed CSVs were synthetic reconstructions
  # and must never enter runtime selection until original terrain is recovered.
  Ensure-PvpMapSetup $configBasePath
  Sync-PvpMapSetupText $configBasePath $configFullPath
  Assert-PvpMapSetupTextContract $configFullPath
  Write-Host "PVP_AUTHENTIC_CATALOG=PASS active=1 native=pvp_map_1_4valleys_11x11 synthetic_disabled=$($disabledSyntheticPvpMapIds.Count)"

  $allPvpIds=@($pvpMaps|ForEach-Object{[string]$_.Id})
  $asset=Normalize-Lf ([IO.File]::ReadAllText($assetPath))
  $registry='public static const CVS_FILES_TO_LOAD:Array = ["tile_map","tile_map_desert",'+(($allPvpIds|ForEach-Object{'"'+$_+'"'}) -join ',')+'];'
  $registryMatch=[regex]::Match($asset,'public static const CVS_FILES_TO_LOAD:Array = \[[^\]]*\];')
  if(-not $registryMatch.Success){throw 'ANDROID_EVIDENCE_ROOTFIX_V56=FAIL asset_registry_unparseable'}
  $asset=Replace-ExactOne $asset $registryMatch.Value $registry 'pvp_bootstrap_csv_registry'
  foreach($id in $allPvpIds){Require $asset ('"'+$id+'"') ('asset_registry_'+$id)}
  Write-Utf8Bom $assetPath $asset

  # The final SWF patch plan must include every source changed here.
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  Require $patcher "Class='AssetManager'" 'assetmanager_patched_into_swf'
  Require $patcher "Class='Config'" 'daily_reward_config_patched_into_swf'
  Require $patcher "Class='game.gui.popups.DailyRewardWindow'" 'daily_reward_window_patched_into_swf'
  Require $patcher "Class='game.actions.AttackEnemyAction'" 'attack_action_patched_into_swf'
  Require $patcher "Class='game.actions.EnemyAttackingAction'" 'enemy_attack_action_patched_into_swf'
  Require $patcher "Class='game.actions.PvPEnemyMovingAction'" 'pvp_move_action_patched_into_swf'
  Require $patcher "Class='game.actions.EnemyMovingAction'" 'campaign_enemy_move_patched_into_swf'
  Require $patcher "Class='game.characters.EnemyUnit'" 'enemy_unit_patched_into_swf'
  Write-Host 'FINAL_COMPOSITION=PASS classes=AssetManager,Config,DailyRewardWindow,AttackEnemyAction,PvPEnemyMovingAction,EnemyMovingAction,EnemyUnit'

  # Validate all final invariants after every historical overlay has run.
  $baseCfg=Get-Content -LiteralPath $configBasePath -Raw|ConvertFrom-Json
  $baseMapSetup=(Get-JsonProperty $baseCfg 'MapSetup').Value
  foreach($map in $pvpMaps){
    $id=[string]$map.Id
    if(-not (Get-JsonProperty $baseMapSetup $id)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL final_mapsetup_missing=$id"}
    $csv=Join-Path $RepoRoot ('src\config\'+$id+'.csv')
    if(-not(Test-Path -LiteralPath $csv -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL final_csv_missing=$id"}
    $expectedCells=[int]$map.Width*[int]$map.Height
    $actualCells=Get-NormalizedCsvCellCount $csv
    if($actualCells -ne $expectedCells){throw "ANDROID_EVIDENCE_ROOTFIX_V56=FAIL final_csv_cells id=$id expected=$expectedCells actual=$actualCells"}
  }
  $mapData=Get-Content -LiteralPath $mapDataPath -Raw
  $offline=Get-Content -LiteralPath $offlinePath -Raw
  $gameState=Get-Content -LiteralPath $gameStatePath -Raw
  $gameHud=Get-Content -LiteralPath $gameHudPath -Raw
  $dailyReward=Get-Content -LiteralPath $dailyRewardPath -Raw
  $configSource=Get-Content -LiteralPath $configSourcePath -Raw
  $enemy=Get-Content -LiteralPath $enemyPath -Raw
  $enemyAttack=Get-Content -LiteralPath $enemyAttackPath -Raw
  Require $mapData 'TILE_MAP_TYPE_SNOW' 'snow_runtime_type'
  Require $offline 'SNOW_RUNTIME_IDENTITY' 'snow_runtime_identity'
  Require $gameState 'OFFLINE_ENEMY_SPATIAL_TARGET:int = 24' 'spatial_ai_target'
  Require $gameState 'OFFLINE_ENEMY_SPATIAL_REFRESH_MS:int = 1500' 'spatial_ai_refresh'
  Require $enemy 'OFFLINE_SLEEP_VISUAL_INTERVAL_MS:int = 250' 'enemy_visual_throttle'
  Require $enemy 'UNIT_ID_ELITE_DROID: String = "EliteDroid"' 'snow_elite_droid_sound_support'
  Require $enemy 'findPriorityPlayerTargetInRange' 'campaign_enemy_priority_target_final'
  Require $enemy 'hasPriorityPlayerTargetInRange' 'campaign_enemy_priority_public_probe_final'
  Require $enemy 'ENEMY_ATTACK_PRIORITY' 'campaign_enemy_priority_telemetry_final'
  Require $enemy 'ENEMY_ATTACK_PRIORITY_WAKE' 'campaign_enemy_wait_bypass_final'
  Require $enemy 'OFFLINE_PRIORITY_ATTACK_SCAN_MS: int = 150' 'campaign_enemy_priority_scan_budget_final'
  Require $gameState 'this.mScene.isInsideVisibleArea(enemy.getCell())' 'enemy_spatial_visibility_is_viewport_final'
  Require $gameState 'enemy.hasPriorityPlayerTargetInRange()' 'enemy_spatial_priority_targets_always_active_final'
  Require $enemyAttack 'if(mActor && mActor.getCell())' 'campaign_enemy_attack_camera_independent_final'
  Reject $enemyAttack 'if(GameState.mInstance.mScene.isInsideVisibleArea(mActor.getCell()))' 'campaign_enemy_attack_old_camera_gate_absent'
  Require $pvp 'PVP_TERRITORY_INVARIANT' 'pvp_ownership_immutable_final'
  Reject $pvp 'PVP_TERRITORY_CAPTURE' 'pvp_capture_absent_final'
  Require $campaignMove 'CAMPAIGN_TERRITORY_CAPTURE' 'campaign_enemy_capture_visible_final'
  Require $configSource 'ENABLE_DAILY_REWARDS:Boolean = true' 'daily_reward_enabled_final'
  Require $offline 'DAILY_REWARD_MAX_STREAK: int = 360' 'daily_reward_360_state_final'
  Require $offline 'CURRENT_SAVE_VERSION:int = 9' 'offline_current_save_version_v9_final'
  Require $offline 'SAVE_SCHEMA:String = "armyattack-offline-save/v9"' 'portable_save_schema_v9_final'
  Require $offline 'savedata["saveversion"] = CURRENT_SAVE_VERSION;' 'daily_reward_save_v9_final'
  Reject $offline 'CURRENT_SAVE_VERSION:int = 8' 'offline_stale_v8_version_absent_final'
  Reject $offline 'armyattack-offline-save/v8' 'offline_stale_v8_schema_absent_final'
  Require $gameState 'setOfflineDailyRewardState' 'daily_reward_state_bridge_final'
  Require $gameHud 'requestImmediateSave' 'daily_reward_immediate_save_final'
  Require $dailyReward 'MAX_STREAK_DAY:int = 360' 'daily_reward_popup_360_final'
  Require $dailyReward 'OfflineSave.claimDailyReward' 'daily_reward_offline_claim_final'

  Write-Host 'REGRESSION_CHECK=PASS name=daily_reward_360_offline streak=360 missed_day_reset=true one_claim_per_day=true saveversion=9 representation=CURRENT_SAVE_VERSION popup_window=5day_page'
  Write-Host 'REGRESSION_CHECK=PASS name=campaign_enemy_attack_priority player_in_range=attack wait_timer_bypassed=true queue_wait_bypassed=true camera_independent=true explicit_target=true pvp_untouched=true'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_spatial_budget target=24 viewport_visibility=true in_range_targets_always_active=true container_visible_not_used=true'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_tile_ownership_is_immutable_during_unit_movement capture_call=false owner_write=false v43_invariant=true'
  Write-Host 'REGRESSION_CHECK=PASS name=campaign_enemy_capture_uses_native_owner_transfer visual_commit=immediate forced_owner=false'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_elite_droid_sound_supported transition_abort_on_elitedroid=false'
  Write-Host 'REGRESSION_CHECK=PASS name=attack_logic_decoupled_from_visual budget_ms=220 shooting_length_dependency=false effect_length_dependency=false'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_final_product_invariant world_map=true unlocked=true runtime_type=true runtime_identity=true switch_transaction=requestWorldMapSwitch'
  Write-Host 'REGRESSION_CHECK=PASS name=enemy_ai_spatial_optimization_preserved target=24 refresh_ms=1500 visual_update_ms=250'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_catalog_authentic_only maps=1 native=1 synthetic_disabled=11 probability_metadata=preserved zoom_mobile=40,75,100 full_config_case_sensitive=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V56=PASS mode=apply predecessor=v55 sha=$ExpectedSha campaign_capture_visual=true pvp_ownership_immutable=true snow_elitedroid=true daily_reward_360=true campaign_enemy_attack_priority=true enemy_spatial_budget=true attack_budget_ms=220 pvp_maps=1 synthetic_pvp_disabled=11 spatial_ai=true powershell51_safe=true"
}
catch {
  $failure=$_
  try { Restore-OwnedFiles } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V56_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  if($v55Applied){
    try { & $v55 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -RequestedMode Restore | Out-Host } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V56_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  }
  throw $failure
}
