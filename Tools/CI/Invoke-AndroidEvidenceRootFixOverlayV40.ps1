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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v39=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV39.ps1'
$pvpMovePath=Join-Path $RepoRoot 'src\game\actions\PvPEnemyMovingAction.as'
$pvpSetupPath=Join-Path $RepoRoot 'src\game\gui\pvp\PvPCombatSetupDialog.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v40\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v39 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL predecessor_missing=$v39"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V40_HOOK=PASS name=$Name matches=1 literal=true"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V40_HOOK=PASS name=$Name matches=1 semantic=true"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL verify=$Name token=$Token"}}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL restore_backup_missing=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL restore_hash=$($entry.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v39 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V40=PASS mode=restore predecessor=v39 sha=$ExpectedSha"
  return
}

& $v39 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  foreach($required in @($pvpMovePath,$pvpSetupPath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V40=FAIL required_file_missing=$required"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $files=@()
  foreach($pair in @(
    @('src\game\actions\PvPEnemyMovingAction.as',$pvpMovePath,'PvPEnemyMovingAction.post-v39.as'),
    @('src\game\gui\pvp\PvPCombatSetupDialog.as',$pvpSetupPath,'PvPCombatSetupDialog.post-v39.as')
  )){
    Copy-Item -LiteralPath $pair[1] -Destination (Join-Path $backupRoot $pair[2]) -Force
    $files+=@([ordered]@{path=$pair[0];backup=$pair[2];sha256=(Get-Sha256 $pair[1])})
  }
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v40';source_sha=$ExpectedSha;predecessor='v39';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # PvP enemy movement already knew that PvPEnemyUnit is the opponent side, but
  # physical V39 evidence showed that a player-owned arrival tile could remain
  # visually friendly. Make capture an explicit post-arrival transaction and
  # synchronously commit the same dirty ownership region used by campaign maps.
  $pvpMove=Normalize-Lf ([IO.File]::ReadAllText($pvpMovePath))
  if(-not $pvpMove.Contains('import game.battlefield.MapData;')){
    $pvpMove=Replace-LiteralOne $pvpMove '   import game.characters.PvPEnemyUnit;' "   import game.characters.PvPEnemyUnit;`n   import game.battlefield.MapData;" 'pvp_enemy_capture_mapdata_import'
  }
  $settlePattern='(?ms)(var current:GridCell = actor \? actor\.getCell\(\) : null;\s*)if\(param2 && actor && current && mOriginCell && \(mActor as Element\)\.mScene\)\s*\{\s*\(mActor as Element\)\.mScene\.characterArrivedInCell\(mActor as PvPEnemyUnit,current\);\s*actor\.mPreviousTile = mOriginCell;\s*\}'
  $settleReplacement=@'
$1var arrival:GridCell = this.mReservedCell ? this.mReservedCell : current;
         if(param2 && actor && arrival && mOriginCell && (mActor as Element).mScene)
         {
            var scene:IsometricScene = (mActor as Element).mScene;
            var ownerBefore:int = arrival.mOwner;
            scene.characterArrivedInCell(mActor as PvPEnemyUnit,arrival);
            if(ownerBefore == MapData.TILE_OWNER_FRIENDLY && arrival.mOwner != MapData.TILE_OWNER_ENEMY)
            {
               arrival.mOwner = MapData.TILE_OWNER_ENEMY;
            }
            var ownerAfter:int = arrival.mOwner;
            var visualCommit:Boolean = true;
            if(ownerBefore != ownerAfter)
            {
               if(GameState.mInstance && GameState.mInstance.mMapData)
               {
                  GameState.mInstance.mMapData.mUpdateRequired = true;
               }
               if(scene.mTilemapGraphic)
               {
                  scene.mTilemapGraphic.recalculateBorderEdgesAround(arrival.mPosI,arrival.mPosJ);
                  scene.mTilemapGraphic.markOwnershipDirty(arrival);
                  visualCommit = scene.mTilemapGraphic.commitOwnershipVisualNow();
               }
               Utils.DiagEvent("PVP_TERRITORY_CAPTURE","side=enemy;x=" + arrival.mPosI + ";y=" + arrival.mPosJ + ";before=" + ownerBefore + ";after=" + ownerAfter + ";visual_commit=" + visualCommit);
            }
            else
            {
               Utils.DiagEvent("PVP_TERRITORY_CAPTURE","side=enemy;x=" + arrival.mPosI + ";y=" + arrival.mPosJ + ";before=" + ownerBefore + ";after=" + ownerAfter + ";result=no_change");
            }
            actor.mPreviousTile = mOriginCell;
         }
'@
  $pvpMove=Replace-RegexOne $pvpMove $settlePattern (Normalize-Lf $settleReplacement).TrimEnd() 'pvp_enemy_arrival_capture_transaction'
  foreach($token in @('var arrival:GridCell = this.mReservedCell ? this.mReservedCell : current;','MapData.TILE_OWNER_ENEMY','recalculateBorderEdgesAround(arrival.mPosI,arrival.mPosJ)','markOwnershipDirty(arrival)','commitOwnershipVisualNow()','PVP_TERRITORY_CAPTURE')){Require-Token $pvpMove $token ('pvp_capture_'+$token)}
  Write-Utf8Bom $pvpMovePath $pvpMove

  # The setup screenshot is the authored popup_pvp_armies Toolbox. Buy/Fight use
  # static root button states, but nested MovieClips continue their own timelines.
  # On this asset those descendants can advance from the visible icon frame to a
  # blank frame while the root remains stopped. Pin only descendants of these two
  # static buttons after each state update; Back and the rest of the popup retain
  # their authored animations.
  $setup=Normalize-Lf ([IO.File]::ReadAllText($pvpSetupPath))
  if(-not $setup.Contains('import flash.display.DisplayObject;')){
    $setup=Replace-LiteralOne $setup '   import flash.display.DisplayObjectContainer;' "   import flash.display.DisplayObject;`n   import flash.display.DisplayObjectContainer;" 'pvp_setup_displayobject_import'
  }
  $initialButtons=@'
         this.mButtonFight.playAnim(DCButton.BUTTON_FRAME_NAME_DISABLED_UP);
         this.mButtonBuy.playAnim(DCButton.BUTTON_FRAME_NAME_UP);
'@
  $initialButtonsNew=@'
         this.mButtonFight.playAnim(DCButton.BUTTON_FRAME_NAME_DISABLED_UP);
         this.mButtonBuy.playAnim(DCButton.BUTTON_FRAME_NAME_UP);
         this.stabilizeStaticButtonVisual(this.mButtonFight,"fight_ctor");
         this.stabilizeStaticButtonVisual(this.mButtonBuy,"buy_ctor");
         Utils.DiagEvent("PVP_COMBAT_SETUP_ASSET","resource=swf/popups_pvp;class=popup_pvp_armies;toolbox=Info_Panel/Toolbox;buttons=Back,Buy,Fight");
'@
  $setup=Replace-LiteralOne $setup (Normalize-Lf $initialButtons) (Normalize-Lf $initialButtonsNew) 'pvp_setup_static_button_initial_pin'

  $helperAnchor='      private function removeChildClip(param1:DisplayObjectContainer, param2:String) : void'
  $helper=@'
      private function stopStaticButtonDescendants(param1:DisplayObjectContainer) : int
      {
         if(!param1) return 0;
         var stopped:int = 0;
         var i:int = 0;
         var child:DisplayObject = null;
         var clip:MovieClip = null;
         var container:DisplayObjectContainer = null;
         while(i < param1.numChildren)
         {
            child = param1.getChildAt(i);
            clip = child as MovieClip;
            if(clip)
            {
               clip.stop();
               stopped++;
               stopped += this.stopStaticButtonDescendants(clip);
            }
            else
            {
               container = child as DisplayObjectContainer;
               if(container) stopped += this.stopStaticButtonDescendants(container);
            }
            i++;
         }
         return stopped;
      }

      private function stabilizeStaticButtonVisual(param1:ArmyButton, param2:String) : void
      {
         var root:MovieClip = param1 ? param1.getMovieClip() as MovieClip : null;
         if(!root)
         {
            Utils.DiagEvent("PVP_SETUP_BUTTON_VISUAL","result=missing;reason=" + param2);
            return;
         }
         root.visible = true;
         root.alpha = 1;
         root.stop();
         var stopped:int = this.stopStaticButtonDescendants(root);
         Utils.DiagEvent("PVP_SETUP_BUTTON_VISUAL","result=pinned;button=" + root.name + ";reason=" + param2 + ";frame=" + root.currentFrame + ";label=" + root.currentLabel + ";descendants=" + stopped + ";visible=" + root.visible + ";alpha=" + root.alpha);
      }

'@
  $setup=Replace-LiteralOne $setup $helperAnchor ((Normalize-Lf $helper)+$helperAnchor) 'pvp_setup_static_button_helpers'

  $fightUpdate='         this.mButtonFight.playAnim(smSelectedUnits.length > 0 ? DCButton.BUTTON_FRAME_NAME_UP : DCButton.BUTTON_FRAME_NAME_DISABLED_UP);'
  $fightUpdateNew=@'
         this.mButtonFight.playAnim(smSelectedUnits.length > 0 ? DCButton.BUTTON_FRAME_NAME_UP : DCButton.BUTTON_FRAME_NAME_DISABLED_UP);
         this.stabilizeStaticButtonVisual(this.mButtonFight,"fight_update");
'@
  $setup=Replace-LiteralOne $setup $fightUpdate (Normalize-Lf $fightUpdateNew).TrimEnd() 'pvp_setup_fight_repin_after_state_change'
  foreach($token in @('PVP_COMBAT_SETUP_ASSET','popup_pvp_armies','PVP_SETUP_BUTTON_VISUAL','stopStaticButtonDescendants','stabilizeStaticButtonVisual(this.mButtonFight,"fight_update")')){Require-Token $setup $token ('pvp_setup_'+$token)}
  Write-Utf8Bom $pvpSetupPath $setup

  Write-Host 'REGRESSION_CHECK=PASS name=pvp_enemy_arrival_captures_friendly_tile owner=enemy destination=reserved_or_current model=true'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_enemy_capture_visual_commits_same_action border=local dirty=true commit=immediate telemetry=PVP_TERRITORY_CAPTURE'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_setup_asset_identity resource=swf/popups_pvp class=popup_pvp_armies screenshot_buttons=Back,Buy,Fight'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_setup_buy_fight_icons_persist root=static descendants=pinned back_button_animation=preserved'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V40=PASS mode=apply predecessor=v39 sha=$ExpectedSha pvp_capture=true setup_button_visual=true"
}
catch {
  $failure=$_
  try { Restore-OwnedFiles } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V40_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  try { & $v39 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Host } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V40_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  throw $failure
}
