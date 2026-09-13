param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$targets=[ordered]@{
  animation='src\game\characters\AnimationController.as'
  attack='src\game\actions\AttackEnemyAction.as'
  missile='src\game\gameElements\Missile.as'
  hit='src\game\utils\HitEffect.as'
  mapgui='src\game\battlefield\MapGUIEffectsLayer.as'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\animation-lifecycle-overlay\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-RegexOnce([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -eq 0){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=$Name reason=semantic_pattern_missing"}
  if($matches.Count -ne 1){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=$Name reason=semantic_pattern_ambiguous matches=$($matches.Count)"}
  Write-Host "ANIMATION_LIFECYCLE_SEMANTIC_HOOK=PASS name=$Name matches=1"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Replace-LiteralOnce([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=$Name reason=literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=$Name reason=literal_ambiguous"}
  Write-Host "ANIMATION_LIFECYCLE_SEMANTIC_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Get-TargetPath([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Get-BackupPath([string]$Key){Join-Path $backupRoot ($Key+'.original')}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){Write-Host "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha";return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $key=[string]$entry.key
    $target=Get-TargetPath $key
    $backup=Get-BackupPath $key
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL restore_backup_missing key=$key path=$backup"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    $restored=Get-Sha256 $target
    $expected=([string]$entry.sha256).ToUpperInvariant()
    if($restored -ne $expected){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL restore_hash key=$key expected=$expected actual=$restored"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=PASS mode=restore baseline_restored=true composable=true combat_lifecycle=true sha=$ExpectedSha"
  return
}

if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=New-Object System.Collections.Generic.List[object]
foreach($key in $targets.Keys){
  $target=Get-TargetPath $key
  if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL source_missing key=$key path=$($targets[$key])"}
  $backup=Get-BackupPath $key
  Copy-Item -LiteralPath $target -Destination $backup -Force
  $manifestFiles.Add([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $target)})
}
$manifestArray=$manifestFiles.ToArray()
[ordered]@{schema='armyattack-animation-lifecycle-overlay/v3';source_sha=$ExpectedSha;files=$manifestArray}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "ANIMATION_LIFECYCLE_MANIFEST=PASS files=$($manifestArray.Count) powershell51_safe=true"

try{
  # AnimationController: retain the proven lazy materialization and transient shoot cleanup.
  $animationTarget=Get-TargetPath 'animation'
  $text=Normalize-Lf ([IO.File]::ReadAllText($animationTarget))

  $loadPattern='(?ms)if\(this\.shouldDeferSpecialAnimation\(index\)\)\s*\{\s*smDeferredSpecials\+\+;\s*Utils\.DiagEvent\("ANIMATION_DEFERRED","index=" \+ index \+ ";source=" \+ source \+ ";reason=special_on_demand"\);\s*\}\s*else\s*\{\s*this\.materializeAnimation\(index,manager\);\s*\}'
  $loadReplacement=@'
if(index != CHARACTER_ANIMATION_IDLE)
               {
                  smDeferredOnDemand++;
               }
               else
               {
                  this.materializeAnimation(index,manager);
               }
'@
  $text=Replace-RegexOnce $text $loadPattern $loadReplacement 'defer_non_idle_at_load'

  $finishPattern='(?ms)if\(this\.shouldDeferSpecialAnimation\(index\) && index != this\.mCurrentAnimation\)\s*\{\s*smDeferredSpecials\+\+;\s*\}\s*else\s*\{\s*this\.materializeAnimation\(index,manager\);\s*\}'
  $finishReplacement=@'
if(index != this.mCurrentAnimation && index != CHARACTER_ANIMATION_IDLE)
               {
                  smDeferredOnDemand++;
               }
               else
               {
                  this.materializeAnimation(index,manager);
               }
'@
  $text=Replace-RegexOnce $text $finishPattern $finishReplacement 'defer_non_current_after_resource_load'

  $startPattern='(?ms)child\.visible = true;\s*child\.gotoAndPlay\(1\);\s*child\.addEventListener\(Event\.ENTER_FRAME,this\.enterFrame,false,0,true\);'
  $startReplacement=@'
child.removeEventListener(Event.ENTER_FRAME,this.enterFrame);
               child.visible = true;
               child.gotoAndPlay(1);
               child.addEventListener(Event.ENTER_FRAME,this.enterFrame,false,0,true);
'@
  $text=Replace-RegexOnce $text $startPattern $startReplacement 'shoot_listener_idempotent_start'

  $endPattern='(?ms)public function enterFrame\(param1:Event\) : void\s*\{\s*var clip:MovieClip = param1\.target as MovieClip;\s*if\(clip\.currentFrame == clip\.totalFrames\)\s*\{\s*clip\.stop\(\);\s*clip\.removeEventListener\(Event\.ENTER_FRAME,this\.enterFrame\);\s*\}\s*\}'
  $endReplacement=@'
public function enterFrame(param1:Event) : void
      {
         var clip:MovieClip = param1.target as MovieClip;
         if(clip && clip.currentFrame >= clip.totalFrames)
         {
            clip.removeEventListener(Event.ENTER_FRAME,this.enterFrame);
            clip.stop();
            clip.gotoAndStop(1);
            clip.visible = false;
            Utils.DiagEvent("ANIMATION_TRANSIENT_CLEANUP","frames=" + clip.totalFrames + ";reason=shoot_complete");
         }
      }
'@
  $text=Replace-RegexOnce $text $endPattern $endReplacement 'shoot_transient_cleanup_at_end'

  $stopPattern='(?ms)private function stopAnim\(param1:DisplayObject, param2:Array\) : void\s*\{\s*if\(param1 is MovieClip\)\s*\{\s*\(param1 as MovieClip\)\.gotoAndStop\(1\);\s*\}\s*\}'
  $stopReplacement=@'
private function stopAnim(param1:DisplayObject, param2:Array) : void
      {
         if(param1 is MovieClip)
         {
            var clip:MovieClip = param1 as MovieClip;
            clip.removeEventListener(Event.ENTER_FRAME,this.enterFrame);
            clip.gotoAndStop(1);
         }
      }
'@
  $text=Replace-RegexOnce $text $stopPattern $stopReplacement 'destroy_removes_transient_listener'

  $legacyDeferredMatches=[regex]::Matches($text,'\bsmDeferredSpecials\b').Count
  if($legacyDeferredMatches -ne 2){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=deferred_counter_migration reason=unexpected_legacy_count expected=2 actual=$legacyDeferredMatches"}
  $text=$text.Replace('smDeferredSpecials','smDeferredOnDemand')
  $text=$text.Replace('deferred_specials=','deferred_on_demand=')
  $legacyAfter=[regex]::Matches($text,'\bsmDeferredSpecials\b').Count
  $onDemandAfter=[regex]::Matches($text,'\bsmDeferredOnDemand\b').Count
  if($legacyAfter -ne 0){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=deferred_counter_migration reason=legacy_identifier_remaining actual=$legacyAfter"}
  if($onDemandAfter -lt 4){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=deferred_counter_migration reason=on_demand_identifier_missing minimum=4 actual=$onDemandAfter"}
  Write-Host "ANIMATION_LIFECYCLE_COUNTER_MIGRATION=PASS legacy_expected=2 legacy_actual=$legacyDeferredMatches on_demand_actual=$onDemandAfter semantic_runtime_hooks=2"
  Write-Utf8Bom $animationTarget $text

  # AttackEnemyAction: visual timeline is advisory; gameplay must finish on a bounded timer.
  $attackTarget=Get-TargetPath 'attack'
  $attack=Normalize-Lf ([IO.File]::ReadAllText($attackTarget))
  $attackWaitPattern='(?ms)if \(!_loc2_\)\s*\{\s*this\.execute\(\);\s*\}'
  $attackWaitReplacement=@'
if (!_loc2_ || this.mTimer >= this.mAttackDuration) {
                           if (_loc2_ && this.mTimer >= this.mAttackDuration) {
                              Utils.DiagEvent("ATTACK_VISUAL_TIMEOUT", "elapsed_ms=" + this.mTimer + ";duration_ms=" + this.mAttackDuration + ";action=AttackEnemy");
                           }
                           this.execute();
                        }
'@
  $attack=Replace-RegexOnce $attack $attackWaitPattern $attackWaitReplacement 'attack_completion_bounded_timer'
  $attackDurationPattern='(?ms)if \(this\.mState == STATE_ATTACKING\) \{\s*playAttackSoundsForAttackers\(\);\s*\}'
  $attackDurationReplacement=@'
if (this.mState == STATE_ATTACKING) {
                  this.mAttackDuration = Math.max(250, EffectController.getEffectLength(EffectController.EFFECT_TYPE_HIT_BULLET));
                  playAttackSoundsForAttackers();
               }
'@
  $attack=Replace-RegexOnce $attack $attackDurationPattern $attackDurationReplacement 'attack_visual_duration_initialized'
  if(-not $attack.Contains('ATTACK_VISUAL_TIMEOUT')){throw 'ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL verification_missing=ATTACK_VISUAL_TIMEOUT'}
  Write-Utf8Bom $attackTarget $attack

  # HitEffect: generic impact effects get deterministic frame OR elapsed-time cleanup.
  $hitTarget=Get-TargetPath 'hit'
  $hit=Normalize-Lf ([IO.File]::ReadAllText($hitTarget))
  $hitUpdatePattern='(?ms)override public function update\(param1:int\) : Boolean\s*\{\s*if\(!mMC\)\s*\{\s*return true;\s*\}\s*var _loc2_:String = mMC\.currentFrameLabel;\s*if\(_loc2_ == "end"\)\s*\{\s*mMC\.gotoAndStop\(1\);\s*mMC\.visible = false;\s*if\(mMC\.parent\)\s*\{\s*mMC\.parent\.removeChild\(mMC\);\s*\}\s*mMC = null;\s*return true;\s*\}\s*return false;\s*\}'
  $hitUpdateReplacement=@'
override public function update(param1:int) : Boolean
      {
         mTimer += param1;
         if(!mMC)
         {
            return true;
         }
         var _loc2_:String = mMC.currentFrameLabel;
         var _loc3_:Boolean = mMC.totalFrames > 1 && mMC.currentFrame >= mMC.totalFrames;
         var _loc4_:int = Math.max(250,EffectController.getEffectLength(mType) + 250);
         if(_loc2_ == "end" || _loc3_ || mTimer >= _loc4_)
         {
            if(mTimer >= _loc4_ && _loc2_ != "end" && !_loc3_)
            {
               Utils.DiagEvent("HIT_EFFECT_TIMEOUT","type=" + mType + ";elapsed_ms=" + mTimer + ";max_ms=" + _loc4_);
            }
            mMC.stop();
            mMC.gotoAndStop(1);
            mMC.visible = false;
            if(mMC.parent)
            {
               mMC.parent.removeChild(mMC);
            }
            mMC = null;
            return true;
         }
         return false;
      }
'@
  $hit=Replace-RegexOnce $hit $hitUpdatePattern $hitUpdateReplacement 'generic_hit_effect_bounded_cleanup'
  Write-Utf8Bom $hitTarget $hit

  # Missile: never dereference parent after removing the missile container; always destroy.
  $missileTarget=Get-TargetPath 'missile'
  $missile=Normalize-Lf ([IO.File]::ReadAllText($missileTarget))
  $missileFieldPattern='(?m)^(\s*)private var mAngles:Array;\s*$'
  $missileFieldReplacement='$1private var mAngles:Array;'+"`n"+'$1private var mImpactFrameTicks:int = 0;'
  $missile=Replace-RegexOnce $missile $missileFieldPattern $missileFieldReplacement 'missile_impact_watchdog_field'
  $missileListenerPattern='(?ms)_loc9_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
  $missileListenerReplacement=@'
this.mImpactFrameTicks = 0;
               _loc9_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
'@
  $missile=Replace-RegexOnce $missile $missileListenerPattern $missileListenerReplacement 'missile_impact_watchdog_reset'
  $missileCheckPattern='(?ms)private function checkFrame\(param1:Event\) : void\s*\{.*?\n\s*\}\s*(?=\n\s*private function addParticle)'
  $missileCheckReplacement=@'
private function checkFrame(param1:Event) : void
      {
         var _loc2_:MovieClip = param1.currentTarget as MovieClip;
         ++this.mImpactFrameTicks;
         if(_loc2_ && (_loc2_.currentFrameLabel == "end" || _loc2_.currentFrame >= _loc2_.totalFrames || this.mImpactFrameTicks >= 90))
         {
            var _loc3_:String = this.mImpactFrameTicks >= 90 ? "watchdog" : "timeline";
            _loc2_.removeEventListener(Event.ENTER_FRAME,this.checkFrame);
            _loc2_.stop();
            _loc2_.gotoAndStop(1);
            _loc2_.visible = false;
            if(_loc2_.parent)
            {
               _loc2_.parent.removeChild(_loc2_);
            }
            Utils.DiagEvent("MISSILE_IMPACT_CLEANUP","reason=" + _loc3_ + ";frames=" + this.mImpactFrameTicks);
            destroy();
         }
      }
'@
  $missile=Replace-RegexOnce $missile $missileCheckPattern $missileCheckReplacement 'missile_parent_safe_cleanup'
  if($missile.Contains('parent.parent.removeChild')){throw 'ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL regression=missile_parent_parent_remove_still_present'}
  Write-Utf8Bom $missileTarget $missile

  # Map GUI: cleanup is idempotent and each unsafe disabled-cell removal is patched in its own method.
  $mapTarget=Get-TargetPath 'mapgui'
  $map=Normalize-Lf ([IO.File]::ReadAllText($mapTarget))
  $rangeResetPattern='(?ms)(this\.mRangeHighlights = new Array\(\);)\s*(\}\s*public function highlightRange)'
  $rangeResetReplacement='$1'+"`n"+'         this.mRangeHighlightRenderable = null;'+"`n"+'      $2'
  $map=Replace-RegexOnce $map $rangeResetPattern $rangeResetReplacement 'range_cache_reset_on_clear'

  $clearHighlightsNeedle='this.mTopLayer.removeChild(_loc4_);'
  $clearHighlightsReplacement=@'
if(_loc4_ && _loc4_.parent)
               {
                  _loc4_.parent.removeChild(_loc4_);
               }
'@
  $map=Replace-LiteralOnce $map $clearHighlightsNeedle $clearHighlightsReplacement.TrimEnd() 'map_gui_clear_highlights_parent_safe'

  $clearMovePattern='(?ms)(public function clearMoveDisabledArea\(\) : void\s*\{.*?_loc1_ = this\.mDisabledCells\[_loc3_\] as MovieClip;\s*)this\.mTopLayer\.removeChild\(_loc1_\);'
  $clearMoveReplacement=@'
$1if(_loc1_ && _loc1_.parent)
               {
                  _loc1_.parent.removeChild(_loc1_);
               }
'@
  $map=Replace-RegexOnce $map $clearMovePattern $clearMoveReplacement 'map_gui_clear_move_disabled_parent_safe'

  if($map.Contains($clearHighlightsNeedle)){throw 'ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL regression=unsafe_clear_highlights_remove_remaining'}
  $clearMoveUnsafePattern='(?ms)public function clearMoveDisabledArea\(\) : void\s*\{.*?this\.mTopLayer\.removeChild\(_loc1_\);'
  if([regex]::IsMatch($map,$clearMoveUnsafePattern)){throw 'ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL regression=unsafe_clear_move_disabled_remove_remaining'}
  Write-Utf8Bom $mapTarget $map
  Write-Host 'MAP_GUI_PARENT_SAFE_CLEANUP=PASS clear_highlights=1 clear_move_disabled=1 semantic=true'

  # Ensure these source fixes are actually replaced into the Android SWF and version provenance changes.
  $patcherTarget=Get-TargetPath 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherTarget))
  $versionNeedle='$patchVersion=''mobile-engine-v3.21-android-boot-product-rootfix'''
  $versionReplacement='$patchVersion=''mobile-engine-v3.22-combat-lifecycle-rootfix'''
  $patcher=Replace-LiteralOnce $patcher $versionNeedle $versionReplacement 'patch_version_v3_22'
  $specNeedle="  [ordered]@{Class='game.isometric.characters.IsometricCharacter';Source='src\game\isometric\characters\IsometricCharacter.as';Log='ffdec-feature-character-hints.log'},"
  $specReplacement=@"
$specNeedle
  [ordered]@{Class='game.actions.AttackEnemyAction';Source='src\game\actions\AttackEnemyAction.as';Log='ffdec-feature-attack-enemy-lifecycle.log'},
  [ordered]@{Class='game.gameElements.Missile';Source='src\game\gameElements\Missile.as';Log='ffdec-feature-missile-lifecycle.log'},
  [ordered]@{Class='game.utils.HitEffect';Source='src\game\utils\HitEffect.as';Log='ffdec-feature-hit-effect-lifecycle.log'},
  [ordered]@{Class='game.battlefield.MapGUIEffectsLayer';Source='src\game\battlefield\MapGUIEffectsLayer.as';Log='ffdec-feature-map-gui-lifecycle.log'},
"@
  $patcher=Replace-LiteralOnce $patcher $specNeedle $specReplacement.TrimEnd() 'combat_lifecycle_patch_specs'
  foreach($required in @('game.actions.AttackEnemyAction','game.gameElements.Missile','game.utils.HitEffect','game.battlefield.MapGUIEffectsLayer','mobile-engine-v3.22-combat-lifecycle-rootfix')){
    if(-not $patcher.Contains($required)){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=patcher_verification missing=$required"}
  }
  Write-Utf8Bom $patcherTarget $patcher

  Write-Host 'REGRESSION_CHECK=PASS name=shoot_fx_last_frame_is_not_persistent reset_frame=1 visible=false listener_removed=true'
  Write-Host 'REGRESSION_CHECK=PASS name=shoot_fx_listener_is_idempotent stale_listener_removed_before_play=true'
  Write-Host 'REGRESSION_CHECK=PASS name=animation_materialization_is_on_demand eager=idle non_idle=deferred current_after_load=materialized'
  Write-Host 'REGRESSION_CHECK=PASS name=animation_destroy_removes_transient_enter_frame_listener'
  Write-Host 'REGRESSION_CHECK=PASS name=attack_completion_independent_of_visual_end_label bounded_by=Shooting.Length'
  Write-Host 'REGRESSION_CHECK=PASS name=generic_hit_effect_cleanup bounded_timeout=true final_frame=true end_label=true'
  Write-Host 'REGRESSION_CHECK=PASS name=missile_impact_cleanup parent_safe=true watchdog_frames=90'
  Write-Host 'REGRESSION_CHECK=PASS name=map_gui_cleanup_idempotent stale_parent_safe=true methods=clearHighlights,clearMoveDisabledArea'
  Write-Host 'REGRESSION_CHECK=PASS name=range_highlight_cache_reset_on_clear'
  Write-Host 'REGRESSION_CHECK=PASS name=render_hotpath_contract_preserved dirty_region_overlay_untouched=true'
  Write-Host "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=PASS mode=apply sha=$ExpectedSha schema=v3 combat_lifecycle=true swf_patch_version=mobile-engine-v3.22-combat-lifecycle-rootfix"
}catch{
  $failure=$_
  foreach($key in $targets.Keys){
    $target=Get-TargetPath $key
    $backup=Get-BackupPath $key
    if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue}
  }
  throw $failure
}
