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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v40=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV40.ps1'
$pvpMovePath=Join-Path $RepoRoot 'src\game\actions\PvPEnemyMovingAction.as'
$pvpSetupPath=Join-Path $RepoRoot 'src\game\gui\pvp\PvPCombatSetupDialog.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v41\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v40 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL predecessor_missing=$v40"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V41_HOOK=PASS name=$Name matches=1 literal=true"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL verify=$Name token=$Token"}}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL restore_backup_missing=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL restore_hash=$($entry.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v40 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V41=PASS mode=restore predecessor=v40 sha=$ExpectedSha"
  return
}

& $v40 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  foreach($required in @($pvpMovePath,$pvpSetupPath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V41=FAIL required_file_missing=$required"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $files=@()
  foreach($pair in @(
    @('src\game\actions\PvPEnemyMovingAction.as',$pvpMovePath,'PvPEnemyMovingAction.post-v40.as'),
    @('src\game\gui\pvp\PvPCombatSetupDialog.as',$pvpSetupPath,'PvPCombatSetupDialog.post-v40.as')
  )){
    Copy-Item -LiteralPath $pair[1] -Destination (Join-Path $backupRoot $pair[2]) -Force
    $files+=@([ordered]@{path=$pair[0];backup=$pair[2];sha256=(Get-Sha256 $pair[1])})
  }
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v41';source_sha=$ExpectedSha;predecessor='v40';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # V39 made path completion commit the visual IDLE state from movement core and
  # clears actor.mDestinationCell. V33's PvP action still used that transient field
  # as its arrival truth, so every physical enemy movement in the supplied V39 trace
  # settled as no_destination and skipped characterArrivedInCell/territory capture.
  # mReservedCell is owned by this action until settle() and survives visual cleanup;
  # prove arrival by comparing the actor's current cell with that reservation.
  $move=Normalize-Lf ([IO.File]::ReadAllText($pvpMovePath))
  $old=@'
         if(actor.isStill())
         {
            if(actor.mDestinationCell && mOriginCell && actor.getCell()) this.settle("arrived",true);
            else this.settle("no_destination",false);
            return true;
         }
'@.TrimEnd()
  $new=@'
         if(actor.isStill())
         {
            var settledCell:GridCell = actor.getCell();
            var reachedReservation:Boolean = Boolean(this.mReservedCell && settledCell && (settledCell == this.mReservedCell || settledCell.mPosI == this.mReservedCell.mPosI && settledCell.mPosJ == this.mReservedCell.mPosJ));
            if(reachedReservation && mOriginCell)
            {
               Utils.DiagEvent("PVP_ENEMY_ARRIVAL_RESOLVED","mode=reserved_cell;from=" + mOriginCell.mPosI + "," + mOriginCell.mPosJ + ";to=" + settledCell.mPosI + "," + settledCell.mPosJ + ";destination_field=" + Boolean(actor.mDestinationCell));
               this.settle("arrived",true);
            }
            else if(actor.mDestinationCell && mOriginCell && settledCell)
            {
               Utils.DiagEvent("PVP_ENEMY_ARRIVAL_RESOLVED","mode=legacy_destination;to=" + settledCell.mPosI + "," + settledCell.mPosJ);
               this.settle("arrived",true);
            }
            else
            {
               Utils.DiagEvent("PVP_ENEMY_ARRIVAL_UNRESOLVED","reserved=" + Boolean(this.mReservedCell) + ";current=" + Boolean(settledCell) + ";origin=" + Boolean(mOriginCell) + ";destination_field=" + Boolean(actor.mDestinationCell));
               this.settle("no_destination",false);
            }
            return true;
         }
'@.TrimEnd()
  $move=Replace-LiteralOne $move (Normalize-Lf $old) (Normalize-Lf $new) 'pvp_enemy_arrival_uses_reserved_cell'
  foreach($token in @('reachedReservation:Boolean','PVP_ENEMY_ARRIVAL_RESOLVED','PVP_ENEMY_ARRIVAL_UNRESOLVED','this.settle("arrived",true)','this.mReservedCell.mPosI')){Require-Token $move $token ('pvp_arrival_'+$token)}
  Write-Utf8Bom $pvpMovePath $move

  # The physical setup trace retries a preserved 2010 Facebook CDN URL three times
  # before falling back locally. That host is legacy/dead for this offline build.
  # Resolve only that known host to the already packaged default avatar; keep all
  # other picture URLs untouched so valid user/opponent pictures still work.
  $setup=Normalize-Lf ([IO.File]::ReadAllText($pvpSetupPath))
  $playerOld='            IconLoader.addIconPicture(_loc6_,_loc3_.mPicID);'
  $playerNew='            IconLoader.addIconPicture(_loc6_,this.resolvePvPPicture(_loc3_.mPicID,"player"));'
  $setup=Replace-LiteralOne $setup $playerOld $playerNew 'pvp_player_legacy_avatar_fallback'
  $opponentOld='            IconLoader.addIconPicture(_loc8_,_loc4_.mPicID);'
  $opponentNew='            IconLoader.addIconPicture(_loc8_,this.resolvePvPPicture(_loc4_.mPicID,"opponent"));'
  $setup=Replace-LiteralOne $setup $opponentOld $opponentNew 'pvp_opponent_legacy_avatar_fallback'
  $helperAnchor='      private function stopStaticButtonDescendants(param1:DisplayObjectContainer) : int'
  $helper=@'
      private function resolvePvPPicture(param1:String, param2:String) : String
      {
         if(param1 && param1.indexOf("profile.ak.fbcdn.net") >= 0)
         {
            Utils.DiagEvent("PVP_PROFILE_IMAGE_FALLBACK","side=" + param2 + ";reason=legacy_facebook_cdn;fallback=../data/avatars/default_avatar.png");
            return "../data/avatars/default_avatar.png";
         }
         return param1;
      }

'@
  $setup=Replace-LiteralOne $setup $helperAnchor ((Normalize-Lf $helper)+$helperAnchor) 'pvp_legacy_avatar_resolver'
  foreach($token in @('resolvePvPPicture','profile.ak.fbcdn.net','PVP_PROFILE_IMAGE_FALLBACK','../data/avatars/default_avatar.png')){Require-Token $setup $token ('pvp_avatar_'+$token)}
  Write-Utf8Bom $pvpSetupPath $setup

  Write-Host 'REGRESSION_CHECK=PASS name=pvp_enemy_arrival_survives_destination_field_cleanup truth=reserved_cell current_cell_match=true'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_enemy_arrival_reaches_territory_capture chain=isOver->settle_arrived->characterArrivedInCell->V40_commit'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_legacy_facebook_avatar_uses_local_fallback retries=0 valid_other_urls=preserved'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V41=PASS mode=apply predecessor=v40 sha=$ExpectedSha pvp_arrival_contract=true legacy_avatar_fallback=true"
}
catch {
  $failure=$_
  try { Restore-OwnedFiles } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V41_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  try { & $v40 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Host } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V41_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  throw $failure
}
