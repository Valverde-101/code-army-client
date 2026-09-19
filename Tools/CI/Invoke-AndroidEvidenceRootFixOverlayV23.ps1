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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v22=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV22.ps1'
if(-not(Test-Path -LiteralPath $v22 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL predecessor_missing=$v22"}

$pausePath=Join-Path $RepoRoot 'src\game\gui\PauseDialog.as'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v23\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V23_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL restore_backup_missing path=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    $actualHash=Get-Sha256 $target
    $expectedHash=([string]$entry.sha256).ToUpperInvariant()
    if($actualHash -ne $expectedHash){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL restore_hash path=$($entry.path) expected=$expectedHash actual=$actualHash"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v22 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V23=PASS mode=restore predecessor=v22 sha=$ExpectedSha"
  return
}

& $v22 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL predecessor_apply_exit=$LASTEXITCODE"}

try {
  foreach($path in @($pausePath,$patcherPath)){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V23=FAIL required_file_missing path=$path"}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $files=@()
  foreach($spec in @(
    [ordered]@{path='src\game\gui\PauseDialog.as';backup='PauseDialog.post-v22.as'},
    [ordered]@{path='Tools\CI\Patch-AndroidPerformanceSwf.ps1';backup='Patch-AndroidPerformanceSwf.post-v22.ps1'}
  )){
    $target=Join-Path $RepoRoot ([string]$spec.path)
    $backup=Join-Path $backupRoot ([string]$spec.backup)
    Copy-Item -LiteralPath $target -Destination $backup -Force
    $files+=@([ordered]@{path=[string]$spec.path;backup=[string]$spec.backup;sha256=(Get-Sha256 $target)})
  }
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v23';source_sha=$ExpectedSha;predecessor='v22';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # Root cause observed on the Android 15 physical report for c1fecfe7:
  # the picker opened four times, but SELECT never reached the handler and there
  # was no SAVE_IMPORT_COMMIT or SAVE_IMPORT_REJECTED. V22 created the File only
  # as a local variable and registered the handler as a weak listener. Once
  # startSelectingFile returned, nothing kept the AS3 File/handler graph alive
  # while Android's external document picker owned the screen.
  $pause=Normalize-Lf ([IO.File]::ReadAllText($pausePath))

  $fieldNeedle="`t`tprivate var mButtonLoad: ArmyButton;"
  $fieldReplacement=@'
		private var mButtonLoad: ArmyButton;

		CONFIG::BUILD_FOR_MOBILE_AIR {
			private var mExternalSaveFile: File;
		}
'@.TrimEnd()
  $pause=Replace-LiteralOne $pause $fieldNeedle $fieldReplacement 'mobile_picker_strong_member'

  $oldPicker=@'
			CONFIG::BUILD_FOR_MOBILE_AIR {
				var mobileFile:File = new File();
				mobileFile.addEventListener(Event.SELECT, this.onExternalSaveSelected, false, 0, true);
				mobileFile.browseForOpen("Importar partida Army Attack");
				Utils.DiagEvent("SAVE_IMPORT_PICKER_OPEN", "source=android_document_picker");
			}
'@.TrimEnd()
  $newPicker=@'
			CONFIG::BUILD_FOR_MOBILE_AIR {
				if (this.mExternalSaveFile) this.releaseExternalSavePicker();
				this.mExternalSaveFile = new File();
				this.mExternalSaveFile.addEventListener(Event.SELECT, this.onExternalSaveSelected, false, 0, false);
				this.mExternalSaveFile.addEventListener(Event.CANCEL, this.onExternalSaveCancelled, false, 0, false);
				try {
					this.mExternalSaveFile.browseForOpen("Importar partida Army Attack");
					Utils.DiagEvent("SAVE_IMPORT_PICKER_OPEN", "source=android_document_picker;lifetime=strong");
				} catch (error:Error) {
					this.releaseExternalSavePicker();
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=picker_exception;type=" + error.name + ";message=" + error.message);
				}
			}
'@.TrimEnd()
  $pause=Replace-LiteralOne $pause $oldPicker $newPicker 'mobile_picker_strong_lifetime'

  $oldHandler=@'
			private function onExternalSaveSelected(evt:Event):void {
				var selected:File = evt && evt.target is File ? evt.target as File : null;
				if (!selected) {
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=no_file");
					return;
				}
				selected.removeEventListener(Event.SELECT, this.onExternalSaveSelected);
				try {
					var fs:FileStream = new FileStream();
					fs.open(selected, FileMode.READ);
					var raw:String = fs.readUTFBytes(fs.bytesAvailable);
					fs.close();
					var savedata:* = JSON.parse(raw);
					var validation:String = OfflineSave.validatePortableSave(savedata);
					if (validation.indexOf("PASS:") != 0) {
						Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=validation;result=" + validation + ";name=" + selected.name);
						return;
					}
					var normalized:String = JSON.stringify(savedata);
					var internalFile:File = File.applicationStorageDirectory.resolvePath("savefile.txt");
					var backupFile:File = File.applicationStorageDirectory.resolvePath("savefile.before-import.txt");
					if (internalFile.exists) internalFile.copyTo(backupFile, true);
					var tempFile:File = File.applicationStorageDirectory.resolvePath("savefile.import.tmp");
					var out:FileStream = new FileStream();
					out.open(tempFile, FileMode.WRITE);
					out.writeUTFBytes(normalized);
					out.close();
					tempFile.moveTo(internalFile, true);
					Utils.DiagEvent("SAVE_IMPORT_COMMIT", "validation=" + validation + ";bytes=" + normalized.length + ";name=" + selected.name + ";backup=" + backupFile.name);
					loadProgress(savedata);
				} catch (error:Error) {
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=exception;type=" + error.name + ";message=" + error.message);
				}
			}
'@.TrimEnd()
  $newHandler=@'
			private function releaseExternalSavePicker():void {
				var pending:File = this.mExternalSaveFile;
				if (pending) {
					pending.removeEventListener(Event.SELECT, this.onExternalSaveSelected);
					pending.removeEventListener(Event.CANCEL, this.onExternalSaveCancelled);
				}
				this.mExternalSaveFile = null;
			}

			private function onExternalSaveCancelled(evt:Event):void {
				this.releaseExternalSavePicker();
				Utils.DiagEvent("SAVE_IMPORT_CANCELLED", "source=android_document_picker");
			}

			private function onExternalSaveSelected(evt:Event):void {
				var selected:File = evt && evt.target is File ? evt.target as File : this.mExternalSaveFile;
				Utils.DiagEvent("SAVE_IMPORT_SELECTED", "source=android_document_picker;name=" + (selected ? selected.name : "null"));
				this.releaseExternalSavePicker();
				if (!selected) {
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=no_file");
					return;
				}
				try {
					var fs:FileStream = new FileStream();
					fs.open(selected, FileMode.READ);
					var raw:String = fs.readUTFBytes(fs.bytesAvailable);
					fs.close();
					var savedata:* = JSON.parse(raw);
					var validation:String = OfflineSave.validatePortableSave(savedata);
					if (validation.indexOf("PASS:") != 0) {
						Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=validation;result=" + validation + ";name=" + selected.name);
						return;
					}
					var normalized:String = JSON.stringify(savedata);
					var internalFile:File = File.applicationStorageDirectory.resolvePath("savefile.txt");
					var backupFile:File = File.applicationStorageDirectory.resolvePath("savefile.before-import.txt");
					if (internalFile.exists) internalFile.copyTo(backupFile, true);
					var tempFile:File = File.applicationStorageDirectory.resolvePath("savefile.import.tmp");
					var out:FileStream = new FileStream();
					out.open(tempFile, FileMode.WRITE);
					out.writeUTFBytes(normalized);
					out.close();
					tempFile.moveTo(internalFile, true);
					Utils.DiagEvent("SAVE_IMPORT_COMMIT", "validation=" + validation + ";bytes=" + normalized.length + ";name=" + selected.name + ";backup=" + backupFile.name);
					loadProgress(savedata);
				} catch (error:Error) {
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=exception;type=" + error.name + ";message=" + error.message);
				}
			}
'@.TrimEnd()
  $pause=Replace-LiteralOne $pause $oldHandler $newHandler 'mobile_picker_handler_lifetime'

  foreach($token in @(
    'private var mExternalSaveFile: File;',
    'addEventListener(Event.SELECT, this.onExternalSaveSelected, false, 0, false)',
    'addEventListener(Event.CANCEL, this.onExternalSaveCancelled, false, 0, false)',
    'releaseExternalSavePicker',
    'SAVE_IMPORT_SELECTED',
    'SAVE_IMPORT_CANCELLED',
    'SAVE_IMPORT_COMMIT',
    'SAVE_IMPORT_REJECTED'
  )){Require-Token $pause $token 'mobile_picker_lifetime_contract'}
  if($pause.Contains('var mobileFile:File = new File();')){throw 'ANDROID_EVIDENCE_ROOTFIX_V23=FAIL local_picker_reference_survived'}
  if($pause.Contains('onExternalSaveSelected, false, 0, true')){throw 'ANDROID_EVIDENCE_ROOTFIX_V23=FAIL weak_select_listener_survived'}
  Write-Utf8Bom $pausePath $pause

  # Ensure the final-SWF gate proves the new callback path actually compiled.
  # Event strings are stable bytecode constants and do not depend on FFDec method
  # rendering, unlike API call spellings such as File.copyTo.
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $oldMarkers="$v21PauseMarkers=@('browseForOpen','onExternalSaveSelected')"
  $newMarkers="$v21PauseMarkers=@('browseForOpen','onExternalSaveSelected','SAVE_IMPORT_SELECTED','SAVE_IMPORT_CANCELLED')"
  $patcher=Replace-LiteralOne $patcher $oldMarkers $newMarkers 'final_swf_picker_lifetime_markers'
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V23_PICKER_LIFETIME=PASS root_cause=local_File_plus_weak_listener strong_member=true select_listener_weak=false cancel_cleanup=true selected_telemetry=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V23=PASS mode=apply predecessor=v22 sha=$ExpectedSha"
}
catch {
  $failure=$_
  try{Restore-OwnedFiles}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V23_RESTORE_OWNED_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  try{& $v22 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V23_PREDECESSOR_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
