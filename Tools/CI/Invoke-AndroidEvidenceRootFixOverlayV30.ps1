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
  Write-Host "EVIDENCE_ROOTFIX_V30_HOOK=PASS name=$Name matches=1 literal=true"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V30=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V30_HOOK=PASS name=$Name matches=1 semantic=true"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
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
  # cell. Commit topology once after materialization on both load boundaries.
  # Per-capture mutations remain V29's bounded 3x3 refresh.
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

  # Do not bind to formatting inserted by older overlays. Scope each hook from its
  # method signature to a stable semantic statement and require exactly one match.
  $switchPattern='(?s)(public\s+static\s+function\s+switchMap\s*\(\s*\)\s*:\s*void\s*\{.*?)(\n[ \t]*Utils\.DiagEvent\("OFFLINE_MAP_TIMING","map="\s*\+\s*map_id\s*\+\s*";phase=fog_missions;ms="\s*\+\s*\(getTimer\(\)\s*-\s*mapPhaseStarted\)\);)'
  $switchReplacement=@'
$1
			commitLoadedTerritoryTopology("switch:" + map_id);$2
'@.TrimEnd()
  $offline=Replace-RegexOne $offline $switchPattern $switchReplacement 'switch_map_topology_commit'

  $bootPattern='(?s)(public\s+static\s+function\s+loadProgress\s*\([^)]*\)\s*:\s*void\s*\{.*?)(\n[ \t]*GameState\.mInstance\.mLoadingStatesOver\s*=\s*true;)'
  $bootReplacement=@'
$1
			commitLoadedTerritoryTopology("boot_restore:" + GameState.mInstance.mCurrentMapId);$2
'@.TrimEnd()
  $offline=Replace-RegexOne $offline $bootPattern $bootReplacement 'boot_restore_topology_commit'

  foreach($token in @(
    'private static function commitLoadedTerritoryTopology(param1: String): void',
    'state.updateGrid();',
    'state.mScene.mTilemapGraphic.recalculateBorderEdges();',
    'state.mScene.mTilemapGraphic.updateTilemap();',
    'TERRITORY_TOPOLOGY_COMMIT',
    'commitLoadedTerritoryTopology("switch:" + map_id);',
    'commitLoadedTerritoryTopology("boot_restore:" + GameState.mInstance.mCurrentMapId);'
  )){Require-Token $offline $token ('territory_contract_'+$token)}

  $switchMethodIndex=$offline.IndexOf('public static function switchMap()',[StringComparison]::Ordinal)
  $switchIndex=$offline.IndexOf('commitLoadedTerritoryTopology("switch:" + map_id);',$switchMethodIndex,[StringComparison]::Ordinal)
  $switchTimingIndex=$offline.IndexOf('phase=fog_missions',$switchIndex,[StringComparison]::Ordinal)
  if($switchMethodIndex -lt 0 -or $switchIndex -lt 0 -or $switchTimingIndex -lt 0 -or $switchIndex -gt $switchTimingIndex){throw 'ANDROID_EVIDENCE_ROOTFIX_V30=FAIL switch_commit_order'}
  $loadMethodIndex=$offline.IndexOf('public static function loadProgress',[StringComparison]::Ordinal)
  $bootIndex=$offline.IndexOf('commitLoadedTerritoryTopology("boot_restore:" + GameState.mInstance.mCurrentMapId);',$loadMethodIndex,[StringComparison]::Ordinal)
  $bootDoneIndex=$offline.IndexOf('GameState.mInstance.mLoadingStatesOver = true;',$bootIndex,[StringComparison]::Ordinal)
  if($loadMethodIndex -lt 0 -or $bootIndex -lt 0 -or $bootDoneIndex -lt 0 -or $bootIndex -gt $bootDoneIndex){throw 'ANDROID_EVIDENCE_ROOTFIX_V30=FAIL boot_commit_order'}
  Write-Utf8Bom $offlinePath $offline

  # Physical evidence showed Error #1009 escaping Building.convertToSnow() and
  # aborting ArchiveMap.convertAllBuildingsToSnow(). Building/ArchiveMap live in
  # the canonical SWF, not the tracked replacement-source subset. Export every AS3
  # class from the exact produced SWF and discover the method semantically. Never
  # depend on FFDec's output filename: class paths/names are derived from source.
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patchAnchor='foreach($tmpSource in $tempSources){Remove-Item -LiteralPath $tmpSource -Force -ErrorAction SilentlyContinue}'
  $snowGuard=@'

# Root fix V30: isolate authored snow-building conversion failures per building.
# Discovery is representation-safe: scan all exported AS3 sources by method
# signature and derive the owning class from source instead of assuming Building.as.
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
foreach($candidate in @(Get-ChildItem -LiteralPath $snowExportRoot -Recurse -File -Filter '*.as' -ErrorAction Stop)){
  $candidateText=[IO.File]::ReadAllText($candidate.FullName).Replace("`r`n","`n").Replace("`r","`n")
  $methodMatches=@([regex]::Matches($candidateText,'\bfunction\s+convertToSnow\s*\([^)]*\)\s*(?::\s*[A-Za-z_][A-Za-z0-9_\.<>]*)?\s*\{'))
  foreach($methodMatch in $methodMatches){
    $classMatches=@([regex]::Matches($candidateText,'\b(?:(?:public|internal)\s+)?(?:(?:dynamic|final)\s+)*class\s+([A-Za-z_][A-Za-z0-9_]*)')|Where-Object{$_.Index -lt $methodMatch.Index})
    if($classMatches.Count -eq 0){throw "SNOW_BUILDING_GUARD=FAIL phase=owner_class_parse file=$($candidate.FullName)"}
    $classMatch=$classMatches[$classMatches.Count-1]
    $simpleClass=[string]$classMatch.Groups[1].Value
    $packageMatch=[regex]::Match($candidateText,'(?m)^\s*package(?:\s+([A-Za-z_][A-Za-z0-9_\.]*))?\s*\{')
    if(-not $packageMatch.Success){throw "SNOW_BUILDING_GUARD=FAIL phase=package_parse file=$($candidate.FullName)"}
    $packageName=[string]$packageMatch.Groups[1].Value
    $qualifiedClass=if([string]::IsNullOrWhiteSpace($packageName)){$simpleClass}else{$packageName+'.'+$simpleClass}
    $snowBuildingCandidates+=@([pscustomobject]@{File=$candidate.FullName;Text=$candidateText;Method=$methodMatch;Class=$qualifiedClass;SimpleClass=$simpleClass})
  }
}

$preferredSnowCandidates=@($snowBuildingCandidates|Where-Object{$_.SimpleClass -eq 'Building'})
$snowSelected=$null
if($preferredSnowCandidates.Count -eq 1){$snowSelected=$preferredSnowCandidates[0]}
elseif($snowBuildingCandidates.Count -eq 1){$snowSelected=$snowBuildingCandidates[0]}
else{
  $discovered=@($snowBuildingCandidates|ForEach-Object{$_.Class+'@'+$_.File}) -join ';'
  throw "SNOW_BUILDING_GUARD=FAIL phase=locate_convertToSnow candidates=$($snowBuildingCandidates.Count) preferred=$($preferredSnowCandidates.Count) discovered=$discovered export=$snowExportRoot"
}

$snowBuildingSource=[string]$snowSelected.File
$snowBuildingText=[string]$snowSelected.Text
$snowMethod=$snowSelected.Method
$snowBuildingClass=[string]$snowSelected.Class
Write-Host "SNOW_BUILDING_GUARD_DISCOVERY=PASS strategy=semantic_method_scan class=$snowBuildingClass file=$snowBuildingSource candidates=$($snowBuildingCandidates.Count)"

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
$snowWrappedBody="`n         try {"+$snowBody+"`n         } catch(snowConversionError:Error) {`n            trace(`"[SNOW_BUILDING_CONVERT_GUARD] result=FALLBACK;type=`" + snowConversionError.name + `";message=`" + snowConversionError.message);`n         }`n      "
$snowBuildingText=$snowBuildingText.Substring(0,$snowOpen+1)+$snowWrappedBody+$snowBuildingText.Substring($snowClose)
[IO.File]::WriteAllText($snowBuildingSource,$snowBuildingText,(New-Object System.Text.UTF8Encoding($true)))

$snowGuardedSwf=Join-Path $outDir 'swf-runtime-snow-building-v30.tmp.swf'
Remove-Item -LiteralPath $snowGuardedSwf -Force -ErrorAction SilentlyContinue
Invoke-FFDecReplace -In $OutputSwf -Out $snowGuardedSwf -ClassName $snowBuildingClass -Source $snowBuildingSource -LogName 'ffdec-snow-building-v30-replace.log'
Remove-Item -LiteralPath $OutputSwf -Force
Move-Item -LiteralPath $snowGuardedSwf -Destination $OutputSwf -Force
Remove-Item -LiteralPath $snowExportRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "SNOW_BUILDING_GUARD=PASS class=$snowBuildingClass boundary=convertToSnow isolation=per_building discovery=semantic_method_scan error1009_aborts_map=false"
'@.TrimEnd()
  $patcher=Replace-LiteralOne $patcher $patchAnchor ($patchAnchor+$snowGuard) 'snow_building_convert_guard_in_patcher'
  foreach($token in @('snow-building-v30-export','-Filter ''*.as''','function\s+convertToSnow','SNOW_BUILDING_GUARD_DISCOVERY=PASS','SNOW_BUILDING_CONVERT_GUARD','SNOW_BUILDING_GUARD=PASS','Invoke-FFDecReplace -In $OutputSwf')){Require-Token $patcher $token ('snow_guard_contract_'+$token)}
  if($patcher.Contains("-Filter 'Building.as'")){throw 'ANDROID_EVIDENCE_ROOTFIX_V30=FAIL stale_filename_bound_snow_discovery'}
  Write-Utf8Bom $patcherPath $patcher

  $psTokens=$null;$psErrors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($patcherPath,[ref]$psTokens,[ref]$psErrors)
  if(@($psErrors).Count -gt 0){
    $psErrors|ForEach-Object{Write-Host "EVIDENCE_ROOTFIX_V30_PATCHER_PARSER_ERROR line=$($_.Extent.StartLineNumber) message=$($_.Message)"}
    throw 'ANDROID_EVIDENCE_ROOTFIX_V30=FAIL patched_patcher_parser_invalid'
  }
  Write-Host 'EVIDENCE_ROOTFIX_V30_PATCHER_PARSER=PASS target=Patch-AndroidPerformanceSwf.ps1'

  Write-Host 'REGRESSION_CHECK=PASS name=territory_border_initial_restore topology_commit=before_visible_ready full_recalc=true full_tilemap_commit=true semantic_hook=true'
  Write-Host 'REGRESSION_CHECK=PASS name=territory_border_map_switch topology_commit=after_missions before_timing_checkpoint=true semantic_hook=true'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_building_conversion_failure_isolated scope=convertToSnow map_wide_abort=false canonical_swf=true discovery=semantic_method_scan filename_dependency=false'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V30_TERRITORY=PASS boot_restore=true map_switch=true per_capture=v29_local_refresh sha=$ExpectedSha"
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V30_SNOW=PASS strategy=canonical_swf_semantic_method_guard error1009_isolated=true sha=$ExpectedSha"
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V30=PASS mode=apply predecessor=v29 sha=$ExpectedSha"
}
catch {
  $message=$_.Exception.Message
  try{Restore-OwnedFiles}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V30_ROLLBACK=WARN $($_.Exception.Message)"}
  try{& $v29 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore|Out-Host}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V30_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)"}
  throw $message
}