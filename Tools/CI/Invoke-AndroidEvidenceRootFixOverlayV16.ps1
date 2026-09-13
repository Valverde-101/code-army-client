param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL exact_head expected=$ExpectedSha actual=$actual"}

# V15 owns the runtime behavior. V16 is a compatibility compiler for the
# composed V10 -> V15 source. It removes assumptions about neighboring method
# order while preserving the runtime ownership already established by V3/V4.
$v15=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV15.ps1'
if(-not(Test-Path -LiteralPath $v15 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL predecessor_missing=$v15"}
$runtimeScript=Join-Path $PSScriptRoot '.Invoke-AndroidEvidenceRootFixOverlayV15.v16.runtime.ps1'

function Replace-SourceOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL source_anchor=$Name reason=missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL source_anchor=$Name reason=ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V16_SOURCE_ANCHOR=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}

try {
  $patched=[IO.File]::ReadAllText($v15).Replace("`r`n","`n").Replace("`r","`n")

  # Ownership has one owner: V3 already performs partial redraw followed by a
  # synchronous full redraw fallback. V15 must verify that contract, not rewrite
  # the complete method a second time after V4 inserts cache helpers around it.
  $ownershipApplyOld='  $tile=Replace-RegexOne $tile $commitPattern $commitReplacement.TrimEnd() ''ownership_visual_full_fallback'''
  $ownershipApplyNew=@'
  foreach($ownershipToken in @(
    'var committed:Boolean = this.redrawDirtyOwnershipRegion();',
    'var mode:String = committed ? "partial" : "full";',
    'this.requestFullRedraw();',
    'this.updateTilemap();',
    'return committed;'
  )){
    if(-not $tile.Contains($ownershipToken)){throw "ANDROID_EVIDENCE_ROOTFIX_V15=FAIL ownership_predecessor_contract token=$ownershipToken"}
  }
  Write-Host 'EVIDENCE_ROOTFIX_V15_HOOK=PASS name=ownership_visual_full_fallback mode=predecessor_semantic_contract rewrite=false'
'@
  $patched=Replace-SourceOne $patched $ownershipApplyOld $ownershipApplyNew.TrimEnd() 'ownership_single_owner_contract'

  # Missile: V3 inserts mImpactClip ownership between the reset and listener.
  # Accept both shapes and explicitly retain that ownership when V15 adds its
  # wall-clock impact timing and smoke cleanup.
  $missilePatternOld=@'
  $missileArmPattern='(?ms)this\.mImpactFrameTicks = 0;\s*_loc9_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
'@
  $missilePatternNew=@'
  $missileArmPattern='(?ms)this\.mImpactFrameTicks = 0;\s*(?:this\.mImpactClip = _loc9_;\s*)?_loc9_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
'@
  $patched=Replace-SourceOne $patched $missilePatternOld.TrimEnd() $missilePatternNew.TrimEnd() 'missile_arm_accepts_owned_clip'
  $missileBodyOld=@'
this.mImpactFrameTicks = 0;
               this.mImpactStartedAt = getTimer();
               var trailChildrenBefore:int = this.numChildren;
               if(this.mSmoker)
               {
                  this.mSmoker.destroy();
                  this.mSmoker = null;
               }
               Utils.DiagEvent("MISSILE_TRAIL_CLEANUP","children_before=" + trailChildrenBefore + ";children_after=" + this.numChildren + ";budget=16;emit_interval=2");
               _loc9_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
'@
  $missileBodyNew=@'
this.mImpactFrameTicks = 0;
               this.mImpactClip = _loc9_;
               this.mImpactStartedAt = getTimer();
               var trailChildrenBefore:int = this.numChildren;
               if(this.mSmoker)
               {
                  this.mSmoker.destroy();
                  this.mSmoker = null;
               }
               Utils.DiagEvent("MISSILE_TRAIL_CLEANUP","children_before=" + trailChildrenBefore + ";children_after=" + this.numChildren + ";budget=16;emit_interval=2");
               _loc9_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
'@
  $patched=Replace-SourceOne $patched $missileBodyOld.TrimEnd() $missileBodyNew.TrimEnd() 'missile_arm_preserves_owned_clip'

  # checkFrame is bounded by its semantic destroy terminal, not by whichever
  # helper happens to follow it. V4 may insert timeout/destroy helpers before
  # addParticle without invalidating this locator.
  $missileCheckOld=@'
  $missileCheckPattern='(?ms)      private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?\n      \}\s*(?=\n      private function addParticle)'
'@
  $missileCheckNew=@'
  $missileCheckPattern='(?ms)[ \t]*private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?destroy\(\);\s*\}\s*\}'
'@
  $patched=Replace-SourceOne $patched $missileCheckOld.TrimEnd() $missileCheckNew.TrimEnd() 'missile_checkframe_semantic_terminal'

  # Artillery has the same ownership/helper composition as Missile.
  $artilleryPatternOld=@'
  $artilleryArmPattern='(?ms)this\.mImpactFrameTicks = 0;\s*_loc3_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
'@
  $artilleryPatternNew=@'
  $artilleryArmPattern='(?ms)this\.mImpactFrameTicks = 0;\s*(?:this\.mImpactClip = _loc3_;\s*)?_loc3_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
'@
  $patched=Replace-SourceOne $patched $artilleryPatternOld.TrimEnd() $artilleryPatternNew.TrimEnd() 'artillery_arm_accepts_owned_clip'
  $artilleryBodyOld=@'
this.mImpactFrameTicks = 0;
               this.mImpactStartedAt = getTimer();
               _loc3_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
'@
  $artilleryBodyNew=@'
this.mImpactFrameTicks = 0;
               this.mImpactClip = _loc3_;
               this.mImpactStartedAt = getTimer();
               _loc3_.addEventListener(Event.ENTER_FRAME,this.checkFrame,false,0,true);
'@
  $patched=Replace-SourceOne $patched $artilleryBodyOld.TrimEnd() $artilleryBodyNew.TrimEnd() 'artillery_arm_preserves_owned_clip'
  $artilleryCheckOld=@'
  $artilleryCheckPattern='(?ms)      private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?\n      \}\s*(?=\n      private function addParticle)'
'@
  $artilleryCheckNew=@'
  $artilleryCheckPattern='(?ms)[ \t]*private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?destroy\(\);\s*\}\s*\}'
'@
  $patched=Replace-SourceOne $patched $artilleryCheckOld.TrimEnd() $artilleryCheckNew.TrimEnd() 'artillery_checkframe_semantic_terminal'

  # HitEffect is hardened at the same time so a future helper insertion cannot
  # recreate the same adjacency failure class.
  $hitOld=@'
  $hitUpdatePattern='(?ms)      override public function update\(param1:int\)\s*:\s*Boolean\s*\{.*?\n      \}\s*(?=\n      override public function setEffectSpecificValues)'
'@
  $hitNew=@'
  $hitUpdatePattern='(?ms)[ \t]*override public function update\(param1:int\)\s*:\s*Boolean\s*\{.*?return false;\s*\}'
'@
  $patched=Replace-SourceOne $patched $hitOld.TrimEnd() $hitNew.TrimEnd() 'hit_update_semantic_terminal'

  # The regression check must verify the actual V3 ownership implementation.
  $ownershipTestOld="Require-Contains `$tile 'result=full' 'ownership_commit_has_immediate_full_fallback'"
  $ownershipTestNew="Require-Contains `$tile 'var mode:String = committed ? `"partial`" : `"full`";' 'ownership_commit_has_immediate_full_fallback'"
  $patched=Replace-SourceOne $patched $ownershipTestOld $ownershipTestNew 'ownership_test_semantic_contract'

  if($patched.Contains($ownershipApplyOld)){throw 'ANDROID_EVIDENCE_ROOTFIX_V16=FAIL duplicate_ownership_rewrite_remaining'}
  foreach($required in @(
    'ownership_predecessor_contract',
    'this.mImpactClip = _loc9_;',
    'this.mImpactClip = _loc3_;',
    'destroy\(\);\s*\}\s*\}',
    'var mode:String = committed ? "partial" : "full";'
  )){
    if(-not $patched.Contains($required)){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL transformed_contract_missing=$required"}
  }

  [IO.File]::WriteAllText($runtimeScript,$patched,(New-Object System.Text.UTF8Encoding($true)))
  Write-Host 'EVIDENCE_ROOTFIX_V16_COMPAT=PASS ownership=reuse_v3_sync_contract missile=semantic artillery=semantic hit=semantic method_adjacency=false duplicate_ownership_rewrite=false parser_safe=true'
  & $runtimeScript -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL predecessor_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V16=PASS mode=$Mode sha=$ExpectedSha predecessor=v15 composition=semantic"
}
finally {
  if(Test-Path -LiteralPath $runtimeScript -PathType Leaf){Remove-Item -LiteralPath $runtimeScript -Force -ErrorAction SilentlyContinue}
}
