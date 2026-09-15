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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$v26=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV26.ps1'
if(-not(Test-Path -LiteralPath $v26 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL predecessor_missing=$v26"}

$pausePath=Join-Path $RepoRoot 'src\game\gui\PauseDialog.as'
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v27\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V27_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Restore-OwnedFiles {
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  foreach($entry in @($manifest.files)){
    $target=Join-Path $RepoRoot ([string]$entry.path)
    $backup=Join-Path $backupRoot ([string]$entry.backup)
    if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL restore_backup_missing path=$($entry.path)"}
    Copy-Item -LiteralPath $backup -Destination $target -Force
    $actualHash=Get-Sha256 $target
    $expectedHash=([string]$entry.sha256).ToUpperInvariant()
    if($actualHash -ne $expectedHash){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL restore_hash path=$($entry.path) expected=$expectedHash actual=$actualHash"}
  }
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

if($Mode -eq 'Restore'){
  Restore-OwnedFiles
  & $v26 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V27=PASS mode=restore predecessor=v26 sha=$ExpectedSha"
  return
}

& $v26 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL predecessor_apply_exit=$LASTEXITCODE"}

try {
  if(-not(Test-Path -LiteralPath $pausePath -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V27=FAIL required_file_missing path=$pausePath"}
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  $backup=Join-Path $backupRoot 'PauseDialog.post-v26.as'
  Copy-Item -LiteralPath $pausePath -Destination $backup -Force
  $files=@([ordered]@{path='src\game\gui\PauseDialog.as';backup='PauseDialog.post-v26.as';sha256=(Get-Sha256 $pausePath)})
  [ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v27';source_sha=$ExpectedSha;predecessor='v26';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

  # Device evidence from cf22d6e6 on Android 15 showed repeated
  # SAVE_IMPORT_PERMISSION_REQUEST/STATUS(granted) pairs and zero PICKER_OPEN.
  # Keep browseForOpen on the original Load-button user stack when permission is
  # already granted. If permission must be requested, cache the granted result;
  # if File.permissionStatus updates before requestPermission returns we can still
  # open on the same user stack, otherwise the next Load tap takes the direct path.
  $pause=Normalize-Lf ([IO.File]::ReadAllText($pausePath))

  $permissionInsertionNeedle=@'
				pickerHost["armyExternalPermissionFile"] = null;
				pickerHost["armyExternalPermissionHandler"] = null;

				var permissionFile:File = new File();
'@.TrimEnd()

  $permissionInsertionReplacement=@'
				pickerHost["armyExternalPermissionFile"] = null;
				pickerHost["armyExternalPermissionHandler"] = null;

				var permissionSnapshot:String = File.permissionStatus != null ? String(File.permissionStatus).toLowerCase() : "unknown";
				var permissionCached:Boolean = pickerHost["armyExternalPermissionReady"] === true;
				Utils.DiagEvent("SAVE_IMPORT_PERMISSION_SNAPSHOT", "status=" + permissionSnapshot + ";cached=" + permissionCached);
				if (permissionSnapshot == "granted" || permissionCached) {
					try {
						var directFile:File = new File();
						pickerHost["armyExternalSaveFile"] = directFile;
						directFile.addEventListener(Event.SELECT, this.onExternalSaveSelected, false, 0, false);
						Utils.DiagEvent("SAVE_IMPORT_PICKER_FASTPATH", "phase=before_browse;status=" + permissionSnapshot + ";cached=" + permissionCached);
						directFile.browseForOpen("Importar partida Army Attack");
						Utils.DiagEvent("SAVE_IMPORT_PICKER_OPEN", "source=android_document_picker;permission=pregranted;user_stack=true");
					} catch (directError:Error) {
						var failedDirect:* = pickerHost["armyExternalSaveFile"];
						if (failedDirect is File) File(failedDirect).removeEventListener(Event.SELECT, this.onExternalSaveSelected);
						pickerHost["armyExternalSaveFile"] = null;
						Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=picker_fastpath_exception;type=" + directError.name + ";message=" + directError.message + ";status=" + permissionSnapshot);
					}
					return;
				}

				var permissionFile:File = new File();
'@.TrimEnd()
  $pause=Replace-LiteralOne $pause $permissionInsertionNeedle $permissionInsertionReplacement 'permission_pregranted_user_stack_fastpath'

  $callbackOpenNeedle=@'
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
'@.TrimEnd()

  $callbackOpenReplacement=@'
					pickerHost["armyExternalPermissionReady"] = true;
					Utils.DiagEvent("SAVE_IMPORT_PERMISSION_READY", "status=granted;picker=deferred_to_user_stack");
					return;
'@.TrimEnd()
  $pause=Replace-LiteralOne $pause $callbackOpenNeedle $callbackOpenReplacement 'permission_callback_does_not_launch_picker'

  $requestNeedle=@'
				try {
					Utils.DiagEvent("SAVE_IMPORT_PERMISSION_REQUEST", "source=blank_file_before_picker");
					permissionFile.requestPermission();
				} catch (error:Error) {
					permissionFile.removeEventListener("permissionStatus", permissionHandler);
					pickerHost["armyExternalPermissionFile"] = null;
					pickerHost["armyExternalPermissionHandler"] = null;
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=permission_exception;type=" + error.name + ";message=" + error.message);
				}
'@.TrimEnd()

  $requestReplacement=@'
				try {
					Utils.DiagEvent("SAVE_IMPORT_PERMISSION_REQUEST", "source=blank_file_before_picker");
					permissionFile.requestPermission();
					var permissionAfterRequest:String = File.permissionStatus != null ? String(File.permissionStatus).toLowerCase() : "unknown";
					Utils.DiagEvent("SAVE_IMPORT_PERMISSION_POST_REQUEST", "status=" + permissionAfterRequest);
					if (permissionAfterRequest == "granted") {
						permissionFile.removeEventListener("permissionStatus", permissionHandler);
						pickerHost["armyExternalPermissionFile"] = null;
						pickerHost["armyExternalPermissionHandler"] = null;
						pickerHost["armyExternalPermissionReady"] = true;
						try {
							var postPermissionFile:File = new File();
							pickerHost["armyExternalSaveFile"] = postPermissionFile;
							postPermissionFile.addEventListener(Event.SELECT, this.onExternalSaveSelected, false, 0, false);
							Utils.DiagEvent("SAVE_IMPORT_PICKER_FASTPATH", "phase=post_request;status=granted");
							postPermissionFile.browseForOpen("Importar partida Army Attack");
							Utils.DiagEvent("SAVE_IMPORT_PICKER_OPEN", "source=android_document_picker;permission=post_request;user_stack=true");
						} catch (postRequestError:Error) {
							var failedPost:* = pickerHost["armyExternalSaveFile"];
							if (failedPost is File) File(failedPost).removeEventListener(Event.SELECT, this.onExternalSaveSelected);
							pickerHost["armyExternalSaveFile"] = null;
							Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=picker_post_permission_exception;type=" + postRequestError.name + ";message=" + postRequestError.message);
						}
					}
				} catch (error:Error) {
					permissionFile.removeEventListener("permissionStatus", permissionHandler);
					pickerHost["armyExternalPermissionFile"] = null;
					pickerHost["armyExternalPermissionHandler"] = null;
					Utils.DiagEvent("SAVE_IMPORT_REJECTED", "reason=permission_exception;type=" + error.name + ";message=" + error.message);
				}
'@.TrimEnd()
  $pause=Replace-LiteralOne $pause $requestNeedle $requestReplacement 'permission_post_request_user_stack_fastpath'

  Require-Token $pause 'File.permissionStatus' 'static_permission_snapshot'
  Require-Token $pause 'SAVE_IMPORT_PERMISSION_SNAPSHOT' 'permission_snapshot_telemetry'
  Require-Token $pause 'SAVE_IMPORT_PICKER_FASTPATH' 'picker_fastpath_telemetry'
  Require-Token $pause 'SAVE_IMPORT_PERMISSION_READY' 'permission_ready_cache'
  Require-Token $pause 'SAVE_IMPORT_READ_COMPLETE' 'async_selected_read_preserved'
  Require-Token $pause 'SAVE_IMPORT_COMMIT' 'import_commit_preserved'
  Require-Token $pause 'loadProgress(savedata);' 'load_progress_preserved'

  if($pause.Contains('lifetime=movieclip_host;permission=granted')){
    throw 'ANDROID_EVIDENCE_ROOTFIX_V27=FAIL permission_callback_picker_launch_survived'
  }

  Write-Utf8Bom $pausePath $pause
  Write-Host 'ANDROID_EVIDENCE_ROOTFIX_V27_IMPORT_RUNTIME=PASS root_cause=permission_callback_picker_launch_noop permission_check=File.permissionStatus browse=user_click_stack async_read=v26 preserved=true'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V27=PASS mode=apply predecessor=v26 sha=$ExpectedSha"
}
catch {
  try { Restore-OwnedFiles } catch {}
  try { & $v26 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore | Out-Null } catch {}
  throw
}
