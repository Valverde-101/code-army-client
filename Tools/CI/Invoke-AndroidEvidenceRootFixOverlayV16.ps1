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

# V15 owns the runtime behavior. V16 is the compatibility compiler for the
# composed V10 -> V15 source. Older V15 assumed that methods were adjacent and
# tried to rewrite ownership logic that V3 already makes synchronous. Later
# overlays legitimately insert lifecycle/cache helpers between those methods,
# so every V15 locator below is normalized to a semantic contract before V15
# is executed. This keeps one owner for each behavior and removes order/indent
# coupling without duplicating the runtime implementation.
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

  # Ownership: V3 already owns the synchronous partial->full fallback. Rewriting
  # that method again in V15 is both redundant and the original composition bug.
  $ownershipOld=@'
  $commitPattern='(?ms)      public function commitOwnershipVisualNow\(\)\s*:\s*Boolean\s*\{.*?\n      \}\s*(?=\n      public function updateCameraViewport)'
  $commitReplacement=@'
      public function commitOwnershipVisualNow() : Boolean
      {
         if(!this.mOwnershipDirty)
         {
            Utils.DiagEvent("OWNERSHIP_VISUAL_COMMIT","map=" + GameState.mInstance.mCurrentMapId + ";result=clean");
            return true;
         }
         var reason:String = this.mDirtyReason;
         if(this.redrawDirtyOwnershipRegion())
         {
            Utils.DiagEvent("OWNERSHIP_VISUAL_COMMIT","map=" + GameState.mInstance.mCurrentMapId + ";result=partial;reason=" + reason);
            return true;
         }
         this.requestFullRedraw();
         this.updateTilemap();
         var resolved:Boolean = !this.mOwnershipDirty;
         Utils.DiagEvent("OWNERSHIP_VISUAL_COMMIT","map=" + GameState.mInstance.mCurrentMapId + ";result=full;reason=" + reason + ";resolved=" + resolved);
         return resolved;
      }
'@
  $tile=Replace-RegexOne $tile $commitPattern $commitReplacement.TrimEnd() 'ownership_visual_full_fallback'
'@
  $ownershipNew=@'
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
  $patched=Replace-SourceOne $patched $ownershipOld.TrimEnd() $ownershipNew.TrimEnd() 'ownership_single_owner_contract'

  # Missile: V3 inserts mImpactClip ownership between the watchdog reset and
  # listener. Accept either legacy/predecessor shape and always preserve ownership.
  $missileArmOld=@'
  $missileArmPattern='(?ms)this\.mImpactFrameTicks = 0;\s*_loc9_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
'@
  $missileArmNew=@'
  $missileArmPattern='(?ms)this\.mImpactFrameTicks = 0;\s*(?:this\.mImpactClip = _loc9_;\s*)?_loc9_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
'@
  $patched=Replace-SourceOne $patched $missileArmOld.TrimEnd() $missileArmNew.TrimEnd() 'missile_arm_accepts_owned_clip'
  $missileOwnerOld=@'
this.mImpactFrameTicks = 0;
               this.mImpactStartedAt = getTimer();
'@
  $missileOwnerNew=@'
this.mImpactFrameTicks = 0;
               this.mImpactClip = _loc9_;
               this.mImpactStartedAt = getTimer();
'@
  $patched=Replace-SourceOne $patched $missileOwnerOld.TrimEnd() $missileOwnerNew.TrimEnd() 'missile_arm_preserves_owned_clip'

  # Method boundaries are semantic, not positional: V4 is allowed to insert
  # timeout/destroy helpers after checkFrame before addParticle.
  $missileCheckOld=@'
  $missileCheckPattern='(?ms)      private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?\n      \}\s*(?=\n      private function addParticle)'
'@
  $missileCheckNew=@'
  $missileCheckPattern='(?ms)[ \t]*private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?destroy\(\);\s*\}\s*\}'
'@
  $patched=Replace-SourceOne $patched $missileCheckOld.TrimEnd() $missileCheckNew.TrimEnd() 'missile_checkframe_semantic_terminal'

  # Artillery has the same V3 ownership and V4 helper composition as Missile.
  $artilleryArmOld=@'
  $artilleryArmPattern='(?ms)this\.mImpactFrameTicks = 0;\s*_loc3_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
'@
  $artilleryArmNew=@'
  $artilleryArmPattern='(?ms)this\.mImpactFrameTicks = 0;\s*(?:this\.mImpactClip = _loc3_;\s*)?_loc3_\.addEventListener\(Event\.ENTER_FRAME,this\.checkFrame,false,0,true\);'
'@
  $patched=Replace-SourceOne $patched $artilleryArmOld.TrimEnd() $artilleryArmNew.TrimEnd() 'artillery_arm_accepts_owned_clip'
  $artilleryOwnerOld=@'
this.mImpactFrameTicks = 0;
               this.mImpactStartedAt = getTimer();
'@
  $artilleryOwnerNew=@'
this.mImpactFrameTicks = 0;
               this.mImpactClip = _loc3_;
               this.mImpactStartedAt = getTimer();
'@
  $patched=Replace-SourceOne $patched $artilleryOwnerOld.TrimEnd() $artilleryOwnerNew.TrimEnd() 'artillery_arm_preserves_owned_clip'
  $artilleryCheckOld=@'
  $artilleryCheckPattern='(?ms)      private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?\n      \}\s*(?=\n      private function addParticle)'
'@
  $artilleryCheckNew=@'
  $artilleryCheckPattern='(?ms)[ \t]*private function checkFrame\(param1:Event\)\s*:\s*void\s*\{.*?destroy\(\);\s*\}\s*\}'
'@
  $patched=Replace-SourceOne $patched $artilleryCheckOld.TrimEnd() $artilleryCheckNew.TrimEnd() 'artillery_checkframe_semantic_terminal'

  # HitEffect currently remains adjacent, but make this method independent of
  # future helper insertion now instead of waiting for another composition failure.
  $hitOld=@'
  $hitUpdatePattern='(?ms)      override public function update\(param1:int\)\s*:\s*Boolean\s*\{.*?\n      \}\s*(?=\n      override public function setEffectSpecificValues)'
'@
  $hitNew=@'
  $hitUpdatePattern='(?ms)[ \t]*override public function update\(param1:int\)\s*:\s*Boolean\s*\{.*?return false;\s*\}'
'@
  $patched=Replace-SourceOne $patched $hitOld.TrimEnd() $hitNew.TrimEnd() 'hit_update_semantic_terminal'

  # Runtime regression must validate the V3 ownership contract, not a V15-only
  # literal that no longer owns the method.
  $patched=Replace-SourceOne $patched "Require-Contains `$tile 'result=full' 'ownership_commit_has_immediate_full_fallback'" "Require-Contains `$tile 'var mode:String = committed ? `"partial`" : `"full`";' 'ownership_commit_has_immediate_full_fallback'" 'ownership_test_semantic_contract'

  foreach($legacy in @(
    '(?=\n      public function updateCameraViewport)',
    '(?=\n      private function addParticle)'
  )){
    if($patched.Contains($legacy)){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL legacy_positional_anchor_remaining=$legacy"}
  }
  foreach($required in @(
    'ownership_predecessor_contract',
    'this.mImpactClip = _loc9_;',
    'this.mImpactClip = _loc3_;',
    'missileCheckPattern=',
    'artilleryCheckPattern=',
    'hitUpdatePattern='
  )){
    if(-not $patched.Contains($required)){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL transformed_contract_missing=$required"}
  }

  [IO.File]::WriteAllText($runtimeScript,$patched,(New-Object System.Text.UTF8Encoding($true)))
  Write-Host 'EVIDENCE_ROOTFIX_V16_COMPAT=PASS ownership=reuse_v3_sync_contract missile=semantic artillery=semantic hit=semantic positional_method_adjacency=false duplicate_ownership_rewrite=false'
  & $runtimeScript -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode $Mode
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V16=FAIL predecessor_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V16=PASS mode=$Mode sha=$ExpectedSha predecessor=v15 composition=semantic"
}
finally {
  if(Test-Path -LiteralPath $runtimeScript -PathType Leaf){Remove-Item -LiteralPath $runtimeScript -Force -ErrorAction SilentlyContinue}
}
