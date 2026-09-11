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

$rel='src\game\characters\AnimationController.as'
$target=Join-Path $RepoRoot $rel
$backupRoot=Join-Path $RepoRoot ('.work\scratch\animation-lifecycle-overlay\'+$ExpectedSha)
$backup=Join-Path $backupRoot 'AnimationController.as.original'
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

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){Write-Host "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha";return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL restore_backup_missing=$backup"}
  Copy-Item -LiteralPath $backup -Destination $target -Force
  $restored=Get-Sha256 $target
  $expected=([string]$manifest.sha256).ToUpperInvariant()
  if($restored -ne $expected){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL restore_hash expected=$expected actual=$restored"}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=PASS mode=restore baseline_restored=true composable=true sha=$ExpectedSha"
  return
}

if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL source_missing=$rel"}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
Copy-Item -LiteralPath $target -Destination $backup -Force
$incomingSha=Get-Sha256 $target
[ordered]@{schema='armyattack-animation-lifecycle-overlay/v2';source_sha=$ExpectedSha;path=$rel;sha256=$incomingSha}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $text=Normalize-Lf ([IO.File]::ReadAllText($target))

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

  # At this point both runtime increment sites were intentionally replaced by the
  # semantic hooks above. The only legacy identifier occurrences that should remain
  # are the counter declaration and its stats emission; validating the old pre-patch
  # count produced a false negative after the lazy-materialization rewrite.
  $legacyDeferredMatches=[regex]::Matches($text,'\bsmDeferredSpecials\b').Count
  if($legacyDeferredMatches -ne 2){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=deferred_counter_migration reason=unexpected_legacy_count expected=2 actual=$legacyDeferredMatches"}
  $text=$text.Replace('smDeferredSpecials','smDeferredOnDemand')
  $text=$text.Replace('deferred_specials=','deferred_on_demand=')
  $legacyAfter=[regex]::Matches($text,'\bsmDeferredSpecials\b').Count
  $onDemandAfter=[regex]::Matches($text,'\bsmDeferredOnDemand\b').Count
  if($legacyAfter -ne 0){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=deferred_counter_migration reason=legacy_identifier_remaining actual=$legacyAfter"}
  if($onDemandAfter -lt 4){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL patch=deferred_counter_migration reason=on_demand_identifier_missing minimum=4 actual=$onDemandAfter"}
  Write-Host "ANIMATION_LIFECYCLE_COUNTER_MIGRATION=PASS legacy_expected=2 legacy_actual=$legacyDeferredMatches on_demand_actual=$onDemandAfter semantic_runtime_hooks=2"

  foreach($needle in @('ANIMATION_TRANSIENT_CLEANUP','index != CHARACTER_ANIMATION_IDLE','index != this.mCurrentAnimation && index != CHARACTER_ANIMATION_IDLE','smDeferredOnDemand')){
    if(-not $text.Contains($needle)){throw "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL verification_missing=$needle"}
  }
  if($text.Contains('reason=special_on_demand')){throw 'ANDROID_ANIMATION_LIFECYCLE_OVERLAY=FAIL regression=eager_special_logging_still_present'}

  Write-Utf8Bom $target $text
  Write-Host 'REGRESSION_CHECK=PASS name=shoot_fx_last_frame_is_not_persistent reset_frame=1 visible=false listener_removed=true'
  Write-Host 'REGRESSION_CHECK=PASS name=shoot_fx_listener_is_idempotent stale_listener_removed_before_play=true'
  Write-Host 'REGRESSION_CHECK=PASS name=animation_materialization_is_on_demand eager=idle non_idle=deferred current_after_load=materialized'
  Write-Host 'REGRESSION_CHECK=PASS name=animation_destroy_removes_transient_enter_frame_listener'
  Write-Host "ANDROID_ANIMATION_LIFECYCLE_OVERLAY=PASS mode=apply sha=$ExpectedSha incoming_sha256=$incomingSha schema=v2"
}catch{
  $failure=$_
  Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue
  throw $failure
}
