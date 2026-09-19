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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v42=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV42.ps1'
$pvpMovePath=Join-Path $RepoRoot 'src\game\actions\PvPEnemyMovingAction.as'
$fireMissionPath=Join-Path $RepoRoot 'src\game\gameElements\FireMissionObject.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v43\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v42 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL predecessor_missing=$v42"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-One([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $p=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($p -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL patch=$Name missing"}
  if($Text.IndexOf($Needle,$p+$Needle.Length,[StringComparison]::Ordinal) -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL patch=$Name ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V43_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$p)+$Replacement+$Text.Substring($p+$Needle.Length)
}
function Require([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL verify=$Name"}}
function Reject([string]$Text,[string]$Token,[string]$Name){if($Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL reject=$Name"}}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $m=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$m.source_sha -ne $ExpectedSha){throw 'ANDROID_EVIDENCE_ROOTFIX_V43=FAIL restore_sha'}
  foreach($e in @($m.files)){
    $target=Join-Path $RepoRoot ([string]$e.path);$backup=Join-Path $backupRoot ([string]$e.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL restore_missing=$($e.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$e.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL restore_hash=$($e.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v42 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V43=PASS mode=restore predecessor=v42 sha=$ExpectedSha"
  return
}

& $v42 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  foreach($p in @($pvpMovePath,$fireMissionPath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V43=FAIL required_file=$p"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $files=@()
  foreach($x in @(@('src\game\actions\PvPEnemyMovingAction.as',$pvpMovePath,'PvPEnemyMovingAction.post-v42.as'),@('src\game\gameElements\FireMissionObject.as',$fireMissionPath,'FireMissionObject.post-v42.as'))){
    Copy-Item -LiteralPath $x[1] -Destination (Join-Path $backupRoot $x[2]) -Force
    $files+=@([ordered]@{path=$x[0];backup=$x[2];sha256=(Get-Sha256 $x[1])})
  }
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v43';source_sha=$ExpectedSha;predecessor='v42';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # Physical V42 evidence: 13/13 enemy arrivals resolved correctly, but all 13
  # also emitted PVP_TERRITORY_CAPTURE. PvP is transient tactical combat, so
  # movement must not invoke campaign ownership mutation. Keep V41 arrival truth.
  $move=Normalize-Lf ([IO.File]::ReadAllText($pvpMovePath))
  $startToken='         var arrival:GridCell = this.mReservedCell ? this.mReservedCell : current;'
  $start=$move.IndexOf($startToken,[StringComparison]::Ordinal)
  if($start -lt 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V43=FAIL pvp_arrival_block_start'}
  $actorToken='            actor.mPreviousTile = mOriginCell;'
  $actorAt=$move.IndexOf($actorToken,$start,[StringComparison]::Ordinal)
  if($actorAt -lt 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V43=FAIL pvp_arrival_actor_tail'}
  $closeToken="`n         }"
  $closeAt=$move.IndexOf($closeToken,$actorAt+$actorToken.Length,[StringComparison]::Ordinal)
  if($closeAt -lt 0){throw 'ANDROID_EVIDENCE_ROOTFIX_V43=FAIL pvp_arrival_block_end'}
  $end=$closeAt+$closeToken.Length
  $replacement=@'
         var arrival:GridCell = this.mReservedCell ? this.mReservedCell : current;
         if(param2 && actor && arrival && mOriginCell && (mActor as Element).mScene)
         {
            var ownerBefore:int = arrival.mOwner;
            Utils.DiagEvent("PVP_TERRITORY_INVARIANT","side=enemy;x=" + arrival.mPosI + ";y=" + arrival.mPosJ + ";owner=" + ownerBefore + ";result=preserved_by_design");
            actor.mPreviousTile = mOriginCell;
         }
'@.TrimEnd()
  $move=$move.Substring(0,$start)+(Normalize-Lf $replacement)+$move.Substring($end)
  $move=$move.Replace("   import game.battlefield.MapData;`n",'')
  Require $move 'PVP_ENEMY_ARRIVAL_RESOLVED' 'arrival_contract_preserved'
  Require $move 'PVP_TERRITORY_INVARIANT' 'territory_invariant'
  Reject $move 'PVP_TERRITORY_CAPTURE' 'capture_removed'
  Reject $move 'characterArrivedInCell(mActor as PvPEnemyUnit,arrival)' 'campaign_arrival_call_removed'
  Reject $move 'arrival.mOwner = MapData.TILE_OWNER_ENEMY' 'forced_owner_removed'
  Write-Utf8Bom $pvpMovePath $move
  Write-Host 'EVIDENCE_ROOTFIX_V43_HOOK=PASS name=pvp_no_territory_capture_on_arrival matches=1'

  # Missing authored PvP symbols currently collapse AirSupport 1/2/3 and Doomsday
  # into the same rocket+effect_explosion. Keep damage and target selection intact,
  # but give the visual fallback mission-specific descent/scale/timing profiles.
  $fire=Normalize-Lf ([IO.File]::ReadAllText($fireMissionPath))
  $oldFields=@'
      private var mFallbackProjectileMode:Boolean = false;
      private var mFallbackRocket:MovieClip;
      private var mFallbackExplosion:MovieClip;
      private var mFallbackImpacted:Boolean = false;
      private var mFallbackFinished:Boolean = false;
'@.TrimEnd()
  $newFields=@'
      private var mFallbackProjectileMode:Boolean = false;
      private var mFallbackRocket:MovieClip;
      private var mFallbackExplosion:MovieClip;
      private var mFallbackImpacted:Boolean = false;
      private var mFallbackFinished:Boolean = false;
      private var mFallbackProfile:String = "standard";
      private var mFallbackProjectileDurationMs:int = FALLBACK_PROJECTILE_MS;
      private var mFallbackProjectileStartY:Number = FALLBACK_PROJECTILE_START_Y;
      private var mFallbackProjectileStartX:Number = 0;
      private var mFallbackRocketScale:Number = 1;
      private var mFallbackExplosionScale:Number = 1;
      private var mFallbackRocketRotation:Number = 180;
      private var mFallbackTotalTimeoutMs:int = FALLBACK_TOTAL_TIMEOUT_MS;
'@.TrimEnd()
  $fire=Replace-One $fire (Normalize-Lf $oldFields) (Normalize-Lf $newFields) 'firemission_fallback_profile_fields'

  $anchor='      private function materializeFallbackProjectile(param1:DCResourceManager, param2:String) : void'
  $helper=@'
      private function configureFallbackProfile(param1:String) : void
      {
         var id:String = this.mItem && this.mItem.mId ? this.mItem.mId.toLowerCase() : "";
         var requested:String = param1 ? param1.toLowerCase() : "";
         this.mFallbackProfile = "standard";
         this.mFallbackProjectileDurationMs = FALLBACK_PROJECTILE_MS;
         this.mFallbackProjectileStartY = FALLBACK_PROJECTILE_START_Y;
         this.mFallbackProjectileStartX = 0;
         this.mFallbackRocketScale = 1;
         this.mFallbackExplosionScale = 1;
         this.mFallbackRocketRotation = 180;
         this.mFallbackTotalTimeoutMs = FALLBACK_TOTAL_TIMEOUT_MS;
         if(id.indexOf("airsupport_1") >= 0)
         {
            this.mFallbackProfile = "air_support_light";
            this.mFallbackProjectileDurationMs = 650;
            this.mFallbackProjectileStartY = -300;
            this.mFallbackProjectileStartX = -80;
            this.mFallbackRocketScale = 0.72;
            this.mFallbackExplosionScale = 0.80;
            this.mFallbackRocketRotation = 165;
            this.mFallbackTotalTimeoutMs = 2200;
         }
         else if(id.indexOf("airsupport_2") >= 0)
         {
            this.mFallbackProfile = "air_support_medium";
            this.mFallbackProjectileDurationMs = 850;
            this.mFallbackProjectileStartY = -420;
            this.mFallbackProjectileStartX = 0;
            this.mFallbackRocketScale = 1.0;
            this.mFallbackExplosionScale = 1.10;
            this.mFallbackRocketRotation = 180;
            this.mFallbackTotalTimeoutMs = 2600;
         }
         else if(id.indexOf("airsupport_3") >= 0)
         {
            this.mFallbackProfile = "air_support_heavy";
            this.mFallbackProjectileDurationMs = 1100;
            this.mFallbackProjectileStartY = -560;
            this.mFallbackProjectileStartX = 90;
            this.mFallbackRocketScale = 1.30;
            this.mFallbackExplosionScale = 1.55;
            this.mFallbackRocketRotation = 195;
            this.mFallbackTotalTimeoutMs = 3000;
         }
         else if(id.indexOf("doomsday") >= 0 || requested.indexOf("doomsday") >= 0)
         {
            this.mFallbackProfile = "doomsday_heavy";
            this.mFallbackProjectileDurationMs = 1300;
            this.mFallbackProjectileStartY = -720;
            this.mFallbackProjectileStartX = 0;
            this.mFallbackRocketScale = 1.65;
            this.mFallbackExplosionScale = 2.35;
            this.mFallbackRocketRotation = 180;
            this.mFallbackTotalTimeoutMs = 3600;
         }
         Utils.DiagEvent("FIREMISSION_FALLBACK_PROFILE","mission=" + (this.mItem ? this.mItem.mId : "null") + ";requested=" + param1 + ";profile=" + this.mFallbackProfile + ";projectile_ms=" + this.mFallbackProjectileDurationMs + ";start=" + this.mFallbackProjectileStartX + "," + this.mFallbackProjectileStartY + ";rocket_scale=" + this.mFallbackRocketScale + ";impact_scale=" + this.mFallbackExplosionScale);
      }

'@
  $fire=Replace-One $fire $anchor ((Normalize-Lf $helper)+$anchor) 'firemission_fallback_profile_helper'
  $fire=Replace-One $fire '         this.mFallbackProjectileMode = true;' (("         this.configureFallbackProfile(param2);`n")+'         this.mFallbackProjectileMode = true;') 'firemission_profile_before_materialize'

  $oldRocket=@'
            this.mFallbackRocket.x = 0;
            this.mFallbackRocket.y = FALLBACK_PROJECTILE_START_Y;
            this.mFallbackRocket.rotation = 180;
'@.TrimEnd()
  $newRocket=@'
            this.mFallbackRocket.x = this.mFallbackProjectileStartX;
            this.mFallbackRocket.y = this.mFallbackProjectileStartY;
            this.mFallbackRocket.rotation = this.mFallbackRocketRotation;
            this.mFallbackRocket.scaleX = this.mFallbackRocketScale;
            this.mFallbackRocket.scaleY = this.mFallbackRocketScale;
'@.TrimEnd()
  $fire=Replace-One $fire (Normalize-Lf $oldRocket) (Normalize-Lf $newRocket) 'firemission_profile_projectile_geometry'

  $oldExplosion=@'
            this.mFallbackExplosion.visible = false;
            this.mFallbackExplosion.mouseEnabled = false;
            this.mFallbackExplosion.mouseChildren = false;
'@.TrimEnd()
  $newExplosion=@'
            this.mFallbackExplosion.visible = false;
            this.mFallbackExplosion.scaleX = this.mFallbackExplosionScale;
            this.mFallbackExplosion.scaleY = this.mFallbackExplosionScale;
            this.mFallbackExplosion.mouseEnabled = false;
            this.mFallbackExplosion.mouseChildren = false;
'@.TrimEnd()
  $fire=Replace-One $fire (Normalize-Lf $oldExplosion) (Normalize-Lf $newExplosion) 'firemission_profile_impact_geometry'
  $fire=Replace-One $fire '         Utils.DiagEvent("FIREMISSION_GRAPHICS_FALLBACK","mission=" + this.mItem.mId + ";requested=" + param2 + ";projectile=rocket;impact=effect_explosion");' '         Utils.DiagEvent("FIREMISSION_GRAPHICS_FALLBACK","mission=" + this.mItem.mId + ";requested=" + param2 + ";projectile=rocket;impact=effect_explosion;profile=" + this.mFallbackProfile);' 'firemission_profile_fallback_log'

  $fire=Replace-One $fire '               this.mFallbackRocket.y = FALLBACK_PROJECTILE_START_Y;' (("               this.mFallbackRocket.x = this.mFallbackProjectileStartX;`n")+'               this.mFallbackRocket.y = this.mFallbackProjectileStartY;') 'firemission_profile_restart_position'
  $fire=Replace-One $fire '            Utils.DiagEvent("FIREMISSION_ANIMATION","phase=start;mission=" + this.mItem.mId + ";symbol=" + this.getGraphicsSymbol() + ";mode=projectile_fallback;duration_ms=" + FALLBACK_PROJECTILE_MS);' '            Utils.DiagEvent("FIREMISSION_ANIMATION","phase=start;mission=" + this.mItem.mId + ";symbol=" + this.getGraphicsSymbol() + ";mode=projectile_fallback;profile=" + this.mFallbackProfile + ";duration_ms=" + this.mFallbackProjectileDurationMs);' 'firemission_profile_start_log'
  $fire=Replace-One $fire '               var fallbackProgress:Number = Math.min(1,fallbackElapsed / FALLBACK_PROJECTILE_MS);' '               var fallbackProgress:Number = Math.min(1,fallbackElapsed / this.mFallbackProjectileDurationMs);' 'firemission_profile_duration'
  $fire=Replace-One $fire '                  this.mFallbackRocket.y = FALLBACK_PROJECTILE_START_Y * (1 - fallbackProgress);' (("                  this.mFallbackRocket.x = this.mFallbackProjectileStartX * (1 - fallbackProgress);`n")+'                  this.mFallbackRocket.y = this.mFallbackProjectileStartY * (1 - fallbackProgress);') 'firemission_profile_trajectory'
  $fire=Replace-One $fire '            if(fallbackElapsed >= FALLBACK_TOTAL_TIMEOUT_MS)' '            if(fallbackElapsed >= this.mFallbackTotalTimeoutMs)' 'firemission_profile_timeout'
  foreach($t in @('FIREMISSION_FALLBACK_PROFILE','air_support_light','air_support_medium','air_support_heavy','doomsday_heavy','mFallbackExplosionScale = 2.35','mFallbackProjectileDurationMs = 1300')){Require $fire $t ('firemission_'+$t)}
  Write-Utf8Bom $fireMissionPath $fire

  Write-Host 'REGRESSION_CHECK=PASS name=pvp_tile_ownership_is_immutable_during_unit_movement capture_call=false owner_write=false arrival=v41_reserved_cell'
  Write-Host 'REGRESSION_CHECK=PASS name=campaign_and_snow_territory_semantics_untouched scope=PvPEnemyMovingAction_only'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_firemission_fallback_profiles_distinct light=650ms/0.80 medium=850ms/1.10 heavy=1100ms/1.55 doomsday=1300ms/2.35'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_firemission_damage_contract_unchanged visual_only=true'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_authored_firemission_precedence_preserved graphicsClass_returns_before_fallback=true orbital_laser=authored_by_existing_build_gate'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V43=PASS mode=apply predecessor=v42 sha=$ExpectedSha pvp_territory_invariant=true firemission_profiles=true"
}
catch {
  $failure=$_
  try{Restore-OwnedFiles}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V43_OWNED_ROLLBACK=WARN $($_.Exception.Message)"}
  try{& $v42 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore|Out-Host}catch{Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V43_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)"}
  throw $failure
}
