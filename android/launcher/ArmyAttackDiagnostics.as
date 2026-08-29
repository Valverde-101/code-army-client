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
    import flash.system.Capabilities;
    import flash.text.TextField;
    import flash.text.TextFormat;

    public final class ArmyAttackDiagnostics {
        private var owner:Sprite;
        private var context:ExtensionContext;
        private var events:Array = [];
        private var currentProfile:String = "base";
        private var currentName:String = "Army Attack 23.2";
        private var currentPath:String = "";
        private var testedSha:String = "unknown";
        private var lastError:String = "";

        public function ArmyAttackDiagnostics(owner:Sprite) {
            this.owner = owner;
            try {
                context = ExtensionContext.createExtensionContext("com.valverde.armyattack.diagnostics", "");
                record("DIAGNOSTICS_EXTENSION", context ? "READY" : "UNAVAILABLE");
            } catch (err:Error) {
                context = null;
                record("DIAGNOSTICS_EXTENSION_ERROR", formatError(err));
            }
            record("DIAGNOSTICS_INIT", "capabilities=" + Capabilities.version);
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
            record("SHARE_REQUEST", "profile=" + currentProfile);
            if (!context) {
                capture("SHARE_ERROR", "extension_unavailable");
                return;
            }
            try {
                var result:Object = context.call("shareZip", payload(), "ArmyAttack-" + currentProfile);
                record("SHARE_RESULT", String(result));
            } catch (err:Error) {
                capture("SHARE_EXCEPTION", formatError(err));
            }
        }

        private function payload():String {
            var screen:String = "no-stage";
            if (owner && owner.stage) screen = owner.stage.stageWidth + "x" + owner.stage.stageHeight;
            return JSON.stringify({
                schema_version:1,
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
                events:events
            }, null, 2);
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
