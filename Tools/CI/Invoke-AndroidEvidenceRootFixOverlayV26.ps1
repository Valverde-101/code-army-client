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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v25=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV25.ps1'
if(-not(Test-Path -LiteralPath $v25 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL predecessor_missing=$v25"}

$pausePath=Join-Path $RepoRoot 'src\game\gui\PauseDialog.as'
$patcherPath=Join-Path $RepoRoot 'Tools\CI\Patch-AndroidPerformanceSwf.ps1'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v26\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V26_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL restore_backup_missing path=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    $actualHash=Get-Sha256 $target
    $expectedHash=([string]$entry.sha256).ToUpperInvariant()
    if($actualHash -ne $expectedHash){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL restore_hash path=$($entry.path) expected=$expectedHash actual=$actualHash"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v25 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V26=PASS mode=restore predecessor=v25 sha=$ExpectedSha"
  return
}

& $v25 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL predecessor_apply_exit=$LASTEXITCODE"}

try {
  foreach($path in @($pausePath,$patcherPath)){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V26=FAIL required_file_missing path=$path"}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $files=@()
  foreach($spec in @(
    [ordered]@{path='src\game\gui\PauseDialog.as';backup='PauseDialog.post-v25.as'},
    [ordered]@{path='Tools\CI\Patch-AndroidPerformanceSwf.ps1';backup='Patch-AndroidPerformanceSwf.post-v25.ps1'}
  )){
    $target=Join-Path $RepoRoot ([string]$spec.path)
    $backup=Join-Path $backupRoot ([string]$spec.backup)
    Copy-Item -LiteralPath $target -Destination $backup -Force
    $files+=@([ordered]@{path=[string]$spec.path;backup=[string]$spec.backup;sha256=(Get-Sha256 $target)})
  }
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v26';source_sha=$ExpectedSha;predecessor='v25';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # Manual device evidence from fe9eff on Android 15 proves two distinct runtime
  # defects: browseForOpen throws Error #3800 before storage permission is primed,
  # and after SELECT the synchronous FileStream.open path never reaches either
  # COMMIT or REJECTED. Gate the picker on blank-File requestPermission (the SAF
  # compatible AIR path) and load the selected document asynchronously through the
  # inherited FileReference.load API so content-backed documents never block the
  # AIR main thread.
  $pause=Normalize-Lf ([IO.File]::ReadAllText($pausePath))

  $oldPicker=@'
			CONFIG::BUILD_FOR_MOBILE_AIR {
				var pickerHost:MovieClip = this.mButtonLoad ? this.mButtonLoad.getMovieClip() : null;
				if (!pickerHost) {
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=picker_host_missing");
					return;
				}
				var previousPicker:* = pickerHost["armyExternalSaveFile"];
				if (previousPicker is File) {
					File(previousPicker).removeEventListener(Event.SELECT, this.onExternalSaveSelected);
				}
				var mobileFile:File = new File();
				pickerHost["armyExternalSaveFile"] = mobileFile;
				mobileFile.addEventListener(Event.SELECT, this.onExternalSaveSelected, false, 0, false);
				try {
					mobileFile.browseForOpen("Importar partida Army Attack");
					Utils.DiagEvent("SAVE_IMPORT_PICKER_OPEN", "source=android_document_picker;lifetime=movieclip_host");
				} catch (error:Error) {
					mobileFile.removeEventListener(Event.SELECT, this.onExternalSaveSelected);
					pickerHost["armyExternalSaveFile"] = null;
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=picker_exception;type=" + error.name + ";message=" + error.message);
				}
			}
'@.TrimEnd()

  $newPicker=@'
			CONFIG::BUILD_FOR_MOBILE_AIR {
				var pickerHost:MovieClip = this.mButtonLoad ? this.mButtonLoad.getMovieClip() : null;
				if (!pickerHost) {
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=picker_host_missing");
					return;
				}
				var previousPicker:* = pickerHost["armyExternalSaveFile"];
				if (previousPicker is File) {
					File(previousPicker).removeEventListener(Event.SELECT, this.onExternalSaveSelected);
				}
				var previousPermissionFile:* = pickerHost["armyExternalPermissionFile"];
				var previousPermissionHandler:* = pickerHost["armyExternalPermissionHandler"];
				if (previousPermissionFile is File && previousPermissionHandler is Function) {
					File(previousPermissionFile).removeEventListener("permissionStatus", previousPermissionHandler as Function);
				}
				pickerHost["armyExternalSaveFile"] = null;
				pickerHost["armyExternalPermissionFile"] = null;
				pickerHost["armyExternalPermissionHandler"] = null;

				var permissionFile:File = new File();
				var permissionHandler:Function = null;
				permissionHandler = function(permissionEvent:*):void {
					permissionFile.removeEventListener("permissionStatus", permissionHandler);
					pickerHost["armyExternalPermissionFile"] = null;
					pickerHost["armyExternalPermissionHandler"] = null;
					var permissionStatus:String = permissionEvent && permissionEvent.status != null ? String(permissionEvent.status).toLowerCase() : "unknown";
					Utils.DiagEvent("SAVE_IMPORT_PERMISSION_STATUS", "status=" + permissionStatus);
					if (permissionStatus != "granted") {
						Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=permission_denied;status=" + permissionStatus);
						return;
					}

					var mobileFile:File = new File();
					pickerHost["armyExternalSaveFile"] = mobileFile;
					mobileFile.addEventListener(Event.SELECT, this.onExternalSaveSelected, false, 0, false);
					try {
						mobileFile.browseForOpen("Importar partida Army Attack");
						Utils.DiagEvent("SAVE_IMPORT_PICKER_OPEN", "source=android_document_picker;lifetime=movieclip_host;permission=granted");
					} catch (error:Error) {
						mobileFile.removeEventListener(Event.SELECT, this.onExternalSaveSelected);
						pickerHost["armyExternalSaveFile"] = null;
						Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=picker_exception_after_permission;type=" + error.name + ";message=" + error.message);
					}
				};

				pickerHost["armyExternalPermissionFile"] = permissionFile;
				pickerHost["armyExternalPermissionHandler"] = permissionHandler;
				permissionFile.addEventListener("permissionStatus", permissionHandler, false, 0, false);
				try {
					Utils.DiagEvent("SAVE_IMPORT_PERMISSION_REQUEST", "source=blank_file_before_picker");
					permissionFile.requestPermission();
				} catch (error:Error) {
					permissionFile.removeEventListener("permissionStatus", permissionHandler);
					pickerHost["armyExternalPermissionFile"] = null;
					pickerHost["armyExternalPermissionHandler"] = null;
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=permission_exception;type=" + error.name + ";message=" + error.message);
				}
			}
'@.TrimEnd()
  $pause=Replace-LiteralOne $pause $oldPicker $newPicker 'mobile_picker_permission_gate'

  $oldHandler=@'
			private function onExternalSaveSelected(evt:Event):void {
				var selected:File = evt && evt.target is File ? evt.target as File : null;
				var pickerHost:MovieClip = this.mButtonLoad ? this.mButtonLoad.getMovieClip() : null;
				if (selected) selected.removeEventListener(Event.SELECT, this.onExternalSaveSelected);
				if (pickerHost) pickerHost["armyExternalSaveFile"] = null;
				Utils.DiagEvent("SAVE_IMPORT_SELECTED", "source=android_document_picker;name=" + (selected ? selected.name : "null"));
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

  $newHandler=@'
			private function onExternalSaveSelected(evt:Event):void {
				var selected:File = evt && evt.target is File ? evt.target as File : null;
				var pickerHost:MovieClip = this.mButtonLoad ? this.mButtonLoad.getMovieClip() : null;
				if (selected) selected.removeEventListener(Event.SELECT, this.onExternalSaveSelected);
				if (pickerHost) {
					pickerHost["armyExternalSaveFile"] = null;
					pickerHost["armyExternalReadFile"] = selected;
				}
				Utils.DiagEvent("SAVE_IMPORT_SELECTED", "source=android_document_picker;name=" + (selected ? selected.name : "null"));
				if (!selected) {
					if (pickerHost) pickerHost["armyExternalReadFile"] = null;
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=no_file");
					return;
				}

				var loadComplete:Function = null;
				var loadIoError:Function = null;
				var loadSecurityError:Function = null;
				var cleanupLoad:Function = null;
				cleanupLoad = function():void {
					selected.removeEventListener(Event.COMPLETE, loadComplete);
					selected.removeEventListener(IOErrorEvent.IO_ERROR, loadIoError);
					selected.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, loadSecurityError);
					if (pickerHost) pickerHost["armyExternalReadFile"] = null;
				};
				loadIoError = function(ioEvent:*):void {
					var message:String = ioEvent && ioEvent.text != null ? String(ioEvent.text) : "unknown";
					cleanupLoad();
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=read_io_error;message=" + message + ";name=" + selected.name);
				};
				loadSecurityError = function(securityEvent:*):void {
					var message:String = securityEvent && securityEvent.text != null ? String(securityEvent.text) : "unknown";
					cleanupLoad();
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=read_security_error;message=" + message + ";name=" + selected.name);
				};
				loadComplete = function(loadEvent:Event):void {
					try {
						var payload:* = selected.data;
						if (!payload) throw new Error("selected_data_missing");
						payload.position = 0;
						var raw:String = payload.readUTFBytes(payload.length);
						Utils.DiagEvent("SAVE_IMPORT_READ_COMPLETE", "bytes=" + raw.length + ";name=" + selected.name);
						var savedata:* = JSON.parse(raw);
						var validation:String = OfflineSave.validatePortableSave(savedata);
						if (validation.indexOf("PASS:") != 0) {
							cleanupLoad();
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
						cleanupLoad();
						Utils.DiagEvent("SAVE_IMPORT_COMMIT", "validation=" + validation + ";bytes=" + normalized.length + ";name=" + selected.name + ";backup=" + backupFile.name);
						loadProgress(savedata);
					} catch (error:Error) {
						cleanupLoad();
						Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=read_or_commit_exception;type=" + error.name + ";message=" + error.message + ";name=" + selected.name);
					}
				};

				selected.addEventListener(Event.COMPLETE, loadComplete, false, 0, false);
				selected.addEventListener(IOErrorEvent.IO_ERROR, loadIoError, false, 0, false);
				selected.addEventListener(SecurityErrorEvent.SECURITY_ERROR, loadSecurityError, false, 0, false);
				try {
					Utils.DiagEvent("SAVE_IMPORT_READ_BEGIN", "source=filereference_load;name=" + selected.name);
					selected.load();
				} catch (error:Error) {
					cleanupLoad();
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=load_exception;type=" + error.name + ";message=" + error.message + ";name=" + selected.name);
				}
			}
'@.TrimEnd()
  $pause=Replace-LiteralOne $pause $oldHandler $newHandler 'mobile_selected_file_async_load'

  foreach($token in @(
    'permissionFile.requestPermission();',
    'SAVE_IMPORT_PERMISSION_REQUEST',
    'SAVE_IMPORT_PERMISSION_STATUS',
    'permissionStatus != "granted"',
    'selected.load();',
    'SAVE_IMPORT_READ_BEGIN',
    'SAVE_IMPORT_READ_COMPLETE',
    'SAVE_IMPORT_SELECTED',
    'SAVE_IMPORT_COMMIT',
    'SAVE_IMPORT_REJECTED',
    'OfflineSave.validatePortableSave(savedata)',
    'savefile.before-import.txt',
    'savefile.import.tmp',
    'tempFile.moveTo(internalFile, true);',
    'loadProgress(savedata);'
  )){Require-Token $pause $token 'mobile_picker_permission_async_contract'}
  if($pause.Contains('fs.open(selected, FileMode.READ);')){throw 'ANDROID_EVIDENCE_ROOTFIX_V26=FAIL synchronous_external_filestream_survived'}
  if($pause.Contains('mobileFile.browseForOpen("Importar partida Army Attack");') -and -not $pause.Contains('permissionStatus != "granted"')){throw 'ANDROID_EVIDENCE_ROOTFIX_V26=FAIL picker_not_permission_gated'}
  Write-Utf8Bom $pausePath $pause

  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $oldMarkers='$v21PauseMarkers=@(''browseForOpen'',''onExternalSaveSelected'',''SAVE_IMPORT_SELECTED'')'
  $newMarkers='$v21PauseMarkers=@(''browseForOpen'',''onExternalSaveSelected'',''SAVE_IMPORT_PERMISSION_STATUS'',''SAVE_IMPORT_SELECTED'',''SAVE_IMPORT_READ_COMPLETE'')'
  $patcher=Replace-LiteralOne $patcher $oldMarkers $newMarkers 'final_swf_permission_async_load_markers'
  Write-Utf8Bom $patcherPath $patcher

  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V26_IMPORT_RUNTIME=PASS root_cause=missing_permission_gate_plus_sync_saf_read permission_gate=blank_file_requestPermission external_read=FileReference.load_async main_thread_blocking=false ffdec_class_shape=unchanged'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V26=PASS mode=apply predecessor=v25 sha=$ExpectedSha"
}
catch {
  $failure=$_
  try{Restore-OwnedFiles}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V26_RESTORE_OWNED_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  try{& $v25 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_EVIDENCE_ROOTFIX_V26_PREDECESSOR_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
