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
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL exact_head expected=$ExpectedSha actual=$actual"}
$v20=Join-Path $PSScriptRoot 'Invoke-AndroidEvidenceRootFixOverlayV20.ps1'
if(-not(Test-Path -LiteralPath $v20 -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL predecessor_missing=$v20"}

$targets=[ordered]@{
  offline='src\game\utils\OfflineSave.as'
  hud='src\game\gui\GameHUD.as'
  pause='src\game\gui\PauseDialog.as'
  diagmarker='android\native\diagnostics\as3\com\valverde\armyattack\diagnostics\DiagnosticsMarker.as'
  diagext='android\native\diagnostics\java\com\valverde\armyattack\diagnostics\DiagnosticsExtension.java'
  diagprovider='android\native\diagnostics\java\com\valverde\armyattack\diagnostics\DiagnosticsProvider.java'
  perfjava='android\native\diagnostics\java\com\valverde\armyattack\diagnostics\PerformanceOverlay.java'
  patcher='Tools\CI\Patch-AndroidPerformanceSwf.ps1'
  test='Tools\CI\Test-AndroidRuntimePatch.ps1'
}
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-evidence-rootfix-v21\'+$ExpectedSha)
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Write-Utf8NoBom([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false)))}
function Target-Path([string]$Key){Join-Path $RepoRoot ([string]$targets[$Key])}
function Backup-Path([string]$Key){Join-Path $backupRoot ($Key+'.post-v20')}
function Require-Token([string]$Text,[string]$Token,[string]$Name){if(-not $Text.Contains($Token)){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL verify=$Name token=$Token"}}
function Replace-LiteralOne([string]$Text,[string]$Needle,[string]$Replacement,[string]$Name){
  $first=$Text.IndexOf($Needle,[StringComparison]::Ordinal)
  if($first -lt 0){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL patch=$Name literal_missing"}
  $second=$Text.IndexOf($Needle,$first+$Needle.Length,[StringComparison]::Ordinal)
  if($second -ge 0){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL patch=$Name literal_ambiguous"}
  Write-Host "EVIDENCE_ROOTFIX_V21_HOOK=PASS name=$Name matches=1"
  return $Text.Substring(0,$first)+$Replacement+$Text.Substring($first+$Needle.Length)
}
function Replace-RegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){
  $rx=New-Object System.Text.RegularExpressions.Regex($Pattern)
  $matches=$rx.Matches($Text)
  if($matches.Count -ne 1){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL patch=$Name expected_matches=1 actual=$($matches.Count)"}
  Write-Host "EVIDENCE_ROOTFIX_V21_HOOK=PASS name=$Name matches=1 semantic=true"
  return $rx.Replace($Text,$Replacement,1)
}

if($Mode -eq 'Restore'){
  if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
    foreach($entry in @($manifest.files)){
      $key=[string]$entry.key
      $backup=Backup-Path $key
      $target=Target-Path $key
      if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL restore_backup_missing key=$key"}
      Copy-Item -LiteralPath $backup -Destination $target -Force
      $restored=Get-Sha256 $target
      $expected=([string]$entry.sha256).ToUpperInvariant()
      if($restored -ne $expected){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL restore_hash key=$key expected=$expected actual=$restored"}
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
  & $v20 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore
  if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL predecessor_restore_exit=$LASTEXITCODE"}
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V21=PASS mode=restore baseline_restored=true predecessor=v20 sha=$ExpectedSha"
  return
}

& $v20 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Apply
if($LASTEXITCODE -ne 0){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL predecessor_apply_exit=$LASTEXITCODE"}

foreach($key in $targets.Keys){
  $path=Target-Path $key
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "ANDROID_EVIDENCE_ROOTFIX_V21=FAIL required_file_missing key=$key path=$path"}
}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
$manifestFiles=@()
foreach($key in $targets.Keys){
  $src=Target-Path $key
  Copy-Item -LiteralPath $src -Destination (Backup-Path $key) -Force
  $manifestFiles+=@([ordered]@{key=$key;path=[string]$targets[$key];sha256=(Get-Sha256 $src)})
}
[ordered]@{schema='armyattack-android-evidence-rootfix-overlay/v21';source_sha=$ExpectedSha;predecessor='v20';files=$manifestFiles}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try {
  # Portable save root-fix. Keep the canonical internal autosave, but make manual
  # Save export/share a complete campaign snapshot and make Pause->Load import an
  # external JSON save through Android's document picker. PvP transient maps stay
  # excluded; unvisited campaign maps remain authored/config-driven on first visit.
  $offlinePath=Target-Path 'offline'
  $offline=Normalize-Lf ([IO.File]::ReadAllText($offlinePath))
  $offline=Replace-LiteralOne $offline 'public class OfflineSave {' @'
public class OfflineSave {

		private static const CURRENT_SAVE_VERSION:int = 10;
		private static const SAVE_SCHEMA:String = "armyattack-offline-save/v10";
'@.TrimEnd() 'save_schema_v10'

  $dedupePattern='(?ms)if \(known_objects\.indexOf\(String\(gameobj\["coord_x"\]\) \+ String\(gameobj\["coord_y"\]\)\) == -1\) \{\s*known_objects\.push\(String\(gameobj\["coord_x"\]\) \+ String\(gameobj\["coord_y"\]\)\);\s*gamefield_items\.push\(gameobj\);\s*\}'
  $dedupeReplacement=@'
var objectKey:String = String(gameobj["coord_x"]) + ":" + String(gameobj["coord_y"]);
						if (known_objects.indexOf(objectKey) == -1) {
							known_objects.push(objectKey);
							gamefield_items.push(gameobj);
						}
'@
  $offline=Replace-RegexOne $offline $dedupePattern $dedupeReplacement.TrimEnd() 'structure_coordinate_dedupe_collision_fix'

  $saveVersionNeedle='savedata["saveversion"] = 10;'
  $saveVersionReplacement=@'
savedata["saveversion"] = CURRENT_SAVE_VERSION;
			savedata["save_manifest"] = buildSaveManifest(savedata);
'@
  $offline=Replace-LiteralOne $offline $saveVersionNeedle $saveVersionReplacement.TrimEnd() 'save_version_manifest'

  $helpers=@'
		private static function buildSaveManifest(savedata:*):* {
			var persisted:Array = [];
			var unvisited:Array = [];
			var coverage:Array = [];
			var maps:Array = savedata && savedata["maps"] is Array ? savedata["maps"] as Array : [];
			var mapEntry:* = null;
			var mapData:* = null;
			var mapId:String = null;
			var i:int = 0;
			while (i < maps.length) {
				mapEntry = maps[i];
				if (mapEntry) {
					mapId = String(mapEntry["map_name"]);
					mapData = mapEntry["map_data"];
					if (mapId && persisted.indexOf(mapId) < 0) persisted.push(mapId);
					coverage.push({
						"map_id": mapId,
						"player_tiles": mapData && mapData["player_tiles"] is Array ? mapData["player_tiles"].length : 0,
						"gamefield_items": mapData && mapData["gamefield_items"] is Array ? mapData["gamefield_items"].length : 0
					});
				}
				i++;
			}
			i = 0;
			while (i < GameState.GRAPHICS_MAP_ID_LIST.length) {
				mapId = String(GameState.GRAPHICS_MAP_ID_LIST[i]);
				if (persisted.indexOf(mapId) < 0) unvisited.push(mapId);
				i++;
			}
			var inventory:* = savedata && savedata["profile"] ? savedata["profile"]["inventory_items"] : null;
			return {
				"schema": SAVE_SCHEMA,
				"version": CURRENT_SAVE_VERSION,
				"portable": true,
				"persisted_map_ids": persisted,
				"unvisited_map_ids": unvisited,
				"map_coverage": coverage,
				"inventory_entries": inventory is Array ? inventory.length : 0,
				"generated_at_ms": new Date().valueOf()
			};
		}

		public static function validatePortableSave(savedata:*):String {
			if (!savedata) return "FAIL:missing_root";
			var version:int = int(savedata["saveversion"]);
			if (version <= 0 || version > CURRENT_SAVE_VERSION) return "FAIL:unsupported_version=" + version;
			if (!savedata["profile"]) return "FAIL:missing_profile";
			var inventory:* = savedata["profile"]["inventory_items"];
			if (inventory != null && !(inventory is Array)) return "FAIL:inventory_not_array";
			var mapCount:int = 0;
			var itemCount:int = 0;
			if (version >= 4) {
				if (!(savedata["maps"] is Array)) return "FAIL:maps_not_array";
				var seen:Object = {};
				var maps:Array = savedata["maps"] as Array;
				var i:int = 0;
				while (i < maps.length) {
					var mapEntry:* = maps[i];
					if (!mapEntry) return "FAIL:null_map_entry=" + i;
					var mapId:String = String(mapEntry["map_name"]);
					if (!mapId || mapId.indexOf("pvp_") == 0 || GameState.GRAPHICS_MAP_ID_LIST.indexOf(mapId) < 0) return "FAIL:invalid_map=" + mapId;
					if (seen[mapId]) return "FAIL:duplicate_map=" + mapId;
					seen[mapId] = true;
					var mapData:* = mapEntry["map_data"];
					if (!mapData) return "FAIL:missing_map_data=" + mapId;
					if (!(mapData["player_tiles"] is Array)) return "FAIL:player_tiles_not_array=" + mapId;
					if (!(mapData["gamefield_items"] is Array)) return "FAIL:gamefield_items_not_array=" + mapId;
					if (mapData["map_id"] != null && String(mapData["map_id"]) != mapId) return "FAIL:map_id_mismatch=" + mapId;
					mapCount++;
					itemCount += mapData["gamefield_items"].length;
					i++;
				}
			}
			return "PASS:version=" + version + ";maps=" + mapCount + ";gamefield_items=" + itemCount + ";inventory=" + (inventory is Array ? inventory.length : 0);
		}

		public static function fixOldSave(savedata: * , version: int): * {
'@
  $offline=Replace-LiteralOne $offline 'public static function fixOldSave(savedata: * , version: int): * {' $helpers.TrimEnd() 'portable_save_helpers'

  $migrationNeedle='if (version < 7) savedata["offline_pvp_booster_seed_cleanup_pending"] = true;'
  $migrationReplacement=@'
if (version < 7) savedata["offline_pvp_booster_seed_cleanup_pending"] = true;
			if (version < CURRENT_SAVE_VERSION) {
				savedata["saveversion"] = CURRENT_SAVE_VERSION;
				savedata["save_manifest"] = buildSaveManifest(savedata);
			}
'@
  $offline=Replace-LiteralOne $offline $migrationNeedle $migrationReplacement.TrimEnd() 'save_v10_manifest_migration'
  foreach($token in @('CURRENT_SAVE_VERSION:int = 10','armyattack-offline-save/v10','validatePortableSave','save_manifest','objectKey','persisted_map_ids','unvisited_map_ids')){Require-Token $offline $token 'portable_save_model'}
  Write-Utf8Bom $offlinePath $offline

  # Manual Save on Android persists the exact validated snapshot internally first,
  # then shares the same bytes through the existing secure ANE/provider authority.
  $hudPath=Target-Path 'hud'
  $hud=Normalize-Lf ([IO.File]::ReadAllText($hudPath))
  if(-not $hud.Contains('import flash.utils.getDefinitionByName;')){
    $hud=Replace-LiteralOne $hud 'import flash.utils.ByteArray;' "import flash.utils.ByteArray;`n`timport flash.utils.getDefinitionByName;" 'hud_getdefinition_import'
  }
  $hudHelper=@'
		CONFIG::BUILD_FOR_MOBILE_AIR {
			private function savePortableAndShare():void {
				try {
					var savedata:* = generateSaveJson();
					var validation:String = OfflineSave.validatePortableSave(savedata);
					if (validation.indexOf("PASS:") != 0) {
						Utils.DiagEvent("SAVE_EXPORT_FAIL", "stage=validate;result=" + validation);
						return;
					}
					var payload:String = JSON.stringify(savedata);
					var internalFile:File = File.applicationStorageDirectory.resolvePath("savefile.txt");
					var stream:FileStream = new FileStream();
					stream.open(internalFile, FileMode.WRITE);
					stream.writeUTFBytes(payload);
					stream.close();
					var diagnosticsClass:Class = getDefinitionByName("com.valverde.armyattack.diagnostics.DiagnosticsMarker") as Class;
					if (!diagnosticsClass) throw new Error("diagnostics_marker_unavailable");
					var shareFn:Function = diagnosticsClass["shareSave"] as Function;
					if (shareFn == null) throw new Error("shareSave_unavailable");
					var shareResult:String = String(shareFn(payload, "ArmyAttack-save"));
					Utils.DiagEvent("SAVE_EXPORT_SHARE", "validation=" + validation + ";bytes=" + payload.length + ";result=" + shareResult);
				} catch (error:Error) {
					Utils.DiagEvent("SAVE_EXPORT_FAIL", "stage=share;type=" + error.name + ";message=" + error.message);
				}
			}
		}

		public function generateSaveJson(): * {
'@
  $hud=Replace-LiteralOne $hud 'public function generateSaveJson(): * {' $hudHelper.TrimEnd() 'manual_save_share_helper'

  $buttonPattern='(?ms)(public function buttonSavePressed\(param1:\s*MouseEvent\):\s*void\s*\{.*?CONFIG::NOT_BUILD_FOR_AIR\s*\{.*?^\s*\})(\s*CONFIG::BUILD_FOR_MOBILE_AIR\s*\{.*?^\s*\})(\s*^\s*\}\s*\n\s*CONFIG::BUILD_FOR_MOBILE_AIR\s*\{\s*public function autoSaveGame)'
  $buttonReplacement=@'
$1
			CONFIG::BUILD_FOR_MOBILE_AIR {
				this.savePortableAndShare();
			}
$3
'@
  $hud=Replace-RegexOne $hud $buttonPattern $buttonReplacement.TrimEnd() 'manual_save_routes_to_share'
  foreach($token in @('savePortableAndShare','SAVE_EXPORT_SHARE','SAVE_EXPORT_FAIL','DiagnosticsMarker','shareSave','File.applicationStorageDirectory.resolvePath("savefile.txt")')){Require-Token $hud $token 'manual_save_share_contract'}
  Write-Utf8Bom $hudPath $hud

  # Enable Pause->Load on mobile and use the platform document picker. Validate
  # before mutating state, then persist the imported JSON as the new default save.
  $pausePath=Target-Path 'pause'
  $pause=Normalize-Lf ([IO.File]::ReadAllText($pausePath))
  $pause=Replace-LiteralOne $pause @'
				CONFIG::BUILD_FOR_MOBILE_AIR {
					this.mButtonLoad.setVisible(false);
				}
'@.TrimEnd() @'
				CONFIG::BUILD_FOR_MOBILE_AIR {
					this.mButtonLoad.setVisible(true);
				}
'@.TrimEnd() 'mobile_load_button_enabled'

  $pickerPattern='(?ms)(public function startSelectingFile\(\):\s*void\s*\{.*?CONFIG::NOT_BUILD_FOR_AIR\s*\{.*?^\s*\})(\s*CONFIG::BUILD_FOR_MOBILE_AIR\s*\{.*?^\s*\})(\s*^\s*\})'
  $pickerReplacement=@'
$1
			CONFIG::BUILD_FOR_MOBILE_AIR {
				var mobileFile:File = new File();
				mobileFile.addEventListener(Event.SELECT, this.onExternalSaveSelected, false, 0, true);
				mobileFile.browseForOpen("Importar partida Army Attack");
				Utils.DiagEvent("SAVE_IMPORT_PICKER_OPEN", "source=android_document_picker");
			}
$3
'@
  $pause=Replace-RegexOne $pause $pickerPattern $pickerReplacement.TrimEnd() 'mobile_external_save_picker'

  $importHelper=@'
		CONFIG::BUILD_FOR_MOBILE_AIR {
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
		}

		CONFIG::BUILD_FOR_AIR {
'@
  $pause=Replace-LiteralOne $pause 'CONFIG::BUILD_FOR_AIR {' $importHelper.TrimEnd() 'external_import_validate_persist'
  foreach($token in @('this.mButtonLoad.setVisible(true);','browseForOpen("Importar partida Army Attack")','onExternalSaveSelected','validatePortableSave','SAVE_IMPORT_COMMIT','SAVE_IMPORT_REJECTED','savefile.before-import.txt','savefile.import.tmp')){Require-Token $pause $token 'external_import_contract'}
  Write-Utf8Bom $pausePath $pause

  # ANE ActionScript bridge for portable save sharing.
  $markerPath=Target-Path 'diagmarker'
  $marker=Normalize-Lf ([IO.File]::ReadAllText($markerPath))
  $markerMethod=@'
        public static function shareSave(payload:String, requestedName:String = "ArmyAttack-save"):String {
            var nativeContext:ExtensionContext = getContext();
            if (!nativeContext) return "ERROR:native_context_unavailable";
            try {
                return String(nativeContext.call("shareSave", payload == null ? "{}" : payload, requestedName == null ? "ArmyAttack-save" : requestedName));
            } catch (error:Error) {
                nativeLog("SAVE_SHARE_FAIL", "type=" + safeLogValue(error.name) + ";message=" + safeLogValue(error.message));
                return "ERROR:" + error.name;
            }
        }

        public static function log(kind:String, detail:String = ""):void {
'@
  $marker=Replace-LiteralOne $marker 'public static function log(kind:String, detail:String = ""):void {' $markerMethod.TrimEnd() 'diagnostics_share_save_bridge'
  Require-Token $marker 'nativeContext.call("shareSave"' 'diagnostics_share_save_bridge'
  Write-Utf8NoBom $markerPath $marker

  # Native sharesheet writes exact UTF-8 JSON bytes to a provider-backed cache file.
  $extPath=Target-Path 'diagext'
  $ext=Normalize-Lf ([IO.File]::ReadAllText($extPath))
  $ext=Replace-LiteralOne $ext 'functions.put("shareZip", new ShareZipFunction());' @'
functions.put("shareZip", new ShareZipFunction());
            functions.put("shareSave", new ShareSaveFunction());
'@.TrimEnd() 'native_share_save_registration'
  $shareSaveClass=@'
    private static final class ShareSaveFunction implements FREFunction {
        @Override
        public FREObject call(final FREContext context, FREObject[] args) {
            try {
                final String payload = args != null && args.length > 0 && args[0] != null ? args[0].getAsString() : "{}";
                final String requestedName = args != null && args.length > 1 && args[1] != null ? args[1].getAsString() : "ArmyAttack-save";
                final Activity activity = context.getActivity();
                if (activity == null) return FREObject.newObject("ERROR:no_activity");
                final File dir = new File(activity.getCacheDir(), "armyattack-diagnostics");
                if (!dir.exists() && !dir.mkdirs()) return FREObject.newObject("ERROR:mkdir_failed");
                String safeBase = requestedName == null ? "ArmyAttack-save" : requestedName.trim().replaceAll("[^A-Za-z0-9._-]+", "-");
                if (safeBase.length() == 0) safeBase = "ArmyAttack-save";
                if (safeBase.length() > 80) safeBase = safeBase.substring(0, 80);
                SimpleDateFormat stamp = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US);
                stamp.setTimeZone(TimeZone.getTimeZone("UTC"));
                final File saveFile = new File(dir, safeBase + "-" + stamp.format(new Date()) + ".json");
                FileOutputStream output = new FileOutputStream(saveFile);
                try { output.write(payload.getBytes(StandardCharsets.UTF_8)); }
                finally { output.close(); }

                final Uri uri = Uri.parse("content://" + activity.getPackageName() + ".armyattackdiagnostics/" + Uri.encode(saveFile.getName()));
                final Intent send = new Intent(Intent.ACTION_SEND);
                send.setType("application/json");
                send.putExtra(Intent.EXTRA_STREAM, uri);
                send.putExtra(Intent.EXTRA_SUBJECT, "Partida Army Attack");
                send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                send.setClipData(ClipData.newRawUri("Army Attack save", uri));
                final Runnable openChooser = new Runnable() {
                    @Override public void run() {
                        activity.startActivity(Intent.createChooser(send, "Compartir partida Army Attack"));
                    }
                };
                if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) openChooser.run();
                else activity.runOnUiThread(openChooser);
                PerformanceOverlay.recordGameEvent("SAVE_SHARE_NATIVE", "bytes=" + payload.getBytes(StandardCharsets.UTF_8).length + ";file=" + saveFile.getName());
                return FREObject.newObject("QUEUED:" + uri.toString());
            } catch (Throwable t) {
                PerformanceOverlay.recordGameEvent("SAVE_SHARE_FAIL", "type=" + t.getClass().getSimpleName());
                try { return FREObject.newObject("ERROR:" + t.getClass().getSimpleName()); }
                catch (Throwable ignored) { return null; }
            }
        }
    }

    private static final class ShareZipFunction implements FREFunction {
'@
  $ext=Replace-LiteralOne $ext 'private static final class ShareZipFunction implements FREFunction {' $shareSaveClass.TrimEnd() 'native_share_save_function'
  foreach($token in @('functions.put("shareSave"','class ShareSaveFunction','application/json','Compartir partida Army Attack','SAVE_SHARE_NATIVE')){Require-Token $ext $token 'native_share_save_contract'}
  Write-Utf8NoBom $extPath $ext

  $providerPath=Target-Path 'diagprovider'
  $provider=Normalize-Lf ([IO.File]::ReadAllText($providerPath))
  $provider=Replace-LiteralOne $provider 'return "application/zip";' @'
String name = uri == null ? "" : Uri.decode(uri.getLastPathSegment() == null ? "" : uri.getLastPathSegment());
        return name.toLowerCase().endsWith(".json") ? "application/json" : "application/zip";
'@.TrimEnd() 'provider_json_mime'
  $provider=Replace-LiteralOne $provider 'if (!name.matches("[A-Za-z0-9._-]+\\.zip")) {' 'if (!name.matches("[A-Za-z0-9._-]+\\.(zip|json)")) {' 'provider_json_extension'
  foreach($token in @('application/json','\\.(zip|json)')){Require-Token $provider $token 'provider_portable_save_contract'}
  Write-Utf8NoBom $providerPath $provider

  $perfPath=Target-Path 'perfjava'
  $perf=Normalize-Lf ([IO.File]::ReadAllText($perfPath))
  if(-not $perf.Contains('kind.startsWith("SAVE_")')){
    $perf=Replace-LiteralOne $perf '|| kind.startsWith("PLACEMENT_")' @'
|| kind.startsWith("PLACEMENT_")
            || kind.startsWith("SAVE_")
'@.TrimEnd() 'save_events_logcat_mirror'
  }
  Write-Utf8NoBom $perfPath $perf

  # Patcher must include PauseDialog, preprocess its mobile CONFIG blocks, identify
  # V21, and prove the exact final SWF contains the portable save/import code.
  $patcherPath=Target-Path 'patcher'
  $patcher=Normalize-Lf ([IO.File]::ReadAllText($patcherPath))
  $patcher=Replace-LiteralOne $patcher '$patchVersion=''mobile-engine-v3.32-movement-recovery-rootfix-v20''' '$patchVersion=''mobile-engine-v3.33-portable-save-share-v21''' 'patch_version_v21'
  $patcher=Replace-LiteralOne $patcher "  [ordered]@{Class='game.gui.GameHUD';Source='src\\game\\gui\\GameHUD.as';Log='ffdec-feature-gamehud.log'}," @'
  [ordered]@{Class='game.gui.GameHUD';Source='src\game\gui\GameHUD.as';Log='ffdec-feature-gamehud.log'},
  [ordered]@{Class='game.gui.PauseDialog';Source='src\game\gui\PauseDialog.as';Log='ffdec-feature-pause-save-import.log'},
'@.TrimEnd() 'pause_dialog_swf_patch_spec'
  $patcher=Replace-LiteralOne $patcher "if(`$spec.Class -in @('game.states.GameState','game.states.GameLoadingSecond','game.gui.GameHUD','game.gui.GiveFilePermissionDialog','game.isometric.IsometricScene')){" "if(`$spec.Class -in @('game.states.GameState','game.states.GameLoadingSecond','game.gui.GameHUD','game.gui.PauseDialog','game.gui.GiveFilePermissionDialog','game.isometric.IsometricScene')){" 'pause_dialog_mobile_preprocess'

  $verifyAnchor='Write-Host "SWF_V20_MOVEMENT_VERIFY=PASS classes=IsometricCharacter,GameState markers=$($v20CharacterMarkers.Count+$v20GameMarkers.Count) patch_version=$patchVersion patched_sha256=$outputSha log=$v20Log"'
  $verifyBlock=@'
$v21VerifyDir=Join-Path $outDir 'v21-final-save-verify'
if(Test-Path -LiteralPath $v21VerifyDir){Remove-Item -LiteralPath $v21VerifyDir -Recurse -Force}
New-Item -ItemType Directory -Force -Path $v21VerifyDir|Out-Null
$v21ClassNames='game.utils.OfflineSave,game.gui.GameHUD,game.gui.PauseDialog'
$v21Args=@('-cli','-selectclass',$v21ClassNames,'-export','script',$v21VerifyDir,$OutputSwf)
$v21Log=Join-Path $logRoot 'ffdec-v21-final-save-verify.log'
$v21OldPreference=$ErrorActionPreference
try {
  $ErrorActionPreference='Continue'
  if($java){$v21Lines=@(& $java.Source '-jar' $ffdec.FullName @v21Args 2>&1|ForEach-Object{$_.ToString()})}
  else{$v21Lines=@(& $ffdec.FullName @v21Args 2>&1|ForEach-Object{$_.ToString()})}
  $v21Exit=$LASTEXITCODE
} finally {$ErrorActionPreference=$v21OldPreference}
$v21Lines|Set-Content -LiteralPath $v21Log -Encoding UTF8
if($v21Exit -ne 0){throw "SWF_V21_SAVE_VERIFY=FAIL operation=export_final_classes exit=$v21Exit log=$v21Log"}
$v21Offline=@(Get-ChildItem -LiteralPath $v21VerifyDir -Recurse -File -Filter 'OfflineSave.as' -ErrorAction SilentlyContinue)
$v21Hud=@(Get-ChildItem -LiteralPath $v21VerifyDir -Recurse -File -Filter 'GameHUD.as' -ErrorAction SilentlyContinue)
$v21Pause=@(Get-ChildItem -LiteralPath $v21VerifyDir -Recurse -File -Filter 'PauseDialog.as' -ErrorAction SilentlyContinue)
if($v21Offline.Count -ne 1 -or $v21Hud.Count -ne 1 -or $v21Pause.Count -ne 1){throw "SWF_V21_SAVE_VERIFY=FAIL exported offline=$($v21Offline.Count) hud=$($v21Hud.Count) pause=$($v21Pause.Count)"}
$v21OfflineText=[IO.File]::ReadAllText($v21Offline[0].FullName)
$v21HudText=[IO.File]::ReadAllText($v21Hud[0].FullName)
$v21PauseText=[IO.File]::ReadAllText($v21Pause[0].FullName)
$v21OfflineMarkers=@('armyattack-offline-save/v10','validatePortableSave','save_manifest','objectKey','persisted_map_ids','unvisited_map_ids')
$v21HudMarkers=@('savePortableAndShare','SAVE_EXPORT_SHARE','shareSave')
$v21PauseMarkers=@('SAVE_IMPORT_COMMIT','SAVE_IMPORT_REJECTED','browseForOpen','onExternalSaveSelected','validatePortableSave')
foreach($marker in $v21OfflineMarkers){if($v21OfflineText -notmatch [regex]::Escape($marker)){throw "SWF_V21_SAVE_VERIFY=FAIL class=OfflineSave marker=$marker"}}
foreach($marker in $v21HudMarkers){if($v21HudText -notmatch [regex]::Escape($marker)){throw "SWF_V21_SAVE_VERIFY=FAIL class=GameHUD marker=$marker"}}
foreach($marker in $v21PauseMarkers){if($v21PauseText -notmatch [regex]::Escape($marker)){throw "SWF_V21_SAVE_VERIFY=FAIL class=PauseDialog marker=$marker"}}
Write-Host "SWF_V21_SAVE_VERIFY=PASS classes=OfflineSave,GameHUD,PauseDialog markers=$($v21OfflineMarkers.Count+$v21HudMarkers.Count+$v21PauseMarkers.Count) patch_version=$patchVersion patched_sha256=$outputSha log=$v21Log"
'@
  $patcher=Replace-LiteralOne $patcher $verifyAnchor ($verifyAnchor+"`n"+$verifyBlock.TrimEnd()) 'final_swf_portable_save_gate'
  Write-Utf8Bom $patcherPath $patcher

  # Static regression contract runs against the post-overlay sources before SWF patching.
  $testPath=Target-Path 'test'
  $test=Normalize-Lf ([IO.File]::ReadAllText($testPath))
  $test=Replace-LiteralOne $test '$gameHud=Read-Source ''src\game\gui\GameHUD.as''' @'
$gameHud=Read-Source 'src\game\gui\GameHUD.as'
$pauseDialog=Read-Source 'src\game\gui\PauseDialog.as'
$diagProvider=Read-Source 'android\native\diagnostics\java\com\valverde\armyattack\diagnostics\DiagnosticsProvider.java'
'@.TrimEnd() 'runtime_test_save_sources'
  $test=Replace-LiteralOne $test "Require-Contains `$swfPatch 'mobile-engine-v3.32-movement-recovery-rootfix-v20' 'swf_patch_version_is_v20'" "Require-Contains `$swfPatch 'mobile-engine-v3.33-portable-save-share-v21' 'swf_patch_version_is_v21'" 'runtime_test_patch_version_v21'
  $test=Replace-LiteralOne $test "Require-Contains `$offline 'savedata[`"saveversion`"] = 10;' 'offline_save_schema_current_v10'" "Require-Contains `$offline 'CURRENT_SAVE_VERSION:int = 10' 'offline_save_schema_current_v10'" 'runtime_test_offline_save_version_v10'
  $test=Replace-LiteralOne $test "Require-Contains `$offline 'savedata[`"saveversion`"] = 10;' 'daily_reward_save_migration_version_bumped'" "Require-Contains `$offline 'savedata[`"saveversion`"] = CURRENT_SAVE_VERSION;' 'daily_reward_save_migration_version_bumped'" 'runtime_test_daily_reward_saveversion_current'
  $saveAssertions=@'
Require-Contains $offline 'CURRENT_SAVE_VERSION:int = 10' 'portable_save_version_v10'
Require-Contains $offline 'armyattack-offline-save/v10' 'portable_save_schema_v10'
Require-Contains $offline 'String(gameobj["coord_x"]) + ":" + String(gameobj["coord_y"])' 'structure_save_coordinate_key_is_unambiguous'
Require-NotContains $offline 'known_objects.push(String(gameobj["coord_x"]) + String(gameobj["coord_y"]))' 'ambiguous_structure_dedupe_removed'
Require-Contains $offline 'validatePortableSave' 'portable_save_has_preimport_validation'
Require-Contains $offline 'savedata["save_manifest"] = buildSaveManifest(savedata);' 'portable_save_manifest_generated'
Require-Contains $offline 'persisted_map_ids' 'portable_save_reports_persisted_maps'
Require-Contains $offline 'unvisited_map_ids' 'portable_save_reports_unvisited_maps_without_faking_empty_state'
Require-Contains $gameHud 'savePortableAndShare' 'manual_save_exports_portable_snapshot'
Require-Contains $gameHud 'SAVE_EXPORT_SHARE' 'manual_save_export_is_observable'
Require-Contains $gameHud 'File.applicationStorageDirectory.resolvePath("savefile.txt")' 'manual_save_persists_internal_before_share'
Require-Contains $pauseDialog 'this.mButtonLoad.setVisible(true);' 'android_external_load_button_enabled'
Require-NotContains $pauseDialog 'this.mButtonLoad.setVisible(false);' 'android_external_load_button_no_longer_hidden'
Require-Contains $pauseDialog 'browseForOpen("Importar partida Army Attack")' 'android_external_load_uses_document_picker'
Require-Contains $pauseDialog 'OfflineSave.validatePortableSave(savedata)' 'external_save_validated_before_load'
Require-Contains $pauseDialog 'savefile.before-import.txt' 'external_import_preserves_previous_internal_backup'
Require-Contains $pauseDialog 'SAVE_IMPORT_COMMIT' 'external_import_commit_is_observable'
Require-Contains $diagMarker 'shareSave' 'diagnostics_as3_exposes_save_share'
Require-Contains $diagExtension 'functions.put("shareSave", new ShareSaveFunction());' 'diagnostics_native_registers_save_share'
Require-Contains $diagExtension 'send.setType("application/json")' 'save_share_uses_json_mime'
Require-Contains $diagProvider 'application/json' 'diagnostics_provider_serves_json'
Require-Contains $diagProvider '\.(zip|json)' 'diagnostics_provider_allows_json_and_zip_only'
Require-Contains $swfPatch "Class='game.gui.PauseDialog'" 'swf_patch_includes_pause_dialog'
Require-Contains $swfPatch "'game.gui.PauseDialog'" 'swf_patch_mobile_preprocess_includes_pause_dialog'
Require-Contains $swfPatch 'SWF_V21_SAVE_VERIFY=PASS' 'swf_patch_verifies_final_portable_save_classes'
$autoSaveScope=[regex]::Match($gameHud,'(?ms)public function autoSaveGame\(param1:\s*TimerEvent\).*?(?=CONFIG::BUILD_FOR_AIR|protected function startSaveTimer)')
if(-not $autoSaveScope.Success){throw 'REGRESSION=FAIL check=autosave_scope_not_found'}
if($autoSaveScope.Value.Contains('shareSave') -or $autoSaveScope.Value.Contains('savePortableAndShare')){throw 'REGRESSION=FAIL check=autosave_must_not_open_sharesheet'}
Write-Host 'REGRESSION_CHECK=PASS name=autosave_remains_internal_only sharesheet=false interval_ms=60000'
Write-Host 'REGRESSION_CHECK=PASS name=portable_save_complete_campaign_contract maps=persisted_stable inventory=true structures=true units=true missions=true profile=true pvp_transient=false'
'@
  $test=Replace-LiteralOne $test '$audit=Join-Path $RepoRoot ''Tools\CI\Audit-SwfCore.ps1''' ($saveAssertions.TrimEnd()+"`n`n"+'$audit=Join-Path $RepoRoot ''Tools\CI\Audit-SwfCore.ps1''') 'runtime_test_portable_save_contract'
  Write-Utf8Bom $testPath $test

  foreach($key in $targets.Keys){Require-Token (Normalize-Lf ([IO.File]::ReadAllText((Target-Path $key)))) '' ('target_loaded_'+$key)}
  Write-Host 'REGRESSION_CHECK=PASS name=portable_save_structure_dedupe coordinate_key=x:y collision_1_23_vs_12_3=false'
  Write-Host 'REGRESSION_CHECK=PASS name=portable_save_export_share internal_first=true exact_json_share=true provider=read_only'
  Write-Host 'REGRESSION_CHECK=PASS name=portable_save_external_import picker=document validation=before_mutation internal_backup=true'
  Write-Host 'REGRESSION_CHECK=PASS name=portable_save_map_scope stable_campaign_maps=true pvp_transient=false unvisited_maps=authored_on_first_visit'
  Write-Host "ANDROID_EVIDENCE_ROOTFIX_V21=PASS mode=apply sha=$ExpectedSha predecessor=v20 swf_patch_version=mobile-engine-v3.33-portable-save-share-v21 portable_save=true external_import=true share=true"
}
catch {
  $failure=$_
  foreach($key in $targets.Keys){
    $backup=Backup-Path $key
    $target=Target-Path $key
    if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force}
  }
  if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
  try{& $v20 -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{}
  throw $failure
}
