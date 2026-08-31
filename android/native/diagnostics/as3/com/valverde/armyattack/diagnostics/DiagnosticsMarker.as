package com.valverde.armyattack.diagnostics {
    import flash.external.ExtensionContext;

    public final class DiagnosticsMarker {
        private static const EXTENSION_ID:String = "com.valverde.armyattack.diagnostics";
        private static var context:ExtensionContext;
        private static var unavailable:Boolean = false;

        public function DiagnosticsMarker() {}

        private static function getContext():ExtensionContext {
            if (context) return context;
            if (unavailable) return null;
            try {
                context = ExtensionContext.createExtensionContext(EXTENSION_ID, null);
                if (!context) unavailable = true;
            } catch (error:Error) {
                unavailable = true;
                context = null;
            }
            return context;
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