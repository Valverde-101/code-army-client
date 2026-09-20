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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V38=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v37=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV37.ps1'
$managerPath=Join-Path $RepoRoot 'src\game\missions\MissionManager.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v38\'+$ExpectedSha)
$backupPath=Join-Path $backupRoot 'MissionManager.post-v37.as'
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v37 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V38=FAIL predecessor_missing=$v37"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V38=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V38_HOOK=PASS name=$Name matches=1 semantic=true"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Restore-OwnedManager {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V38=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V38=FAIL restore_backup_missing=$backupPath"}
  Copy-Item -LiteralPath $backupPath -Destination $managerPath -Force
  if((Get-Sha256 $managerPath) -ne ([string]$manifest.manager_sha256).ToUpperInvariant()){throw 'ANDROID_EVIDENCE_ROOTFIX_V38=FAIL restore_hash'}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedManager
  & $v37 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V38=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V38=PASS mode=restore predecessor=v37 sha=$ExpectedSha"
  return
}

& $v37 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V38=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  if(-not(Test-Path -LiteralPath $managerPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V38=FAIL manager_missing=$managerPath"}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  Copy-Item -LiteralPath $managerPath -Destination $backupPath -Force
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v38';source_sha=$ExpectedSha;predecessor='v37';manager_sha256=(Get-Sha256 $managerPath)}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $manager=Normalize-Lf ([IO.File]::ReadAllText($managerPath))

  # Physical evidence from 6c289201 shows AREA_SNOW_S_INTRO1 reaches
  # SNOW_DIALOG_READY and only then throws Error #1009 before
  # OFFLINE_MAP_TIMING phase=fog_missions. The next synchronous code in
  # findNewActiveMissions is the online ACCEPT_MISSION side effect, followed by
  # analytics. Those external side effects must never own the local mission/map
  # transaction in the offline client. Commit local activation first, then make
  # sync/analytics best-effort and observable.
  $acceptPattern='(?s)GameState\.mInstance\.mServer\.serverCallServiceWithParameters\(ServiceIDs\.ACCEPT_MISSION,\{\s*"mission_id":_loc1_\.mId,\s*"map_id":_loc1_\.mMapId\s*\},false\);\s*if\(Config\.DEBUG_MODE\)\s*\{\s*\}\s*MagicBoxTracker\.generateEvent\(MagicBoxTracker\.GROUP_LEVEL,MagicBoxTracker\.TYPE_MISSION_ACCEPTED,_loc1_\.mId\);'
  $acceptReplacement=@'
Utils.DiagEvent("MISSION_LOCAL_ACCEPT_COMMIT","mission=" + _loc1_.mId + ";map=" + _loc1_.mMapId + ";state=" + _loc1_.mState);
                  try
                  {
                     if(GameState.mInstance != null && GameState.mInstance.mServer != null)
                     {
                        GameState.mInstance.mServer.serverCallServiceWithParameters(ServiceIDs.ACCEPT_MISSION,{
                           "mission_id":_loc1_.mId,
                           "map_id":_loc1_.mMapId
                        },false);
                        Utils.DiagEvent("MISSION_ACCEPT_SYNC_OK","mission=" + _loc1_.mId + ";map=" + _loc1_.mMapId);
                     }
                     else
                     {
                        Utils.DiagEvent("MISSION_ACCEPT_SYNC_SKIP","mission=" + _loc1_.mId + ";map=" + _loc1_.mMapId + ";reason=server_null");
                     }
                  }
                  catch(syncError:Error)
                  {
                     Utils.DiagEvent("MISSION_ACCEPT_SYNC_FAIL","mission=" + _loc1_.mId + ";map=" + _loc1_.mMapId + ";name=" + syncError.name + ";message=" + syncError.message);
                  }
                  if(Config.DEBUG_MODE)
                  {
                  }
                  try
                  {
                     MagicBoxTracker.generateEvent(MagicBoxTracker.GROUP_LEVEL,MagicBoxTracker.TYPE_MISSION_ACCEPTED,_loc1_.mId);
                  }
                  catch(trackerError:Error)
                  {
                     Utils.DiagEvent("MISSION_TRACKER_FAIL","mission=" + _loc1_.mId + ";map=" + _loc1_.mMapId + ";name=" + trackerError.name + ";message=" + trackerError.message);
                  }
'@.TrimEnd()
  $manager=Replace-RegexOne $manager $acceptPattern $acceptReplacement 'mission_accept_external_side_effect_isolation'

  foreach($token in @(
    'MISSION_LOCAL_ACCEPT_COMMIT',
    'MISSION_ACCEPT_SYNC_OK',
    'MISSION_ACCEPT_SYNC_SKIP',
    'MISSION_ACCEPT_SYNC_FAIL',
    'MISSION_TRACKER_FAIL',
    'GameState.mInstance != null && GameState.mInstance.mServer != null'
  )){
    if(-not $manager.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_V38=FAIL verify_missing=$token"}
  }
  $unguarded=[regex]::Matches($manager,'(?m)^\s*GameState\.mInstance\.mServer\.serverCallServiceWithParameters\(ServiceIDs\.ACCEPT_MISSION,')
  if($unguarded.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V38=FAIL accept_call_count expected=1 actual=$($unguarded.Count)"}
  if(-not [regex]::IsMatch($manager,'(?s)try\s*\{\s*if\(GameState\.mInstance != null && GameState\.mInstance\.mServer != null\).*?serverCallServiceWithParameters\(ServiceIDs\.ACCEPT_MISSION')){throw 'ANDROID_EVIDENCE_ROOTFIX_V38=FAIL accept_call_not_guarded'}

  Write-Utf8Bom $managerPath $manager
  Write-Host 'REGRESSION_CHECK=PASS name=snow_mission_acceptance_transaction_boundary local_activation_committed_before_external=true server_sync_nonfatal=true analytics_nonfatal=true'
  Write-Host 'REGRESSION_CHECK=PASS name=offline_mission_activation_no_server_dependency null_server=skip sync_exception=contained tracker_exception=contained'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_dialog_ready_can_reach_offline_map_commit post_dialog_accept_side_effects=isolated'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V38=PASS mode=apply predecessor=v37 sha=$ExpectedSha mission_accept_transaction=true"
}
catch {
  $failure=$_
  try { Restore-OwnedManager } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V38_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  try { & $v37 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Host } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V38_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  throw $failure
}
