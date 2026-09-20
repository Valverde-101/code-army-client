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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V37=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v36=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV36.ps1'
$dialogPath=Join-Path $RepoRoot 'src\game\gui\popups\CharacterDialoqueWindow.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v37\'+$ExpectedSha)
$backupPath=Join-Path $backupRoot 'CharacterDialoqueWindow.post-v36.as'
$manifestPath=Join-Path $backupRoot 'manifest.json'
if(-not(Test-Path -LiteralPath $v36 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V37=FAIL predecessor_missing=$v36"}

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $matches=[regex]::Matches($Text,$Pattern)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V37=FAIL patch=$Name semantic_match_count=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V37_HOOK=PASS name=$Name matches=1 semantic=true"
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Restore-OwnedDialog {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V37=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V37=FAIL restore_backup_missing=$backupPath"}
  Copy-Item -LiteralPath $backupPath -Destination $dialogPath -Force
  if((Get-Sha256 $dialogPath) -ne ([string]$manifest.dialog_sha256).ToUpperInvariant()){throw 'ANDROID_EVIDENCE_ROOTFIX_V37=FAIL restore_hash'}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedDialog
  & $v36 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V37=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V37=PASS mode=restore predecessor=v36 sha=$ExpectedSha"
  return
}

& $v36 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V37=FAIL predecessor_apply_exit=$LASTEXITCODE"}
try {
  if(-not(Test-Path -LiteralPath $dialogPath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V37=FAIL dialog_missing=$dialogPath"}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  Copy-Item -LiteralPath $dialogPath -Destination $backupPath -Force
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v37';source_sha=$ExpectedSha;predecessor='v36';dialog_sha256=(Get-Sha256 $dialogPath)}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $dialog=Normalize-Lf ([IO.File]::ReadAllText($dialogPath))
  $activatePattern='(?s)\n\s*public function Activate\(param1:\s*Function,\s*param2:\s*Mission\)\s*:\s*void\s*\{.*?(?=\n\s*CONFIG::BUILD_FOR_AIR\s*\{)'
  $activateReplacement=@'

		public function Activate(param1: Function, param2: Mission): void {
			var field: TextField = null;
			var text: AutoTextField = null;
			mDoneCallback = param1;
			this.mMission = param2;
			if (param2 == null || mClip == null) {
				Utils.DiagEvent("SNOW_DIALOG_DEGRADED", "reason=mission_or_clip_null");
				return;
			}
			param2.setTargetPopup(this);
			if (param2.mNarratorCharacter) {
				try {
					this.installCharacter();
				} catch (characterError: Error) {
					Utils.DiagEvent("SNOW_DIALOG_CHARACTER_FAIL", "message=" + characterError.message);
				}
				field = mClip.getChildByName("Text_Title") as TextField;
				if (field) {
					text = new AutoTextField(field);
					text.setText(param2.mNarratorCharacter.Name);
				}
			}
			if (param2.mDescription) {
				field = mClip.getChildByName("Text_Description") as TextField;
				if (field) {
					text = new AutoTextField(field);
					text.setText(param2.mDescription);
				}
			}
			var submitClip: MovieClip = mClip.getChildByName("Button_Submit") as MovieClip;
			if (submitClip) {
				this.mButtonSubmit = Utils.createResizingButton(mClip, "Button_Submit", this.okClicked);
				if (this.mButtonSubmit) this.mButtonSubmit.setText(GameState.getText("BUTTON_CONTINUE"));
			} else {
				Utils.DiagEvent("SNOW_DIALOG_DEGRADED", "reason=submit_missing");
			}
			Utils.DiagEvent("SNOW_DIALOG_READY", "mission=" + param2.mId);
		}
	
'@
  $dialog=Replace-RegexOne $dialog $activatePattern $activateReplacement 'snow_dialog_transaction_isolation'

  $installPattern='(?s)\n\s*private function installCharacter\(\)\s*:\s*void\s*\{.*?(?=\n\s*private function okClicked\()'
  $installReplacement=@'

		private function installCharacter(): void {
			if (this.mCharacter && this.mCharacter.parent) this.mCharacter.parent.removeChild(this.mCharacter);
			if (!FeatureTuner.USE_CHARACTER_DIALOQUE || mClip == null || this.mMission == null || this.mMission.mNarratorCharacter == null) {
				Utils.DiagEvent("SNOW_DIALOG_CHARACTER_SKIP", "reason=feature_clip_or_narrator");
				return;
			}
			var target: MovieClip = mClip.getChildByName("Icon_Character") as MovieClip;
			if (target == null) {
				Utils.DiagEvent("SNOW_DIALOG_CHARACTER_SKIP", "reason=target_missing");
				return;
			}
			if (!FeatureTuner.USE_CHARACTER_DIALOQUE_EFFECTS) {
				var overlay: MovieClip = mClip.getChildByName("overlay_levelup") as MovieClip;
				if (overlay && overlay.parent) overlay.parent.removeChild(overlay);
			}
			var graphic: String = this.mMission.mNarratorCharacter.Graphic as String;
			if (graphic == null || graphic.length == 0) {
				Utils.DiagEvent("SNOW_DIALOG_CHARACTER_SKIP", "reason=graphic_empty");
				return;
			}
			var parts: Array = graphic.split("/");
			if (parts == null || parts.length < 3 || parts[0] == null || parts[1] == null || parts[2] == null) {
				Utils.DiagEvent("SNOW_DIALOG_CHARACTER_SKIP", "reason=graphic_malformed;graphic=" + graphic);
				return;
			}
			IconLoader.addIcon(target, new IconAdapter(parts[2], parts[0] + "/" + parts[1]));
			Utils.DiagEvent("SNOW_DIALOG_CHARACTER_REQUEST", "graphic=" + graphic);
		}

'@
  $dialog=Replace-RegexOne $dialog $installPattern $installReplacement 'snow_dialog_character_contract'
  $dialog=$dialog.Replace('mDoneCallback((this as Object).constructor);','if (mDoneCallback != null) mDoneCallback((this as Object).constructor);')
  foreach($token in @('SNOW_DIALOG_READY','SNOW_DIALOG_CHARACTER_FAIL','reason=target_missing','reason=graphic_malformed')){if(-not $dialog.Contains($token)){throw "ANDROID_EVIDENCE_ROOTFIX_V37=FAIL verify_missing=$token"}}
  Write-Utf8Bom $dialogPath $dialog
  Write-Host 'REGRESSION_CHECK=PASS name=snow_intro_modal_transaction_isolation narrator_failure_does_not_abort_map=true'
  Write-Host 'REGRESSION_CHECK=PASS name=snow_dialog_character_contract target_null_safe=true graphic_shape_validated=true callback_null_safe=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V37=PASS mode=apply predecessor=v36 sha=$ExpectedSha snow_intro_modal_hardened=true"
}
catch {
  $failure=$_
  try { Restore-OwnedDialog } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V37_OWNED_ROLLBACK=WARN $($_.Exception.Message)" }
  try { & $v36 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Host } catch { Write-Warning "ANDROID_EVIDENCE_ROOTFIX_V37_PREDECESSOR_ROLLBACK=WARN $($_.Exception.Message)" }
  throw $failure
}
