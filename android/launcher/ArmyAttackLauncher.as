package {
    import flash.desktop.NativeApplication;
    import flash.display.Loader;
    import flash.display.Shape;
    import flash.display.Sprite;
    import flash.display.StageAlign;
    import flash.display.StageScaleMode;
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.events.KeyboardEvent;
    import flash.events.MouseEvent;
    import flash.events.ProgressEvent;
    import flash.events.SecurityErrorEvent;
    import flash.events.UncaughtErrorEvent;
    import flash.filesystem.File;
    import flash.net.URLLoader;
    import flash.net.URLRequest;
    import flash.system.ApplicationDomain;
    import flash.system.LoaderContext;
    import flash.text.TextField;
    import flash.text.TextFormat;
    import flash.ui.Keyboard;

    [SWF(width="1280", height="720", frameRate="60", backgroundColor="#0B1018")]
    public class ArmyAttackLauncher extends Sprite {
        private var manifest:Object;
        private var profiles:Object = {};
        private var selectedRuntime:String = "base";
        private var hardMode:Boolean = false;
        private var swapped:Boolean = false;
        private var swapped2:Boolean = false;
        private var runtimeCards:Object = {};
        private var layerCards:Object = {};
        private var statusText:TextField;
        private var profileText:TextField;
        private var playButton:Sprite;
        private var diagnostics:ArmyAttackDiagnostics;
        private var loader:Loader;
        private var menu:Sprite = new Sprite();

        public function ArmyAttackLauncher() {
            if (stage) init(); else addEventListener(Event.ADDED_TO_STAGE, init);
        }

        private function init(e:Event = null):void {
            removeEventListener(Event.ADDED_TO_STAGE, init);
            stage.scaleMode = StageScaleMode.NO_SCALE;
            stage.align = StageAlign.TOP_LEFT;
            stage.addEventListener(Event.RESIZE, onResize);
            stage.addEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);
            diagnostics = new ArmyAttackDiagnostics(this);
            loadManifest();
        }

        private function loadManifest():void {
            var u:URLLoader = new URLLoader();
            u.addEventListener(Event.COMPLETE, function(e:Event):void {
                try {
                    manifest = JSON.parse(String(u.data));
                    diagnostics.setManifest(manifest);
                    var list:Array = manifest.profiles as Array;
                    for each (var p:Object in list) profiles[String(p.id)] = p;
                    renderMenu();
                } catch (err:Error) {
                    renderFatal("No se pudo leer profiles.json: " + err.message);
                }
            });
            u.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void {
                renderFatal("No se pudo cargar profiles/profiles.json");
            });
            u.load(new URLRequest("profiles/profiles.json"));
        }

        private function renderMenu():void {
            while (numChildren) removeChildAt(0);
            menu = new Sprite();
            addChild(menu);

            var bg:Shape = new Shape();
            bg.graphics.beginFill(0x0B1018);
            bg.graphics.drawRect(0, 0, 1280, 720);
            bg.graphics.endFill();
            menu.addChild(bg);

            var accent:Shape = new Shape();
            accent.graphics.beginFill(0xD3A52B);
            accent.graphics.drawRect(0, 0, 1280, 7);
            accent.graphics.endFill();
            menu.addChild(accent);

            menu.addChild(makeText("ARMY ATTACK", 46, true, 0xF2F5F7, 50, 28, 560, 58));
            menu.addChild(makeText("Android • v23.2 • Selector de versiones y mods", 20, false, 0xAEB7C2, 53, 86, 650, 32));

            menu.addChild(makeText("VERSIÓN / RUNTIME", 18, true, 0xD3A52B, 55, 136, 430, 28));
            addRuntimeCard("base", "Army Attack 23.2", "Versión moderna publicada • recomendada", 55, 172);
            addRuntimeCard("classic", "Classic Mods", "Runtime compartido • permite combinar capas", 55, 267);
            addRuntimeCard("colossal", "Colossal Island", "Experimental • áreas, edificios y enemigos nuevos", 55, 362);
            addRuntimeCard("crimson", "Crimson", "Mod completo con runtime propio", 55, 457);
            addRuntimeCard("truecrimson", "True Crimson", "Mod completo con runtime propio", 55, 552);

            menu.addChild(makeText("CAPAS COMPATIBLES", 18, true, 0xD3A52B, 675, 136, 500, 28));
            menu.addChild(makeText("Disponibles solo con Classic Mods", 15, false, 0x89939E, 675, 164, 480, 24));
            addLayerCard("hardmode", "Hard Mode", "Ajustes de dificultad y balance", 675, 205);
            addLayerCard("swapped", "Swapped", "Intercambia apariencias jugador/enemigo", 675, 300);
            addLayerCard("swapped2", "Swapped 2", "Variante visual alternativa", 675, 395);

            profileText = makeText("", 17, true, 0xE6EBEF, 675, 500, 540, 56);
            menu.addChild(profileText);
            statusText = makeText("", 15, false, 0x9EABB7, 675, 554, 540, 45);
            menu.addChild(statusText);
            diagnostics.setStatusField(statusText);

            playButton = makeButton("JUGAR", 675, 610, 245, 58, 0xB88A17, 0xF8FAFC, onPlay);
            menu.addChild(playButton);
            menu.addChild(diagnostics.makeShareButton(940, 610, 245, 58));
            refresh();
            onResize();
        }

        private function addRuntimeCard(id:String, title:String, desc:String, x:Number, y:Number):void {
            var self:ArmyAttackLauncher = this;
            var s:Sprite = makeCard(title, desc, x, y, 560, 78, function(e:MouseEvent):void {
                self.selectedRuntime = id;
                if (id != "classic") {
                    self.hardMode = false;
                    self.swapped = false;
                    self.swapped2 = false;
                }
                self.refresh();
            });
            runtimeCards[id] = s;
            menu.addChild(s);
        }

        private function addLayerCard(id:String, title:String, desc:String, x:Number, y:Number):void {
            var self:ArmyAttackLauncher = this;
            var s:Sprite = makeCard(title, desc, x, y, 510, 78, function(e:MouseEvent):void {
                if (self.selectedRuntime != "classic") return;
                if (id == "hardmode") self.hardMode = !self.hardMode;
                if (id == "swapped") {
                    self.swapped = !self.swapped;
                    if (self.swapped) self.swapped2 = false;
                }
                if (id == "swapped2") {
                    self.swapped2 = !self.swapped2;
                    if (self.swapped2) self.swapped = false;
                }
                self.refresh();
            });
            layerCards[id] = s;
            menu.addChild(s);
        }

        private function makeCard(title:String, desc:String, x:Number, y:Number, w:Number, h:Number, handler:Function):Sprite {
            var s:Sprite = new Sprite();
            s.x = x; s.y = y;
            drawCard(s, w, h, false, false);
            s.addChild(makeText(title, 21, true, 0xF0F3F5, 18, 11, w - 36, 28));
            s.addChild(makeText(desc, 14, false, 0xA6B0BA, 18, 42, w - 36, 22));
            s.mouseChildren = false;
            s.buttonMode = true;
            s.addEventListener(MouseEvent.CLICK, handler);
            return s;
        }

        private function drawCard(s:Sprite, w:Number, h:Number, selected:Boolean, disabled:Boolean):void {
            s.graphics.clear();
            s.graphics.beginFill(disabled ? 0x141A21 : (selected ? 0x253240 : 0x18212B));
            s.graphics.lineStyle(selected ? 3 : 1, disabled ? 0x2B343D : (selected ? 0xD3A52B : 0x35424F));
            s.graphics.drawRoundRect(0, 0, w, h, 14, 14);
            s.graphics.endFill();
            s.alpha = disabled ? 0.42 : 1.0;
        }

        private function refresh():void {
            for (var id:String in runtimeCards) drawCard(runtimeCards[id], 560, 78, id == selectedRuntime, false);

            var classic:Boolean = selectedRuntime == "classic";
            drawCard(layerCards["hardmode"], 510, 78, hardMode, !classic);
            drawCard(layerCards["swapped"], 510, 78, swapped, !classic);
            drawCard(layerCards["swapped2"], 510, 78, swapped2, !classic);

            var profileId:String = resolveProfileId();
            var p:Object = profiles[profileId];
            var name:String = p ? String(p.name) : profileId;
            profileText.text = "Perfil: " + name;

            if (profileId == "hardmode-swapped" || profileId == "hardmode-swapped2") {
                statusText.text = "MULTI-MOD ACTIVO • Hard Mode + capa visual • conflictos gráficos resueltos a favor de Swapped";
            } else if (selectedRuntime == "classic") {
                statusText.text = "Classic usa un runtime compartido y capas verificadas.";
            } else {
                statusText.text = "Runtime completo aislado. Las capas Classic se desactivan para evitar conflictos de código.";
            }
        }

        private function resolveProfileId():String {
            if (selectedRuntime != "classic") return selectedRuntime;
            if (hardMode && swapped2) return "hardmode-swapped2";
            if (hardMode && swapped) return "hardmode-swapped";
            if (hardMode) return "hardmode";
            if (swapped2) return "swapped2";
            if (swapped) return "swapped";
            return "none";
        }

        private function onPlay(e:MouseEvent):void {
            var profileId:String = resolveProfileId();
            var p:Object = profiles[profileId];
            if (!p) {
                statusText.text = "ERROR: perfil no encontrado: " + profileId;
                return;
            }
            playButton.mouseEnabled = false;
            statusText.text = "Cargando " + String(p.name) + "...";
            diagnostics.setProfile(profileId, String(p.name), String(p.swf));
            loadGame(String(p.swf), p);
        }

        private function loadGame(path:String, p:Object):void {
            loader = new Loader();
            diagnostics.attachLoader(loader);

            // Army Attack's document class accesses stage directly from its constructor.
            // The Loader must already belong to our Stage before the child SWF is
            // instantiated; otherwise GameMain can fail immediately with stage == null.
            loader.visible = false;
            addChildAt(loader, 0);

            loader.contentLoaderInfo.addEventListener(ProgressEvent.PROGRESS, function(e:ProgressEvent):void {
                if (statusText && e.bytesTotal > 0) statusText.text = "Cargando " + String(p.name) + " • " + int(e.bytesLoaded * 100 / e.bytesTotal) + "%";
            });
            loader.contentLoaderInfo.addEventListener(Event.INIT, function(e:Event):void {
                if (statusText) statusText.text = "Inicializando " + String(p.name) + "...";
            });
            loader.contentLoaderInfo.addEventListener(Event.COMPLETE, function(e:Event):void {
                if (contains(menu)) removeChild(menu);
                loader.visible = true;
            });
            loader.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, loadFailure);
            loader.contentLoaderInfo.addEventListener(SecurityErrorEvent.SECURITY_ERROR, loadFailure);
            loader.contentLoaderInfo.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, gameUncaughtError);

            var gameFile:File = File.applicationDirectory.resolvePath(path);
            if (!gameFile.exists) {
                restoreMenuWithError("SWF NO ENCONTRADO: " + gameFile.url);
                return;
            }

            if (statusText) statusText.text = "Abriendo " + String(p.name) + " • " + gameFile.url;
            // Each runtime gets an isolated child domain. Loading every mod into the
            // launcher domain leaks definitions after unload and can make later profiles
            // reuse classes/linkages from the previously selected SWF.
            var gameDomain:ApplicationDomain = new ApplicationDomain(ApplicationDomain.currentDomain);
            var context:LoaderContext = new LoaderContext(false, gameDomain, null);
            diagnostics.record("SWF_DOMAIN", "isolated_child=true;profile=" + resolveProfileId());
            loader.load(new URLRequest(gameFile.url), context);
        }

        private function gameUncaughtError(e:UncaughtErrorEvent):void {
            e.preventDefault();
            var message:String;
            if (e.error is Error) {
                var err:Error = e.error as Error;
                message = err.name + ": " + err.message;
                if (err.getStackTrace()) message += " • " + err.getStackTrace();
            } else {
                message = String(e.error);
            }
            diagnostics.capture("GAME_UNCAUGHT", message);
            restoreMenuWithError("ERROR DEL JUEGO: " + message);
        }

        private function loadFailure(e:Event):void {
            diagnostics.capture("LOAD_FAILURE", e.toString());
            restoreMenuWithError("ERROR AL CARGAR: " + e.toString());
        }

        private function restoreMenuWithError(message:String):void {
            if (loader) {
                try {
                    loader.close();
                } catch (ignored:Error) {}
                try {
                    loader.unloadAndStop(true);
                } catch (ignored2:Error) {}
                if (contains(loader)) removeChild(loader);
                loader = null;
            }
            if (!contains(menu)) addChild(menu);
            if (statusText) statusText.text = message;
            if (playButton) playButton.mouseEnabled = true;
        }

        private function onKeyDown(e:KeyboardEvent):void {
            if (e.keyCode == Keyboard.BACK && contains(menu)) {
                e.preventDefault();
                NativeApplication.nativeApplication.exit();
            }
        }

        private function onResize(e:Event = null):void {
            if (!stage || !menu) return;
            var sx:Number = stage.stageWidth / 1280;
            var sy:Number = stage.stageHeight / 720;
            var scale:Number = Math.min(sx, sy);
            menu.scaleX = menu.scaleY = scale;
            menu.x = (stage.stageWidth - 1280 * scale) * 0.5;
            menu.y = (stage.stageHeight - 720 * scale) * 0.5;
        }

        private function makeText(value:String, size:int, bold:Boolean, color:uint, x:Number, y:Number, w:Number, h:Number):TextField {
            var t:TextField = new TextField();
            t.x = x; t.y = y; t.width = w; t.height = h;
            t.defaultTextFormat = new TextFormat("_sans", size, color, bold);
            t.text = value;
            t.selectable = false;
            t.mouseEnabled = false;
            t.multiline = true;
            t.wordWrap = true;
            return t;
        }

        private function makeButton(label:String, x:Number, y:Number, w:Number, h:Number, bg:uint, fg:uint, handler:Function):Sprite {
            var s:Sprite = new Sprite();
            s.x = x; s.y = y;
            s.graphics.beginFill(bg);
            s.graphics.drawRoundRect(0, 0, w, h, 16, 16);
            s.graphics.endFill();
            var t:TextField = makeText(label, 25, true, fg, 0, 17, w, 34);
            t.defaultTextFormat = new TextFormat("_sans", 25, fg, true, null, null, null, null, "center");
            t.text = label;
            s.addChild(t);
            s.mouseChildren = false;
            s.buttonMode = true;
            s.addEventListener(MouseEvent.CLICK, handler);
            return s;
        }

        private function renderFatal(message:String):void {
            while (numChildren) removeChildAt(0);
            var bg:Shape = new Shape();
            bg.graphics.beginFill(0x0B1018);
            bg.graphics.drawRect(0, 0, stage.stageWidth, stage.stageHeight);
            bg.graphics.endFill();
            addChild(bg);
            addChild(makeText("ARMY ATTACK", 42, true, 0xF2F5F7, 50, 50, 800, 60));
            addChild(makeText(message, 20, false, 0xFF8080, 50, 135, Math.max(500, stage.stageWidth - 100), 160));
        }
    }
}
