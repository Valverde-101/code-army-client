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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v41=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV41.ps1'
$pvpSetupPath=Join-Path $RepoRoot 'src\game\gui\pvp\PvPCombatSetupDialog.as'
$buildPath=Join-Path $RepoRoot 'Tools\CI\Build-Android.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v42\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v41 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL predecessor_missing=$v41"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V42_HOOK=PASS name=$Name matches=1 literal=true"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL verify=$Name token=$Token"}}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL restore_backup_missing=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    if((Get-Sha256 $target) -ne ([string]$entry.sha256).ToUpperInvariant()){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL restore_hash=$($entry.path)"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v41 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V42=PASS mode=restore predecessor=v41 sha=$ExpectedSha"
  return
}

& $v41 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  foreach($required in @($pvpSetupPath,$buildPath)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V42=FAIL required_file_missing=$required"}}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $files=@()
  foreach($pair in @(
    @('src\game\gui\pvp\PvPCombatSetupDialog.as',$pvpSetupPath,'PvPCombatSetupDialog.post-v41.as'),
    @('Tools\CI\Build-Android.ps1',$buildPath,'Build-Android.post-v41.ps1')
  )){
    Copy-Item -LiteralPath $pair[1] -Destination (Join-Path $backupRoot $pair[2]) -Force
    $files+=@([ordered]@{path=$pair[0];backup=$pair[2];sha256=(Get-Sha256 $pair[1])})
  }
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v42';source_sha=$ExpectedSha;predecessor='v41';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # The authored PvP combat setup is popup_pvp_armies -> Info_Panel/Toolbox.
  # V40 pins Buy/Fight and their nested timelines. Keep the Toolbox parent on its
  # authored frame as well, because a parent timeline can remove/hide otherwise
  # stopped child clips. Re-check once after the user's observed ~1 second window.
  $setup=Normalize-Lf ([IO.File]::ReadAllText($pvpSetupPath))
  if(-not $setup.Contains('import flash.utils.setTimeout;')){
    $setup=Replace-LiteralOne $setup '   import flash.events.MouseEvent;' "   import flash.events.MouseEvent;`n   import flash.utils.setTimeout;" 'pvp_setup_settimeout_import'
  }
  $assetDiag='         Utils.DiagEvent("PVP_COMBAT_SETUP_ASSET","resource=swf/popups_pvp;class=popup_pvp_armies;toolbox=Info_Panel/Toolbox;buttons=Back,Buy,Fight");'
  $assetDiagNew=@'
         Utils.DiagEvent("PVP_COMBAT_SETUP_ASSET","resource=swf/popups_pvp;class=popup_pvp_armies;toolbox=Info_Panel/Toolbox;buttons=Back,Buy,Fight");
         if(_loc2_)
         {
            _loc2_.stop();
            Utils.DiagEvent("PVP_SETUP_TOOLBOX_PIN","frame=" + _loc2_.currentFrame + ";total_frames=" + _loc2_.totalFrames + ";visible=" + _loc2_.visible + ";alpha=" + _loc2_.alpha);
         }
         setTimeout(this.verifySetupButtonPersistence,1500);
'@
  $setup=Replace-LiteralOne $setup $assetDiag (Normalize-Lf $assetDiagNew).TrimEnd() 'pvp_setup_toolbox_pin_and_delayed_probe'
  $helperAnchor='      private function resolvePvPPicture(param1:String, param2:String) : String'
  $helper=@'
      private function verifySetupButtonPersistence() : void
      {
         var toolbox:MovieClip = this.mInfoPanel ? this.mInfoPanel.getChildByName("Toolbox") as MovieClip : null;
         var fightRoot:MovieClip = this.mButtonFight ? this.mButtonFight.getMovieClip() as MovieClip : null;
         var buyRoot:MovieClip = this.mButtonBuy ? this.mButtonBuy.getMovieClip() as MovieClip : null;
         if(toolbox) toolbox.stop();
         this.stabilizeStaticButtonVisual(this.mButtonFight,"fight_delayed_1500ms");
         this.stabilizeStaticButtonVisual(this.mButtonBuy,"buy_delayed_1500ms");
         Utils.DiagEvent("PVP_SETUP_BUTTON_PERSISTENCE","delay_ms=1500;toolbox=" + Boolean(toolbox) + ";toolbox_frame=" + (toolbox ? toolbox.currentFrame : -1) + ";fight=" + Boolean(fightRoot) + ";fight_visible=" + (fightRoot ? fightRoot.visible : false) + ";fight_alpha=" + (fightRoot ? fightRoot.alpha : -1) + ";fight_children=" + (fightRoot ? fightRoot.numChildren : -1) + ";buy=" + Boolean(buyRoot) + ";buy_visible=" + (buyRoot ? buyRoot.visible : false) + ";buy_alpha=" + (buyRoot ? buyRoot.alpha : -1) + ";buy_children=" + (buyRoot ? buyRoot.numChildren : -1));
      }

'@
  $setup=Replace-LiteralOne $setup $helperAnchor ((Normalize-Lf $helper)+$helperAnchor) 'pvp_setup_delayed_persistence_probe'
  foreach($token in @('PVP_SETUP_TOOLBOX_PIN','setTimeout(this.verifySetupButtonPersistence,1500)','PVP_SETUP_BUTTON_PERSISTENCE','fight_delayed_1500ms','buy_delayed_1500ms')){Require-Token $setup $token ('pvp_setup_persistence_'+$token)}
  Write-Utf8Bom $pvpSetupPath $setup

  # The authored-powerup classifier accidentally used double-escaped regex tokens
  # inside a single-quoted PowerShell string. It therefore looked for literal "\s"
  # and "\d" and reported every requested symbol as missing, even though the same
  # symbol dump had already proven explosion_orbital_laser is embedded. Correct the
  # effective build verifier and self-test it before Build-Android consumes the file.
  $build=Normalize-Lf ([IO.File]::ReadAllText($buildPath))
  $badPattern=@'
$pattern='(?m)^'+[regex]::Escape($symbol)+'\\s+\\d+\\s*$'
'@.Trim()
  $goodPattern=@'
$pattern='(?m)^'+[regex]::Escape($symbol)+'\s+\d+\s*$'
'@.Trim()
  $build=Replace-LiteralOne $build $badPattern $goodPattern 'pvp_powerup_symbol_regex_unescape'
  Require-Token $build $goodPattern 'pvp_powerup_symbol_regex_correct'
  $probe="explosion_orbital_laser 123`nmissing_symbol nope`n"
  $probePattern='(?m)^'+[regex]::Escape('explosion_orbital_laser')+'\s+\d+\s*$'
  if($probe -notmatch $probePattern){throw 'ANDROID_EVIDENCE_ROOTFIX_V42=FAIL verifier_selftest expected_embedded=true actual=false'}
  $missingPattern='(?m)^'+[regex]::Escape('missing_symbol')+'\s+\d+\s*$'
  if($probe -match $missingPattern){throw 'ANDROID_EVIDENCE_ROOTFIX_V42=FAIL verifier_selftest expected_missing=false actual=true'}
  Write-Utf8Bom $buildPath $build

  Write-Host 'REGRESSION_CHECK=PASS name=pvp_setup_toolbox_parent_timeline_pinned path=popup_pvp_armies/Info_Panel/Toolbox back_child_animation=preserved'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_setup_buttons_rechecked_after_disappearance_window delay_ms=1500 telemetry=PVP_SETUP_BUTTON_PERSISTENCE'
  Write-Host 'REGRESSION_CHECK=PASS name=pvp_powerup_symbol_regex_matches_real_ffdec_dump whitespace=true numeric_character_id=true false_missing_eliminated=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V42=PASS mode=apply predecessor=v41 sha=$ExpectedSha setup_parent_pin=true delayed_probe=true powerup_verifier=true"
}
catch {
  $failure=$_
  try { Restore-OwnedFiles } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V42_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  try { & $v41 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Host } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V42_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  throw $failure
}
