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
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
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
  foreach($required in @($offlinePath,$patcherPath)){
    if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL required_file_missing path=$required"}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  Copy-Item -LiteralPath $offlinePath -Destination (Join-Path $backupRoot 'OfflineSave.post-v29.as') -Force
  Copy-Item -LiteralPath $patcherPath -Destination (Join-Path $backupRoot 'Patch-AndroidPerformanceSwf.post-v29.ps1') -Force
  $files=@(
    [ordered]@{path='src\game\utils\OfflineSave.as';backup='OfflineSave.post-v29.as';sha256=(Get-Sha256 $offlinePath)},
    [ordered]@{path='Tools\CI\Patch-AndroidPerformanceSwf.ps1';backup='Patch-AndroidPerformanceSwf.post-v29.ps1';sha256=(Get-Sha256 $patcherPath)}
  )
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

  # Snow map failure evidence shows Error #1009 propagating from
  # Building.convertToSnow() through ArchiveMap.convertAllBuildingsToSnow(), which
  # aborts the whole first-entry conversion. Building/ArchiveMap are authored
  # classes that live in the canonical SWF rather than this tracked source subset.
  # Patch the exact canonical Building class at SWF build time: decompile the
  # produced SWF, locate the one convertToSnow implementation, wrap that building's
  # conversion boundary, and reinsert it. A bad/missing optional snow visual can no
  # longer abort conversion of every remaining building or the map transition.
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patchAnchor='foreach($tmpSource in $tempSources){Remove-Item -LiteralPath $tmpSource -Force -ErrorAction SilentlyContinue}'
  $snowGuard=@'

# Root fix V30: isolate authored snow-building conversion failures per building.
# Physical evidence showed Error #1009 escaping Building.convertToSnow() and
# aborting ArchiveMap.convertAllBuildingsToSnow(). Building is not part of the
# tracked replacement-source subset, so derive the exact class from this exact
# source SWF at build time and reinsert only that class.
$snowExportRoot=Join-Path $outDir 'snow-building-v30-export'
Remove-Item -LiteralPath $snowExportRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $snowExportRoot|Out-Null
$snowExportLog=Join-Path $logRoot 'ffdec-snow-building-v30-export.log'
$snowExportArgs=@('-cli','-air','-onerror','abort','-export','script',$snowExportRoot,$OutputSwf)
$previousErrorActionPreference=$ErrorActionPreference
try {
  $ErrorActionPreference='Continue'
  if($java){$snowExportLines=@(& $java.Source '-jar' $ffdec.FullName @snowExportArgs 2>&1|ForEach-Object{$_.ToString()})}
  else{$snowExportLines=@(& $ffdec.FullName @snowExportArgs 2>&1|ForEach-Object{$_.ToString()})}
  $snowExportExit=$LASTEXITCODE
} finally {$ErrorActionPreference=$previousErrorActionPreference}
$snowExportLines|Set-Content -LiteralPath $snowExportLog -Encoding UTF8
if($snowExportExit -ne 0){throw "SNOW_BUILDING_GUARD=FAIL phase=export exit=$snowExportExit log=$snowExportLog"}

$snowBuildingCandidates=@()
foreach($candidate in @(Get-ChildItem -LiteralPath $snowExportRoot -Recurse -File -Filter 'Building.as' -ErrorAction Stop)){
  $candidateText=[IO.File]::ReadAllText($candidate.FullName)
  if($candidateText -match '\bfunction\s+convertToSnow\s*\('){$snowBuildingCandidates+=@($candidate)}
}
if($snowBuildingCandidates.Count -ne 1){
  throw "SNOW_BUILDING_GUARD=FAIL phase=locate_convertToSnow candidates=$($snowBuildingCandidates.Count) export=$snowExportRoot"
}
$snowBuildingSource=$snowBuildingCandidates[0].FullName
$snowBuildingText=[IO.File]::ReadAllText($snowBuildingSource).Replace("`r`n","`n").Replace("`r","`n")
$snowMethod=[regex]::Match($snowBuildingText,'\bfunction\s+convertToSnow\s*\([^)]*\)\s*:\s*void\s*\{')
if(-not $snowMethod.Success){throw 'SNOW_BUILDING_GUARD=FAIL phase=method_signature'}
$snowOpen=$snowMethod.Index+$snowMethod.Length-1
$snowDepth=0
$snowClose=-1
for($scan=$snowOpen;$scan -lt $snowBuildingText.Length;$scan++){
  $ch=$snowBuildingText[$scan]
  if($ch -eq '{'){$snowDepth++}
  elseif($ch -eq '}'){
    $snowDepth--
    if($snowDepth -eq 0){$snowClose=$scan;break}
  }
}
if($snowClose -le $snowOpen){throw 'SNOW_BUILDING_GUARD=FAIL phase=method_braces'}
$snowBody=$snowBuildingText.Substring($snowOpen+1,$snowClose-$snowOpen-1)
if($snowBody.Contains('SNOW_BUILDING_CONVERT_GUARD')){throw 'SNOW_BUILDING_GUARD=FAIL phase=already_instrumented'}
$snowWrappedBody="`n         try {"+$snowBody+"`n         } catch(snowConversionError:Error) {`n            trace(\"[SNOW_BUILDING_CONVERT_GUARD] result=FALLBACK;type=\" + snowConversionError.name + \";message=\" + snowConversionError.message);`n         }`n      "
$snowBuildingText=$snowBuildingText.Substring(0,$snowOpen+1)+$snowWrappedBody+$snowBuildingText.Substring($snowClose)
[IO.File]::WriteAllText($snowBuildingSource,$snowBuildingText,(New-Object System.Text.UTF8Encoding($true)))

$snowPackageMatch=[regex]::Match($snowBuildingText,'(?m)^\s*package(?:\s+([A-Za-z_][A-Za-z0-9_\.]*))?\s*\{')
if(-not $snowPackageMatch.Success){throw 'SNOW_BUILDING_GUARD=FAIL phase=package_parse'}
$snowPackage=[string]$snowPackageMatch.Groups[1].Value
$snowBuildingClass=if([string]::IsNullOrWhiteSpace($snowPackage)){'Building'}else{$snowPackage+'.Building'}
$snowGuardedSwf=Join-Path $outDir 'swf-runtime-snow-building-v30.tmp.swf'
Remove-Item -LiteralPath $snowGuardedSwf -Force -ErrorAction SilentlyContinue
Invoke-FFDecReplace -In $OutputSwf -Out $snowGuardedSwf -ClassName $snowBuildingClass -Source $snowBuildingSource -LogName 'ffdec-snow-building-v30-replace.log'
Remove-Item -LiteralPath $OutputSwf -Force
Move-Item -LiteralPath $snowGuardedSwf -Destination $OutputSwf -Force
Remove-Item -LiteralPath $snowExportRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "SNOW_BUILDING_GUARD=PASS class=$snowBuildingClass boundary=convertToSnow isolation=per_building error1009_aborts_map=false"
'@.TrimEnd()
  $patcher=Replace-LiteralOne $patcher $patchAnchor ($patchAnchor+$snowGuard) 'snow_building_convert_guard_in_patcher'
  foreach($token in @('snow-building-v30-export','function\s+convertToSnow','SNOW_BUILDING_CONVERT_GUARD','SNOW_BUILDING_GUARD=PASS','Invoke-FFDecReplace -In $OutputSwf')){Require-Token $patcher $token ('snow_guard_contract_'+$token)}
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=territory_border_initial_restore topology_commit=before_visible_ready full_recalc=true full_tilemap_commit=true'
  Write-Host 'REGRESSION_CHECK=PASS name=territory_border_map_switch topology_commit=after_missions before_loading_complete=true'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_building_conversion_failure_isolated scope=Building.convertToSnow map_wide_abort=false canonical_swf=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V30_TERRITORY=PASS boot_restore=true map_switch=true per_capture=v29_local_refresh sha=$ExpectedSha"
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V30_SNOW=PASS strategy=canonical_swf_building_guard error1009_isolated=true sha=$ExpectedSha"
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V30=PASS mode=apply predecessor=v29 sha=$ExpectedSha"
}
catch {
  $message=$_.Exception.Message
  try{Restore-OwnedFiles}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V30_ROLLBACK=WARN $($_.Exception.Message)"}
  try{& $v29 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore|Out-Host}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V30_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)"}
  throw $message
}
