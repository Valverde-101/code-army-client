package com.valverde.armyattack.diagnostics;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;

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
    @Override
    public FREContext createContext(String contextType) {
        return new DiagnosticsContext();
    }

    @Override
    public void initialize() {}

    @Override
    public void dispose() {}

    private static final class DiagnosticsContext extends FREContext {
        @Override
        public Map<String, FREFunction> getFunctions() {
            Map<String, FREFunction> functions = new HashMap<String, FREFunction>();
            functions.put("shareZip", new ShareZipFunction());
            return functions;
        }

        @Override
        public void dispose() {}
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

                activity.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        Intent chooser = Intent.createChooser(send, "Compartir diagnóstico Army Attack");
                        activity.startActivity(chooser);
                    }
                });

                return FREObject.newObject(uri.toString());
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
