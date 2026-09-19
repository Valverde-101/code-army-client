package com.valverde.armyattack.diagnostics {
    import flash.events.StatusEvent;
    import flash.external.ExtensionContext;
    import flash.system.Capabilities;
    import flash.utils.getDefinitionByName;

    public final class DiagnosticsMarker {
        private static const EXTENSION_ID:String = "com.valverde.armyattack.diagnostics";
        private static const TEST_EVENT_CODE:String = "TEST_COMMAND";
        private static var context:ExtensionContext;
        private static var unavailable:Boolean = false;
        private static var listenerInstalled:Boolean = false;

        public function DiagnosticsMarker() {}

        private static function getContext():ExtensionContext {
            if (context) return context;
            if (unavailable) return null;
            try {
                context = ExtensionContext.createExtensionContext(EXTENSION_ID, null);
                if (!context) {
                    unavailable = true;
                    return null;
                }
                if (!listenerInstalled) {
                    context.addEventListener(StatusEvent.STATUS, onNativeStatus, false, 0, true);
                    listenerInstalled = true;
                }
                try {
                    var consoleState:Object = context.call("enableTestConsole");
                    context.call("logEvent", "TEST_CONSOLE_AS3_READY", "native=" + String(consoleState));
                } catch (consoleError:Error) {
                    context.call("logEvent", "TEST_COMMAND_FAIL", "reason=enable_console;type=" + consoleError.name);
                }
            } catch (error:Error) {
                unavailable = true;
                context = null;
            }
            return context;
        }

        private static function onNativeStatus(event:StatusEvent):void {
            if (!event || event.code != TEST_EVENT_CODE) return;
            var payload:String = event.level == null ? "" : event.level;
            var separator:int = payload.indexOf("\t");
            var command:String = separator >= 0 ? payload.substring(0, separator) : payload;
            var arg:String = separator >= 0 ? payload.substring(separator + 1) : "";
            command = command == null ? "" : command.toLowerCase();
            try {
                nativeLog("TEST_COMMAND_RX_AS3", "command=" + safeLogValue(command) + ";arg=" + safeLogValue(arg));
                var detail:String = executeTestCommand(command, arg);
                nativeLog("TEST_COMMAND_RESULT", "command=" + safeLogValue(command) + ";result=" + safeLogValue(detail));
            } catch (error:Error) {
                nativeLog("TEST_COMMAND_FAIL", "command=" + safeLogValue(command) + ";reason=as3_exception;type=" + safeLogValue(error.name) + ";message=" + safeLogValue(error.message));
            }
        }

        private static function executeTestCommand(command:String, arg:String):String {
            var gameState:Object = resolveGameState();
            if (command == "status") return describeState(gameState);
            if (command == "version") return "runtime=" + Capabilities.version + ";" + describeState(gameState);
            if (command == "health") {
                if (!gameState) return "FAIL:game_state_unavailable";
                var initialized:Boolean = Boolean(readField(gameState, "mInitialized"));
                var loadingOver:Boolean = Boolean(readField(gameState, "mLoadingStatesOver"));
                var mapId:String = String(readField(gameState, "mCurrentMapId"));
                return initialized && loadingOver && mapId.length > 0
                    ? "READY:map=" + mapId + ";state=" + String(readField(gameState, "mState"))
                    : "FAIL:initialized=" + initialized + ";loading_over=" + loadingOver + ";map=" + mapId;
            }
            if (!gameState) throw new Error("game_state_unavailable");

            if (command == "open_map") {
                if (arg != "Home" && arg != "Desert" && arg != "Snow") throw new Error("invalid_map");
                invokeNoReturn(gameState, "requestWorldMapSwitch", [arg]);
                return "ACCEPTED:map=" + arg;
            }
            if (command == "open_pvp") {
                invokeNoReturn(gameState, "openPvPMatchUpDialog", []);
                return "ACCEPTED:pvp_matchup";
            }
            if (command == "pvp_start") {
                invokeNoReturn(gameState, "startPvP", []);
                return "ACCEPTED:pvp_start";
            }
            if (command == "pvp_pass") {
                var match:Object = readField(gameState, "mPvPMatch");
                if (!match) throw new Error("pvp_match_unavailable");
                invokeNoReturn(match, "passPlayerTurn", []);
                return "ACCEPTED:pvp_pass";
            }
            if (command == "pvp_end") {
                invokeNoReturn(gameState, "endPvP", []);
                return "ACCEPTED:pvp_end";
            }
            throw new Error("unsupported_command");
        }

        private static function resolveGameState():Object {
            try {
                var gameStateClass:Object = getDefinitionByName("game.states.GameState");
                if (!gameStateClass) return null;
                return gameStateClass["mInstance"];
            } catch (error:Error) {
                return null;
            }
        }

        private static function describeState(gameState:Object):String {
            if (!gameState) return "WAITING:game_state_unavailable";
            return "READY:initialized=" + Boolean(readField(gameState, "mInitialized"))
                + ";loading_over=" + Boolean(readField(gameState, "mLoadingStatesOver"))
                + ";map=" + String(readField(gameState, "mCurrentMapId"))
                + ";state=" + String(readField(gameState, "mState"))
                + ";pvp=" + (readField(gameState, "mPvPMatch") != null);
        }

        private static function readField(target:Object, field:String):Object {
            if (!target) return null;
            try { return target[field]; }
            catch (error:Error) { return null; }
        }

        private static function invokeNoReturn(target:Object, method:String, args:Array):void {
            if (!target) throw new Error("target_unavailable:" + method);
            var fn:Function;
            try { fn = target[method] as Function; }
            catch (lookupError:Error) { fn = null; }
            if (fn == null) throw new Error("method_unavailable:" + method);
            fn.apply(target, args == null ? [] : args);
        }

        private static function safeLogValue(value:String):String {
            if (value == null) return "";
            var result:String = value.replace(/;/g, "_").replace(/=/g, "_").replace(/[\r\n\t]/g, " ");
            return result.length > 160 ? result.substr(0, 160) : result;
        }

        private static function nativeLog(kind:String, detail:String):void {
            var nativeContext:ExtensionContext = context;
            if (!nativeContext) return;
            try {
                nativeContext.call("logEvent", kind == null ? "UNKNOWN" : kind, detail == null ? "" : detail);
            } catch (error:Error) {
            }
        }

        public static function log(kind:String, detail:String = ""):void {
            var nativeContext:ExtensionContext = getContext();
            if (!nativeContext) return;
            try {
                nativeContext.call("logEvent", kind == null ? "UNKNOWN" : kind, detail == null ? "" : detail);
            } catch (error:Error) {
            }
        }
    }
}
