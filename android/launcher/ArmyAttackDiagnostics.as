package {
    import flash.display.Loader;
    import flash.display.Sprite;
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.events.MouseEvent;
    import flash.events.ProgressEvent;
    import flash.events.SecurityErrorEvent;
    import flash.events.UncaughtErrorEvent;
    import flash.external.ExtensionContext;
    import flash.filesystem.File;
    import flash.filesystem.FileMode;
    import flash.filesystem.FileStream;
    import flash.system.Capabilities;
    import flash.text.TextField;
    import flash.text.TextFormat;

    public final class ArmyAttackDiagnostics {
        private static const EXTENSION_ID:String = "com.valverde.armyattack.diagnostics";

        private var owner:Sprite;
        private var context:ExtensionContext;
        private var events:Array = [];
        private var currentProfile:String = "base";
        private var currentName:String = "Army Attack 23.2";
        private var currentPath:String = "";
        private var testedSha:String = "unknown";
        private var lastError:String = "";
        private var statusField:TextField;
        private var persistedPath:String = "";

        public function ArmyAttackDiagnostics(owner:Sprite) {
            this.owner = owner;
            record("DIAGNOSTICS_INIT", "capabilities=" + Capabilities.version + ";extension=lazy");
        }

        public function setStatusField(field:TextField):void {
            statusField = field;
        }

        public function setManifest(manifest:Object):void {
            if (manifest && manifest.tested_sha != null) testedSha = String(manifest.tested_sha);
            record("MANIFEST", "tested_sha=" + testedSha);
        }

        public function setProfile(id:String, name:String, path:String):void {
            currentProfile = id;
            currentName = name;
            currentPath = path;
            record("PROFILE_SELECTED", "id=" + id + ";name=" + name + ";path=" + path);
        }

        public function attachLoader(loader:Loader):void {
            if (!loader) return;
            loader.contentLoaderInfo.addEventListener(Event.OPEN, function(e:Event):void {
                record("SWF_OPEN", "profile=" + currentProfile);
            });
            loader.contentLoaderInfo.addEventListener(ProgressEvent.PROGRESS, function(e:ProgressEvent):void {
                if (e.bytesTotal > 0) record("SWF_PROGRESS", int(e.bytesLoaded * 100 / e.bytesTotal) + "%");
            });
            loader.contentLoaderInfo.addEventListener(Event.INIT, function(e:Event):void {
                record("SWF_INIT", "profile=" + currentProfile);
            });
            loader.contentLoaderInfo.addEventListener(Event.COMPLETE, function(e:Event):void {
                record("SWF_COMPLETE", "profile=" + currentProfile);
            });
            loader.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void {
                capture("SWF_IO_ERROR", e.toString());
            });
            loader.contentLoaderInfo.addEventListener(SecurityErrorEvent.SECURITY_ERROR, function(e:SecurityErrorEvent):void {
                capture("SWF_SECURITY_ERROR", e.toString());
            });
            loader.contentLoaderInfo.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, function(e:UncaughtErrorEvent):void {
                capture("SWF_UNCAUGHT", formatAnyError(e.error));
            });
        }

        public function capture(kind:String, detail:String):void {
            lastError = detail;
            record(kind, detail);
        }

        public function record(kind:String, detail:String = ""):void {
            events.push({utc:new Date().toUTCString(), kind:kind, detail:detail});
            while (events.length > 250) events.shift();
            trace("ARMY_DIAG " + kind + " " + detail);
            persistSnapshot();
        }

        public function makeShareButton(x:Number, y:Number, w:Number, h:Number):Sprite {
            var s:Sprite = new Sprite();
            s.x = x;
            s.y = y;
            s.graphics.beginFill(0x33475C);
            s.graphics.drawRoundRect(0, 0, w, h, 14, 14);
            s.graphics.endFill();

            var t:TextField = new TextField();
            t.width = w;
            t.height = h;
            t.y = Math.max(0, (h - 28) * 0.5);
            t.defaultTextFormat = new TextFormat("_sans", 19, 0xF8FAFC, true, null, null, null, null, "center");
            t.text = "COMPARTIR ZIP";
            t.selectable = false;
            t.mouseEnabled = false;
            s.addChild(t);

            s.mouseChildren = false;
            s.buttonMode = true;
            s.addEventListener(MouseEvent.CLICK, share);
            return s;
        }

        private function share(e:MouseEvent):void {
            showStatus("Generando diagnóstico ZIP...");
            record("SHARE_REQUEST", "profile=" + currentProfile);

            if (!ensureContext()) {
                showStatus("ERROR ZIP: extensión Android no disponible. latest.json guardado en almacenamiento interno.");
                return;
            }

            try {
                var ping:Object = context.call("ping");
                record("DIAGNOSTICS_PING", String(ping));
                if (String(ping).indexOf("READY:") != 0) {
                    capture("SHARE_ERROR", "ping_failed=" + String(ping));
                    showStatus("ERROR ZIP: ANE no está READY: " + String(ping));
                    return;
                }

                var result:Object = context.call("shareZip", payload(), "ArmyAttack-" + currentProfile);
                var resultText:String = String(result);
                record("SHARE_RESULT", resultText);
                if (resultText.indexOf("ERROR:") == 0 || resultText == "null") {
                    capture("SHARE_ERROR", resultText);
                    showStatus("ERROR AL COMPARTIR: " + resultText + " • latest.json guardado.");
                } else {
                    showStatus("ZIP LISTO • abre WhatsApp/correo/Drive en el selector de Android.");
                }
            } catch (err:Error) {
                capture("SHARE_EXCEPTION", formatError(err));
                showStatus("ERROR AL COMPARTIR: " + err.message + " • latest.json guardado.");
            }
        }

        private function ensureContext():Boolean {
            if (context) return true;
            try {
                // AIR's documented Android ANE pattern uses a null context type.
                context = ExtensionContext.createExtensionContext(EXTENSION_ID, null);
                if (!context) {
                    capture("DIAGNOSTICS_EXTENSION_ERROR", "createExtensionContext_returned_null");
                    return false;
                }
                record("DIAGNOSTICS_EXTENSION", "READY");
                return true;
            } catch (err:Error) {
                context = null;
                capture("DIAGNOSTICS_EXTENSION_ERROR", formatError(err));
                return false;
            }
        }

        private function showStatus(value:String):void {
            if (statusField) statusField.text = value;
            trace("ARMY_DIAG_STATUS " + value);
        }

        private function snapshot():Object {
            var screen:String = "no-stage";
            if (owner && owner.stage) screen = owner.stage.stageWidth + "x" + owner.stage.stageHeight;
            return {
                schema_version:2,
                generated_utc:new Date().toUTCString(),
                app:"Army Attack Android",
                game_version:"23.2",
                tested_sha:testedSha,
                selected_profile:currentProfile,
                selected_name:currentName,
                selected_path:currentPath,
                capabilities_version:Capabilities.version,
                screen:screen,
                last_error:lastError,
                persisted_path:persistedPath,
                events:events
            };
        }

        private function payload():String {
            return JSON.stringify(snapshot(), null, 2);
        }

        private function persistSnapshot():void {
            var stream:FileStream;
            try {
                var dir:File = File.applicationStorageDirectory.resolvePath("diagnostics");
                if (!dir.exists) dir.createDirectory();
                var file:File = dir.resolvePath("latest.json");
                persistedPath = file.nativePath;
                stream = new FileStream();
                stream.open(file, FileMode.WRITE);
                stream.writeUTFBytes(JSON.stringify(snapshot(), null, 2));
                stream.close();
            } catch (err:Error) {
                try { if (stream) stream.close(); } catch (ignored:Error) {}
                trace("ARMY_DIAG_PERSIST_ERROR " + err.toString());
            }
        }

        private function formatAnyError(value:Object):String {
            if (value is Error) return formatError(value as Error);
            return String(value);
        }

        private function formatError(err:Error):String {
            if (!err) return "null";
            var value:String = err.name + " #" + err.errorID + ": " + err.message;
            var stack:String = err.getStackTrace();
            if (stack) value += "\n" + stack;
            return value;
        }
    }
}
