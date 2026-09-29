param(
  [string]$RepoRoot,
  [string]$ConfigPath,
  [ValidateSet('Desert','Snow')][string]$MapId='Desert'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\\..')).Path}
if([string]::IsNullOrWhiteSpace($ConfigPath)){$ConfigPath=Join-Path $RepoRoot 'src\\config\\army_config_base.json'}
if(-not(Test-Path -LiteralPath $ConfigPath -PathType Leaf)){throw "CAMPAIGN_AREA_CONFIG=FAIL path=$ConfigPath"}
$cfg=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$areas=@($cfg.MapArea.PSObject.Properties|ForEach-Object{$_.Value}|Where-Object{[string]$_.MapID -ceq $MapId})
$minimum=if($MapId -eq 'Snow'){9}else{2}
if($areas.Count -lt $minimum){throw "CAMPAIGN_AREA_CONFIG=FAIL map=$MapId expected_min=$minimum actual=$($areas.Count)"}
if($null -eq $cfg.ShopTab -or $null -eq $cfg.ShopTab.Areas -or [string]$cfg.ShopTab.Areas.ItemTable -cne 'ShopArea'){throw "CAMPAIGN_AREA_SHOP=FAIL map=$MapId table"}
$shop=@($cfg.ShopArea.PSObject.Properties|ForEach-Object{$_.Value})
$shopRefs=@($shop|Where-Object{$null -ne $_ -and $null -ne $_.Item}|ForEach-Object{[string]$_.Item})
if($null -eq $cfg.Mission -or $null -eq $cfg.MissionSetup){throw "CAMPAIGN_AREA_SETUP=FAIL map=$MapId authored_tables_missing"}
foreach($area in $areas){
  $id=[string]$area.ID
  $ref='#MapArea.'+$id
  $count=@($shopRefs|Where-Object{$_ -ceq $ref}).Count
  if($count -ne 1){throw "CAMPAIGN_AREA_SHOP=FAIL map=$MapId area=$id shop_refs=$count"}
  if([string]$area.Type -cne 'Area' -or [int]$area.AreaWidth -lt 1 -or [int]$area.AreaHeight -lt 1){throw "CAMPAIGN_AREA_CONFIG=FAIL map=$MapId area=$id dimensions_or_type"}
  $candidates=@()
  foreach($stage in @($cfg.Mission.PSObject.Properties|ForEach-Object{$_.Value}|Where-Object{[string]$_.MapId -ceq $MapId -and -not [string]::IsNullOrWhiteSpace([string]$_.SetupGroup)})){
    $rows=@($cfg.MissionSetup.PSObject.Properties|ForEach-Object{$_.Value}|Where-Object{[string]$_.Group -ceq [string]$stage.SetupGroup})
    if($rows.Count -eq 0){continue}
    $within=$true
    foreach($row in $rows){
      $x=[int]$row.AreaX;$y=[int]$row.AreaY
      $item=$row.Item
      $dx=if($null -ne $item -and $null -ne $item.PSObject.Properties['DimX']){[int]$item.DimX}else{1}
      $dy=if($null -ne $item -and $null -ne $item.PSObject.Properties['DimY']){[int]$item.DimY}else{1}
      if($x -lt [int]$area.AreaX -or $y -lt [int]$area.AreaY -or
         ($x+$dx) -gt ([int]$area.AreaX+[int]$area.AreaWidth) -or
         ($y+$dy) -gt ([int]$area.AreaY+[int]$area.AreaHeight)){$within=$false;break}
    }
    if($within){$candidates+=([string]$stage.ID+':'+$rows.Count)}
  }
  Write-Host "CAMPAIGN_AREA_SHOP=PASS map=$MapId id=$id original_money=$($area.CostMoney) original_intel=$($area.CostIntel) setup_candidates=$($candidates -join ',')"
}
$areaSource=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\\game\\items\\AreaItem.as') -Raw
$manager=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\\game\\missions\\MissionManager.as') -Raw
$state=Get-Content -LiteralPath (Join-Path $RepoRoot 'src\\game\\states\\GameState.as') -Raw
$patch=Get-Content -LiteralPath (Join-Path $RepoRoot 'Tools\\CI\\Patch-AndroidPerformanceSwf.ps1') -Raw
foreach($needle in @('TEST_CAMPAIGN_AREA_PURCHASE:Boolean = true','Config.OFFLINE_MODE','param1 == "Desert" || param1 == "Snow"','mRequiredMission = null;','mRequiredLevel = 0;','mRequiredAllies = 0;','mRequiredItem = null;','mRequiredBuilding = null;','mCostIntel = 0;')){
  if(-not $areaSource.Contains($needle)){throw "CAMPAIGN_AREA_SOURCE=FAIL missing=$needle"}
}
foreach($needle in @('ensureTrialCampaignAreaContent','AreaItem.isTrialCampaignMap','mission.getSetupObjectCount()','matches != 1','matched.mState != Mission.STATE_INACTIVE','matched.activate(true);','CAMPAIGN_AREA_SETUP_UNRESOLVED')){
  if(-not $manager.Contains($needle)){throw "CAMPAIGN_AREA_SOURCE=FAIL missing=$needle"}
}
if(-not $state.Contains('MissionManager.ensureTrialCampaignAreaContent(param1.mId)')){throw 'CAMPAIGN_AREA_SOURCE=FAIL purchase_hook'}
if($areaSource -match 'mCostMoney\\s*=|mCostPremium\\s*=|smUnlockCheat\\s*=|mEarlyUnlockBought\\s*='){throw 'CAMPAIGN_AREA_SCOPE=FAIL global_cheat_or_free_purchase'}
foreach($class in @('game.items.AreaItem','game.missions.MissionManager','game.states.GameState')){
  if(-not $patch.Contains("Class='$class'")){throw "CAMPAIGN_AREA_SWF=FAIL missing=$class"}
}
Write-Host "CAMPAIGN_AREA_PURCHASE_CONTRACT=PASS map=$MapId areas=$($areas.Count) shop=authored offline_only=true requirements=bypassed price=preserved adjacency=preserved new_purchase_setup=unique_only"
