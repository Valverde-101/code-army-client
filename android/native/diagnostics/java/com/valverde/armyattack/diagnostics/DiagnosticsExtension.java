package com.valverde.armyattack.diagnostics;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.Uri;
import android.os.Build;

import com.adobe.fre.FREContext;
import com.adobe.fre.FREExtension;
import com.adobe.fre.FREFunction;
import com.adobe.fre.FREObject;

import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public final class DiagnosticsExtension implements FREExtension {
    private static final String TEST_ACTION = "air.army.attack.TEST_COMMAND";
    private static final String TEST_PERMISSION = "android.permission.DUMP";

    @Override
    public FREContext createContext(String contextType) {
        return new DiagnosticsContext();
    }

    @Override
    public void initialize() {}

    @Override
    public void dispose() {}

    private static final class DiagnosticsContext extends FREContext {
        private BroadcastReceiver testReceiver;
        private boolean testReceiverRegistered;

        @Override
        public Map<String, FREFunction> getFunctions() {
            Map<String, FREFunction> functions = new HashMap<String, FREFunction>();
            functions.put("ping", new PingFunction());
            functions.put("shareZip", new ShareZipFunction());
            functions.put("logEvent", new LogEventFunction());
            functions.put("enableTestConsole", new EnableTestConsoleFunction());
            functions.put("disableTestConsole", new DisableTestConsoleFunction());
            return functions;
        }

        private synchronized String enableTestConsole() {
            if (testReceiverRegistered) return "READY:already_registered";
            final Activity activity = getActivity();
            if (activity == null) return "ERROR:no_activity";
            final DiagnosticsContext self = this;
            testReceiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    try {
                        if (intent == null || !TEST_ACTION.equals(intent.getAction())) return;
                        String command = normalizeCommand(intent.getStringExtra("command"));
                        String arg = sanitizeArgument(intent.getStringExtra("arg"));
                        if (!isAllowedTestCommand(command)) {
                            PerformanceOverlay.recordGameEvent("TEST_COMMAND_FAIL", "reason=not_allowed;command=" + safeLogValue(command));
                            return;
                        }
                        PerformanceOverlay.recordGameEvent("TEST_COMMAND_RX", "command=" + safeLogValue(command) + ";arg=" + safeLogValue(arg));
                        self.dispatchStatusEventAsync("TEST_COMMAND", command + "\t" + arg);
                    } catch (Throwable t) {
                        PerformanceOverlay.recordGameEvent("TEST_COMMAND_FAIL", "reason=native_exception;type=" + t.getClass().getSimpleName());
                    }
                }
            };
            IntentFilter filter = new IntentFilter(TEST_ACTION);
            if (Build.VERSION.SDK_INT >= 33) {
                activity.registerReceiver(testReceiver, filter, TEST_PERMISSION, null, Context.RECEIVER_EXPORTED);
            } else {
                activity.registerReceiver(testReceiver, filter, TEST_PERMISSION, null);
            }
            testReceiverRegistered = true;
            PerformanceOverlay.recordGameEvent("TEST_CONSOLE_READY", "action=" + TEST_ACTION + ";permission=" + TEST_PERMISSION + ";transport=dynamic_receiver");
            return "READY:" + TEST_ACTION;
        }

        private synchronized String disableTestConsole() {
            if (!testReceiverRegistered) return "READY:not_registered";
            final Activity activity = getActivity();
            try {
                if (activity != null && testReceiver != null) activity.unregisterReceiver(testReceiver);
            } catch (Throwable ignored) {
            } finally {
                testReceiver = null;
                testReceiverRegistered = false;
            }
            return "READY:disabled";
        }

        @Override
        public void dispose() {
            disableTestConsole();
        }
    }

    private static final class EnableTestConsoleFunction implements FREFunction {
        @Override
        public FREObject call(final FREContext context, FREObject[] args) {
            try {
                if (!(context instanceof DiagnosticsContext)) return FREObject.newObject("ERROR:bad_context");
                return FREObject.newObject(((DiagnosticsContext) context).enableTestConsole());
            } catch (Throwable t) {
                try { return FREObject.newObject("ERROR:" + t.getClass().getSimpleName()); }
                catch (Throwable ignored) { return null; }
            }
        }
    }

    private static final class DisableTestConsoleFunction implements FREFunction {
        @Override
        public FREObject call(final FREContext context, FREObject[] args) {
            try {
                if (!(context instanceof DiagnosticsContext)) return FREObject.newObject("ERROR:bad_context");
                return FREObject.newObject(((DiagnosticsContext) context).disableTestConsole());
            } catch (Throwable t) {
                try { return FREObject.newObject("ERROR:" + t.getClass().getSimpleName()); }
                catch (Throwable ignored) { return null; }
            }
        }
    }

    private static String normalizeCommand(String input) {
        if (input == null) return "";
        String value = input.trim().toLowerCase(Locale.US);
        if (value.length() > 48) value = value.substring(0, 48);
        return value.replaceAll("[^a-z0-9_-]", "");
    }

    private static String sanitizeArgument(String input) {
        if (input == null) return "";
        String value = input.trim();
        if (value.length() > 80) value = value.substring(0, 80);
        return value.replaceAll("[\\r\\n\\t]", " ").replaceAll("[^A-Za-z0-9_.:-]", "");
    }

    private static boolean isAllowedTestCommand(String command) {
        return "status".equals(command)
            || "health".equals(command)
            || "version".equals(command)
            || "open_map".equals(command)
            || "open_pvp".equals(command)
            || "pvp_start".equals(command)
            || "pvp_pass".equals(command)
            || "pvp_end".equals(command);
    }

    private static String safeLogValue(String input) {
        if (input == null) return "";
        return input.replace(';', '_').replace('=', '_');
    }

    private static final class PingFunction implements FREFunction {
        @Override
        public FREObject call(final FREContext context, FREObject[] args) {
            try {
                final Activity activity = context.getActivity();
                if (activity == null) return FREObject.newObject("ERROR:no_activity");
                return FREObject.newObject("READY:" + activity.getPackageName() + ":" + activity.getClass().getName());
            } catch (Throwable t) {
                try {
                    return FREObject.newObject("ERROR:" + t.getClass().getSimpleName() + ":" + String.valueOf(t.getMessage()));
                } catch (Throwable ignored) {
                    return null;
                }
            }
        }
    }

    private static final class LogEventFunction implements FREFunction {
        @Override
        public FREObject call(final FREContext context, FREObject[] args) {
            try {
                String kind = args != null && args.length > 0 && args[0] != null ? args[0].getAsString() : "UNKNOWN";
                String detail = args != null && args.length > 1 && args[1] != null ? args[1].getAsString() : "";
                PerformanceOverlay.recordGameEvent(kind, detail);
                return FREObject.newObject("OK");
            } catch (Throwable t) {
                try { return FREObject.newObject("ERROR:" + t.getClass().getSimpleName()); }
                catch (Throwable ignored) { return null; }
            }
        }
    }

    private static final class ShareZipFunction implements FREFunction {
        @Override
        public FREObject call(final FREContext context, FREObject[] args) {
            try {
                final String payload = args.length > 0 && args[0] != null ? args[0].getAsString() : "{}";
                final String requestedName = args.length > 1 && args[1] != null ? args[1].getAsString() : "ArmyAttack-diagnostics";
                final Activity activity = context.getActivity();
                if (activity == null) {
                    return FREObject.newObject("ERROR:no_activity");
                }

                final File dir = new File(activity.getCacheDir(), "armyattack-diagnostics");
                if (!dir.exists() && !dir.mkdirs()) {
                    return FREObject.newObject("ERROR:mkdir_failed");
                }

                final String safeBase = sanitizeBaseName(requestedName);
                final String timestamp = utcTimestamp();
                final File zipFile = new File(dir, safeBase + "-" + timestamp + ".zip");
                writeZip(zipFile, payload);

                final Uri uri = Uri.parse("content://" + activity.getPackageName() + ".armyattackdiagnostics/" + Uri.encode(zipFile.getName()));
                final Intent send = new Intent(Intent.ACTION_SEND);
                send.setType("application/zip");
                send.putExtra(Intent.EXTRA_STREAM, uri);
                send.putExtra(Intent.EXTRA_SUBJECT, "Army Attack diagnostics");
                send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                send.setClipData(ClipData.newRawUri("Army Attack diagnostics", uri));

                final Runnable openChooser = new Runnable() {
                    @Override
                    public void run() {
                        Intent chooser = Intent.createChooser(send, "Compartir diagnóstico Army Attack");
                        activity.startActivity(chooser);
                    }
                };
                if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
                    openChooser.run();
                } else {
                    activity.runOnUiThread(openChooser);
                }

                return FREObject.newObject("QUEUED:" + uri.toString());
            } catch (Throwable t) {
                try {
                    return FREObject.newObject("ERROR:" + t.getClass().getSimpleName() + ":" + String.valueOf(t.getMessage()));
                } catch (Throwable ignored) {
                    return null;
                }
            }
        }

        private static void writeZip(File zipFile, String payload) throws Exception {
            ZipOutputStream zos = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(zipFile)));
            try {
                byte[] json = payload.getBytes(StandardCharsets.UTF_8);
                ZipEntry jsonEntry = new ZipEntry("diagnostics.json");
                zos.putNextEntry(jsonEntry);
                zos.write(json);
                zos.closeEntry();

                String readable =
                    "Army Attack Android diagnostic package\n" +
                    "Generated UTC: " + utcIso() + "\n" +
                    "Open diagnostics.json for structured details.\n";
                byte[] txt = readable.getBytes(StandardCharsets.UTF_8);
                ZipEntry txtEntry = new ZipEntry("README.txt");
                zos.putNextEntry(txtEntry);
                zos.write(txt);
                zos.closeEntry();
            } finally {
                zos.close();
            }
        }

        private static String sanitizeBaseName(String input) {
            String value = input == null ? "ArmyAttack-diagnostics" : input.trim();
            value = value.replaceAll("[^A-Za-z0-9._-]+", "-");
            if (value.length() == 0) value = "ArmyAttack-diagnostics";
            if (value.length() > 80) value = value.substring(0, 80);
            return value;
        }

        private static String utcTimestamp() {
            SimpleDateFormat fmt = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US);
            fmt.setTimeZone(TimeZone.getTimeZone("UTC"));
            return fmt.format(new Date());
        }

        private static String utcIso() {
            SimpleDateFormat fmt = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
            fmt.setTimeZone(TimeZone.getTimeZone("UTC"));
            return fmt.format(new Date());
        }
    }
}
