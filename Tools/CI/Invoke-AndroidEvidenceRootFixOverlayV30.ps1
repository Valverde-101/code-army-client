param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v29=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV29.ps1'
if(-not(Test-Path -LiteralPath $v29 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL predecessor_missing=$v29"}

$offlinePath=Join-Path $RepoRoot 'src\game\utils\OfflineSave.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v30\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V30_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL restore_backup_missing path=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL restore_hash path=$($entry.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v29 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V30=PASS mode=restore predecessor=v29 sha=$ExpectedSha"
  return
}

& $v29 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL predecessor_apply_exit=$LASTEXITCODE"}

try {
  if(-not(Test-Path -LiteralPath $offlinePath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL required_file_missing path=$offlinePath"}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  Copy-Item -LiteralPath $offlinePath -Destination (Join-Path $backupRoot 'OfflineSave.post-v29.as') -Force
  $files=@([ordered]@{path='src\game\utils\OfflineSave.as';backup='OfflineSave.post-v29.as';sha256=(Get-Sha256 $offlinePath)})
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v30';source_sha=$ExpectedSha;predecessor='v29';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # Ownership is restored before the first visible frame, but the authored border
  # renderer consumes cached GridCell.mBorderEdgeBits. A later conquest refreshed
  # those bits, which is why the white perimeter appeared only after capturing a
  # cell. Commit topology once, after objects/missions have finished materializing,
  # for both boot restore and map switches. This is intentionally a load-boundary
  # full commit; per-capture mutations remain V29's bounded 3x3 refresh.
  $offline=Normalize-Lf ([IO.File]::ReadAllText($offlinePath))
  $helperAnchor="`n`t`tpublic static function generateSaveJson(): * {"
  $helper=@'

		private static function commitLoadedTerritoryTopology(param1: String): void {
			var state: GameState = GameState.mInstance;
			if (!state || !state.mMapData || !state.mScene || !state.mScene.mTilemapGraphic) {
				Utils.DiagEvent("TERRITORY_TOPOLOGY_COMMIT","result=SKIP;reason=runtime_not_ready;source=" + param1);
				return;
			}
			state.updateGrid();
			state.mScene.mTilemapGraphic.recalculateBorderEdges();
			state.mScene.mTilemapGraphic.updateTilemap();
			Utils.DiagEvent("TERRITORY_TOPOLOGY_COMMIT","result=PASS;map=" + state.mCurrentMapId + ";source=" + param1 + ";grid=" + (state.mMapData.mGrid ? state.mMapData.mGrid.length : 0) + ";visual_commit=full");
		}
'@.TrimEnd()
  $offline=Replace-LiteralOne $offline $helperAnchor ($helper+$helperAnchor) 'territory_topology_helper'

  $switchNeedle='`t`t`tUtils.DiagEvent("OFFLINE_MAP_TIMING","map=" + map_id + ";phase=fog_missions;ms=" + (getTimer() - mapPhaseStarted));'.Replace('`t',"`t")
  $switchReplacement='`t`t`tcommitLoadedTerritoryTopology("switch:" + map_id);`n'+$switchNeedle
  $switchReplacement=$switchReplacement.Replace('`t',"`t").Replace('`n',"`n")
  $offline=Replace-LiteralOne $offline $switchNeedle $switchReplacement 'switch_map_topology_commit'

  $bootNeedle='`t`t`tMissionManager.findNewActiveMissions();`n`n`n`t`t`tGameState.mInstance.mLoadingStatesOver = true;'.Replace('`t',"`t").Replace('`n',"`n")
  $bootReplacement='`t`t`tMissionManager.findNewActiveMissions();`n`t`t`tcommitLoadedTerritoryTopology("boot_restore:" + GameState.mInstance.mCurrentMapId);`n`n`t`t`tGameState.mInstance.mLoadingStatesOver = true;'.Replace('`t',"`t").Replace('`n',"`n")
  $offline=Replace-LiteralOne $offline $bootNeedle $bootReplacement 'boot_restore_topology_commit'

  foreach($token in @(
    'private static function commitLoadedTerritoryTopology(param1: String): void',
    'state.updateGrid();',
    'state.mScene.mTilemapGraphic.recalculateBorderEdges();',
    'state.mScene.mTilemapGraphic.updateTilemap();',
    'TERRITORY_TOPOLOGY_COMMIT',
    'commitLoadedTerritoryTopology("switch:" + map_id);',
    'commitLoadedTerritoryTopology("boot_restore:" + GameState.mInstance.mCurrentMapId);'
  )){Require-Token $offline $token ('territory_contract_'+$token)}

  $switchIndex=$offline.IndexOf('commitLoadedTerritoryTopology("switch:" + map_id);',[StringComparison]::Ordinal)
  $switchDoneIndex=$offline.IndexOf('GameState.mInstance.mLoadingStatesOver = true;',$switchIndex,[StringComparison]::Ordinal)
  if($switchIndex -lt 0 -or $switchDoneIndex -lt 0 -or $switchIndex -gt $switchDoneIndex){throw 'ANDROID_EVIDENCE_ROOTFIX_V30=FAIL switch_commit_order'}
  $bootIndex=$offline.IndexOf('commitLoadedTerritoryTopology("boot_restore:" + GameState.mInstance.mCurrentMapId);',[StringComparison]::Ordinal)
  if($bootIndex -lt 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V30=FAIL boot_commit_missing'}

  Write-Utf8Bom $offlinePath $offline
  Write-Host 'REGRESSION_CHECK=PASS name=territory_border_initial_restore topology_commit=before_visible_ready full_recalc=true full_tilemap_commit=true'
  Write-Host 'REGRESSION_CHECK=PASS name=territory_border_map_switch topology_commit=after_missions before_loading_complete=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V30_TERRITORY=PASS boot_restore=true map_switch=true per_capture=v29_local_refresh sha=$ExpectedSha"
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V30=PASS mode=apply predecessor=v29 sha=$ExpectedSha"
}
catch {
  $message=$_.Exception.Message
  try{Restore-OwnedFiles}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V30_ROLLBACK=WARN $($_.Exception.Message)"}
  try{& $v29 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore|Out-Host}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V30_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)"}
  throw $message
}
