package com.valverde.armyattack.diagnostics;

import android.app.Activity;
import android.app.Application;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Debug;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;
import android.view.Choreographer;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.BufferedOutputStream;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.WeakHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public final class PerformanceOverlay {
    private static final Object GAME_EVENT_LOCK = new Object();
    private static final ArrayDeque<GameEvent> GAME_EVENTS = new ArrayDeque<GameEvent>();
    private static final int MAX_GAME_EVENTS = 3000;
    private static final String GAME_EVENT_TAG = "ArmyAttackGame";
    private static final Object FRAME_SPIKE_LOCK = new Object();
    private static final ArrayDeque<FrameSpike> FRAME_SPIKES = new ArrayDeque<FrameSpike>();
    private static final int MAX_FRAME_SPIKES = 500;
    private static volatile String LAST_GAME_EVENT_KIND = "";
    private static volatile String LAST_GAME_EVENT_DETAIL = "";
    private static volatile long LAST_GAME_EVENT_ELAPSED_MS = -1L;

    private static final class GameEvent {
        final long wallTimeMs;
        final long elapsedMs;
        final String threadName;
        final String kind;
        final String detail;
        GameEvent(long wallTimeMs, long elapsedMs, String threadName, String kind, String detail) {
            this.wallTimeMs = wallTimeMs;
            this.elapsedMs = elapsedMs;
            this.threadName = threadName;
            this.kind = kind;
            this.detail = detail;
        }
    }

    private static final class FrameSpike {
        final long elapsedMs;
        final double frameMs;
        final String eventKind;
        final String eventDetail;
        final long eventAgeMs;
        FrameSpike(long elapsedMs, double frameMs, String eventKind, String eventDetail, long eventAgeMs) {
            this.elapsedMs = elapsedMs;
            this.frameMs = frameMs;
            this.eventKind = eventKind;
            this.eventDetail = eventDetail;
            this.eventAgeMs = eventAgeMs;
        }
    }

    public static void recordGameEvent(String kind, String detail) {
        try {
            final String safeKind = kind == null ? "UNKNOWN" : kind;
            final String safeDetail = detail == null ? "" : detail;
            final long elapsed = android.os.SystemClock.elapsedRealtime();
            final GameEvent event = new GameEvent(
                System.currentTimeMillis(),
                elapsed,
                Thread.currentThread().getName(),
                safeKind,
                safeDetail
            );
            LAST_GAME_EVENT_KIND = safeKind;
            LAST_GAME_EVENT_DETAIL = safeDetail;
            LAST_GAME_EVENT_ELAPSED_MS = elapsed;
            synchronized (GAME_EVENT_LOCK) {
                while (GAME_EVENTS.size() >= MAX_GAME_EVENTS) GAME_EVENTS.removeFirst();
                GAME_EVENTS.addLast(event);
            }
            if (shouldMirrorToLogcat(safeKind)) {
                Log.i(GAME_EVENT_TAG, safeKind + " " + safeDetail);
            }
        } catch (Throwable ignored) {
        }
    }

    private static boolean shouldMirrorToLogcat(String kind) {
        if (kind == null) return false;
        return kind.startsWith("SWF_")
            || kind.startsWith("PVP_")
            || kind.startsWith("MAP_")
            || kind.startsWith("WORLD_MAP_")
            || kind.startsWith("OFFLINE_")
            || kind.startsWith("HUD_")
            || kind.startsWith("PLACEMENT_")
            || "HFE_HARVEST_ANIMATION".equals(kind)
            || kind.startsWith("TILEMAP_")
            || kind.startsWith("ANIMATION_")
            || "UI_BUTTON".equals(kind)
            || "AUTO_FLIGHT_RECORDER".equals(kind)
            || "GAMEPLAY_INPUT".equals(kind);
    }

    private static void clearFrameSpikes() {
        synchronized (FRAME_SPIKE_LOCK) { FRAME_SPIKES.clear(); }
    }

    private static void recordFrameSpike(long deltaNs) {
        long now = android.os.SystemClock.elapsedRealtime();
        long eventAt = LAST_GAME_EVENT_ELAPSED_MS;
        long age = eventAt < 0L ? -1L : Math.max(0L, now - eventAt);
        FrameSpike spike = new FrameSpike(now, deltaNs / 1_000_000.0, LAST_GAME_EVENT_KIND, LAST_GAME_EVENT_DETAIL, age);
        synchronized (FRAME_SPIKE_LOCK) {
            while (FRAME_SPIKES.size() >= MAX_FRAME_SPIKES) FRAME_SPIKES.removeFirst();
            FRAME_SPIKES.addLast(spike);
        }
    }

    private static void writeFrameSpikes(File dir) {
        if (dir == null) return;
        try {
            List<FrameSpike> snapshot;
            synchronized (FRAME_SPIKE_LOCK) { snapshot = new ArrayList<FrameSpike>(FRAME_SPIKES); }
            StringBuilder text = new StringBuilder();
            int over50 = 0;
            int over100 = 0;
            double maxMs = 0.0;
            for (FrameSpike spike : snapshot) {
                JSONObject row = new JSONObject();
                row.put("process_elapsed_ms", spike.elapsedMs);
                row.put("frame_ms", spike.frameMs);
                row.put("nearest_game_event_kind", spike.eventKind == null ? "" : spike.eventKind);
                row.put("nearest_game_event_detail", spike.eventDetail == null ? "" : spike.eventDetail);
                row.put("nearest_game_event_age_ms", spike.eventAgeMs);
                text.append(row.toString()).append('\n');
                if (spike.frameMs >= 50.0) over50++;
                if (spike.frameMs >= 100.0) over100++;
                if (spike.frameMs > maxMs) maxMs = spike.frameMs;
            }
            writeText(new File(dir, "frame-spikes.jsonl"), text.toString());
            JSONObject summary = new JSONObject();
            summary.put("threshold_ms", 33);
            summary.put("retained_spikes", snapshot.size());
            summary.put("over_50ms", over50);
            summary.put("over_100ms", over100);
            summary.put("max_frame_ms", maxMs);
            writeText(new File(dir, "frame-spikes-summary.json"), summary.toString(2));
        } catch (Throwable t) {
            appendError(dir, "frame_spikes", t);
        }
    }

    private static void writeGameEvents(File dir) {
        if (dir == null) return;
        try {
            List<GameEvent> snapshot;
            synchronized (GAME_EVENT_LOCK) { snapshot = new ArrayList<GameEvent>(GAME_EVENTS); }
            StringBuilder text = new StringBuilder();
            for (GameEvent event : snapshot) {
                JSONObject row = new JSONObject();
                row.put("utc", utcIso(event.wallTimeMs));
                row.put("process_elapsed_ms", event.elapsedMs);
                row.put("thread", event.threadName);
                row.put("kind", event.kind);
                row.put("detail", event.detail);
                text.append(row.toString()).append('\n');
            }
            writeText(new File(dir, "game-events.jsonl"), text.toString());
        } catch (Throwable t) {
            appendError(dir, "game_events", t);
        }
    }

    private static void writeGameEventSummary(File dir) {
        if (dir == null) return;
        try {
            List<GameEvent> snapshot;
            synchronized (GAME_EVENT_LOCK) { snapshot = new ArrayList<GameEvent>(GAME_EVENTS); }
            JSONObject counts = new JSONObject();
            for (GameEvent event : snapshot) {
                String kind = event.kind == null ? "UNKNOWN" : event.kind;
                counts.put(kind, counts.optInt(kind, 0) + 1);
            }
            JSONObject summary = new JSONObject();
            summary.put("generated_utc", utcIso());
            summary.put("retained_events", snapshot.size());
            summary.put("parsed_events", snapshot.size());
            summary.put("counts_by_kind", counts);
            writeText(new File(dir, "game-events-summary.json"), summary.toString(2));
        } catch (Throwable t) {
            appendError(dir, "game_event_summary", t);
        }
    }
    private static final AtomicBoolean BOOTSTRAPPED = new AtomicBoolean(false);
    private static final Map<Activity, PerformanceOverlay> INSTANCES = new WeakHashMap<Activity, PerformanceOverlay>();

    public static void bootstrap(Context context) {
        if (context == null || !BOOTSTRAPPED.compareAndSet(false, true)) return;
        Context appContext = context.getApplicationContext();
        if (!(appContext instanceof Application)) return;
        final Application app = (Application) appContext;
        app.registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
            @Override public void onActivityCreated(Activity activity, Bundle state) {}
            @Override public void onActivityStarted(Activity activity) {}
            @Override public void onActivityResumed(final Activity activity) {
                if (activity == null || !app.getPackageName().equals(activity.getPackageName())) return;
                activity.runOnUiThread(new Runnable() {
                    @Override public void run() { install(activity); }
                });
            }
            @Override public void onActivityPaused(Activity activity) {}
            @Override public void onActivityStopped(Activity activity) {}
            @Override public void onActivitySaveInstanceState(Activity activity, Bundle outState) {}
            @Override public void onActivityDestroyed(Activity activity) {
                synchronized (INSTANCES) {
                    PerformanceOverlay overlay = INSTANCES.remove(activity);
                    if (overlay != null) overlay.dispose();
                }
            }
        });
    }

    private static void install(Activity activity) {
        synchronized (INSTANCES) {
            if (INSTANCES.containsKey(activity)) return;
            PerformanceOverlay overlay = new PerformanceOverlay(activity);
            INSTANCES.put(activity, overlay);
            overlay.attach();
        }
    }

    private final Activity activity;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final ExecutorService sampler = Executors.newSingleThreadExecutor();
    private final int cores = Math.max(1, Runtime.getRuntime().availableProcessors());
    private static final long RECORD_SAMPLE_MS = 2000L;
    private static final long PANEL_SAMPLE_MS = 1500L;
    private static final long HEAVY_SAMPLE_MS = 5000L;
    private static final long LIVE_RENDER_RECORDING_MS = 5000L;
    private static final long LIVE_RENDER_IDLE_MS = 2500L;
    private static final long FLIGHT_RECORDER_FLUSH_MS = 15000L;

    private FrameLayout root;
    private LinearLayout panel;
    private TextView metricsView;
    private TextView statusView;
    private Button toggleButton;

    private boolean panelVisible = false;
    private boolean sampleLoopActive = false;
    private boolean recording = false;
    private boolean frameLoopActive = false;

    private final AtomicBoolean heavySampleInFlight = new AtomicBoolean(false);
    private volatile double latestPssMb = -1.0;
    private volatile double latestJavaMb = -1.0;
    private volatile double latestNativeMb = -1.0;
    private volatile long latestGcCount = -1L;
    private volatile long latestGcTimeMs = -1L;
    private volatile int latestThermal = -1;
    private long lastHeavySampleElapsedMs = 0L;
    private long lastLiveRenderElapsedMs = 0L;
    private long lastFlightRecorderFlushElapsedMs = 0L;

    private long lastCpuMs = -1L;
    private long lastWallMs = -1L;
    private long sessionStartElapsed = 0L;
    private long lastFrameNs = 0L;
    private int frameCountWindow = 0;
    private long frameNsWindow = 0L;
    private int jank24Window = 0;
    private int jank50Window = 0;
    private long maxFrameNsWindow = 0L;
    private long totalSamples = 0L;
    private long totalJank24 = 0L;
    private long totalJank33 = 0L;
    private long totalJank50 = 0L;
    private long totalJank100 = 0L;
    private long maxFrameNsSession = 0L;

    private File sessionDir;
    private File sessionCsv;
    private File latestJson;
    private String sessionId = "";
    private String testedSha = "unknown";
    private String renderMode = "unknown";

    private final Choreographer.FrameCallback frameCallback = new Choreographer.FrameCallback() {
        @Override public void doFrame(long frameTimeNanos) {
            if (!recording) {
                frameLoopActive = false;
                lastFrameNs = 0L;
                return;
            }
            if (lastFrameNs != 0L) {
                long delta = frameTimeNanos - lastFrameNs;
                if (delta > 0L) {
                    frameCountWindow++;
                    frameNsWindow += delta;
                    if (delta >= 24_000_000L) {
                        jank24Window++;
                        totalJank24++;
                    }
                    if (delta >= 33_000_000L) {
                        totalJank33++;
                        recordFrameSpike(delta);
                    }
                    if (delta >= 50_000_000L) {
                        jank50Window++;
                        totalJank50++;
                    }
                    if (delta >= 100_000_000L) totalJank100++;
                    if (delta > maxFrameNsWindow) maxFrameNsWindow = delta;
                    if (delta > maxFrameNsSession) maxFrameNsSession = delta;
                }
            }
            lastFrameNs = frameTimeNanos;
            Choreographer.getInstance().postFrameCallback(this);
        }
    };

    private final Runnable sampleRunnable = new Runnable() {
        @Override public void run() {
            if (!recording && !panelVisible) {
                sampleLoopActive = false;
                return;
            }
            scheduleHeavyMetrics(false);
            MetricSample sample = collectSample();
            if (recording) persistSample(sample);
            long now = android.os.SystemClock.elapsedRealtime();
            if (recording && (lastFlightRecorderFlushElapsedMs == 0L || now - lastFlightRecorderFlushElapsedMs >= FLIGHT_RECORDER_FLUSH_MS)) {
                lastFlightRecorderFlushElapsedMs = now;
                flushFlightRecorderAsync();
            }
            long liveInterval = recording ? LIVE_RENDER_RECORDING_MS : LIVE_RENDER_IDLE_MS;
            if (panelVisible && (lastLiveRenderElapsedMs == 0L || now - lastLiveRenderElapsedMs >= liveInterval)) {
                renderSample(sample);
                lastLiveRenderElapsedMs = now;
            }
            long delay = recording ? RECORD_SAMPLE_MS : PANEL_SAMPLE_MS;
            main.postDelayed(this, delay);
        }
    };

    private PerformanceOverlay(Activity activity) {
        this.activity = activity;
        readBuildMetadata();
        File rootDir = new File(activity.getFilesDir(), "perf-diagnostics");
        if (!rootDir.exists()) rootDir.mkdirs();
        latestJson = new File(rootDir, "latest.json");
        recoverLatestSession(rootDir);
    }

    private void recoverLatestSession(File rootDir) {
        File[] dirs = rootDir.listFiles();
        if (dirs == null) return;
        File newest = null;
        for (File dir : dirs) {
            if (dir != null && dir.isDirectory() && dir.getName().startsWith("session-")) {
                if (newest == null || dir.lastModified() > newest.lastModified()) newest = dir;
            }
        }
        if (newest != null) {
            sessionDir = newest;
            sessionCsv = new File(newest, "performance.csv");
            sessionId = newest.getName().substring("session-".length());
        }
    }

    private void attach() {
        root = new FrameLayout(activity);
        root.setClickable(false);
        root.setClipChildren(false);
        root.setClipToPadding(false);

        toggleButton = button("PERF");
        toggleButton.setContentDescription("army_perf_toggle");
        FrameLayout.LayoutParams toggleLp = new FrameLayout.LayoutParams(dp(76), dp(44), Gravity.TOP | Gravity.END);
        toggleLp.topMargin = dp(12);
        toggleLp.rightMargin = dp(12);
        root.addView(toggleButton, toggleLp);

        panel = new LinearLayout(activity);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(12), dp(10), dp(12), dp(10));
        panel.setBackgroundColor(Color.argb(232, 18, 27, 39));
        panel.setVisibility(View.GONE);

        TextView title = text("Army Perf · SWF intacto", 16f, Color.WHITE);
        panel.addView(title, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        metricsView = text("CPU/RAM: esperando…", 13f, Color.rgb(220, 230, 240));
        metricsView.setPadding(0, dp(6), 0, dp(6));
        panel.addView(metricsView, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        LinearLayout row1 = new LinearLayout(activity);
        row1.setOrientation(LinearLayout.HORIZONTAL);
        Button mark = button("MARCAR LAG");
        mark.setContentDescription("army_perf_mark");
        Button zip = button("ZIP");
        zip.setContentDescription("army_perf_zip");
        row1.addView(mark, weighted());
        row1.addView(zip, weighted());
        panel.addView(row1);

        statusView = text("REGISTRO SIEMPRE ACTIVO · PERF muestra métricas, marca lag o comparte una copia ZIP.", 12f, Color.rgb(170, 220, 170));
        statusView.setPadding(0, dp(8), 0, 0);
        panel.addView(statusView, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        FrameLayout.LayoutParams panelLp = new FrameLayout.LayoutParams(dp(315), ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.END);
        panelLp.topMargin = dp(64);
        panelLp.rightMargin = dp(12);
        root.addView(panel, panelLp);

        toggleButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                panelVisible = !panelVisible;
                panel.setVisibility(panelVisible ? View.VISIBLE : View.GONE);
                toggleButton.setText(panelVisible ? "CERRAR" : "PERF");
                if (panelVisible) ensureSampleLoop();
            }
        });
        mark.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                if (!recording) startSession();
                mark("LAG");
                status("LAG marcado en " + elapsedSessionMs() + " ms");
            }
        });
        zip.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { shareLatest(); }
        });

        activity.addContentView(root, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        startSession();
        recordGameEvent("AUTO_FLIGHT_RECORDER", "started_on_activity_attach");
    }

    private void startSession() {
        if (recording) {
            status("Ya hay una sesión activa.");
            return;
        }
        File sessionsRoot = new File(activity.getFilesDir(), "perf-diagnostics");
        if (!sessionsRoot.exists()) sessionsRoot.mkdirs();
        sessionId = utcCompact();
        sessionDir = new File(sessionsRoot, "session-" + sessionId);
        if (!sessionDir.exists()) sessionDir.mkdirs();
        sessionCsv = new File(sessionDir, "performance.csv");
        recording = true;
        sessionStartElapsed = android.os.SystemClock.elapsedRealtime();
        totalSamples = 0L;
        totalJank24 = 0L;
        totalJank33 = 0L;
        totalJank50 = 0L;
        totalJank100 = 0L;
        maxFrameNsSession = 0L;
        clearFrameSpikes();
        lastCpuMs = -1L;
        lastWallMs = -1L;
        lastHeavySampleElapsedMs = 0L;
        lastLiveRenderElapsedMs = 0L;
        lastFlightRecorderFlushElapsedMs = 0L;
        resetFrameWindow();
        scheduleHeavyMetrics(true);

        final File dir = sessionDir;
        io.execute(new Runnable() {
            @Override public void run() {
                try {
                    writeText(new File(dir, "README.txt"),
                        "Army Attack Android always-on flight recorder\n" +
                        "Recording starts automatically when the game activity attaches; PERF only controls visibility/manual markers.\n" +
                        "Buttons are native Android views layered over AIR; the SWF bytecode is not modified by this recorder.\n" +
                        "Use markers.jsonl to locate MARCAR LAG timestamps.\n" +
                        "ZIP captures a live snapshot without stopping the always-on recorder, including threads/proc/memory when Android permits it.\n" +
                        "Search game-events.jsonl for UI_BUTTON, PVP_, WORLD_MAP_, MAP_, OFFLINE_SWITCH_MAP, SWF_, ANIMATION_, HFE_ and TILEMAP_ markers.\n" +
                        "frame-spikes.jsonl records every >=33ms frame and correlates it with the nearest preceding SWF/game event.\n" +
                        "MARCAR LAG captures an immediate lag-snapshots/ thread, proc, memory and own-process logcat snapshot near the hitch.\n" +
                        "Live metrics text is throttled while recording so the profiler does not compete with AIR layout on the main thread.\n");
                    writeText(new File(dir, "device.json"), buildDeviceJson().toString(2));
                    writeText(sessionCsv,
                        "elapsed_ms,utc,cpu_onecore_pct,cpu_normalized_pct,pss_mb,java_used_mb,native_mb,gc_count,gc_time_ms,thermal,vsync_fps,jank_24ms,jank_50ms,max_frame_ms,cores\n");
                } catch (Throwable t) {
                    appendError(dir, "start_io", t);
                }
            }
        });
        mark("START");
        startFrameLoop();
        ensureSampleLoop();
        status("GRABANDO · juega y pulsa MARCAR LAG cuando lo notes.");
    }

    private void stopSession() {
        if (!recording) {
            status("Profiler ya está detenido.");
            return;
        }
        mark("STOP");
        recording = false;
        if (frameLoopActive) {
            Choreographer.getInstance().removeFrameCallback(frameCallback);
            frameLoopActive = false;
        }
        lastFrameNs = 0L;
        final File dir = sessionDir;
        final long duration = elapsedSessionMs();
        final long samples = totalSamples;
        final long j24 = totalJank24;
        final long j33 = totalJank33;
        final long j50 = totalJank50;
        final long j100 = totalJank100;
        final double maxMs = maxFrameNsSession / 1_000_000.0;
        io.execute(new Runnable() {
            @Override public void run() {
                try {
                    captureProcessDiagnostics(dir);
                    JSONObject summary = new JSONObject();
                    summary.put("schema_version", 1);
                    summary.put("session_id", sessionId);
                    summary.put("tested_sha", testedSha);
                    summary.put("render_mode", renderMode);
                    summary.put("duration_ms", duration);
                    summary.put("samples", samples);
                    summary.put("jank_24ms_total", j24);
                    summary.put("jank_33ms_total", j33);
                    summary.put("jank_50ms_total", j50);
                    summary.put("jank_100ms_total", j100);
                    summary.put("max_frame_ms", maxMs);
                    writeText(new File(dir, "session.json"), summary.toString(2));
                } catch (Throwable t) {
                    appendError(dir, "stop_io", t);
                }
            }
        });
        status("DETENIDO · pulsa ZIP para compartir la sesión.");
    }

    private void shareLatest() {
        if (sessionDir == null || !recording) startSession();
        mark("SHARE");
        final File dir = sessionDir;
        status("Preparando ZIP sin detener el registro…");
        io.execute(new Runnable() {
            @Override public void run() {
                try {
                    captureProcessDiagnostics(dir);
                    writeGameEvents(dir);
                    writeGameEventSummary(dir);
                    writeFrameSpikes(dir);
                    File cacheDir = new File(activity.getCacheDir(), "armyattack-diagnostics");
                    if (!cacheDir.exists() && !cacheDir.mkdirs()) throw new IllegalStateException("mkdir cache");
                    final File zip = new File(cacheDir, "ArmyAttack-perf-" + utcCompact() + ".zip");
                    zipDirectory(dir, zip);
                    main.post(new Runnable() {
                        @Override public void run() {
                            try {
                                Uri uri = Uri.parse("content://" + activity.getPackageName() + ".armyattackdiagnostics/" + Uri.encode(zip.getName()));
                                Intent send = new Intent(Intent.ACTION_SEND);
                                send.setType("application/zip");
                                send.putExtra(Intent.EXTRA_STREAM, uri);
                                send.putExtra(Intent.EXTRA_SUBJECT, "Army Attack performance diagnostics");
                                send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                                send.setClipData(ClipData.newRawUri("Army Attack performance", uri));
                                activity.startActivity(Intent.createChooser(send, "Compartir rendimiento Army Attack"));
                                status("ZIP listo · elige WhatsApp/correo/Drive.");
                            } catch (Throwable t) {
                                appendError(dir, "share_intent", t);
                                status("ERROR ZIP: " + t.getClass().getSimpleName() + " · sesión guardada.");
                            }
                        }
                    });
                } catch (final Throwable t) {
                    appendError(dir, "zip", t);
                    main.post(new Runnable() {
                        @Override public void run() {
                            status("ERROR ZIP: " + t.getClass().getSimpleName() + " · sesión guardada.");
                        }
                    });
                }
            }
        });
    }

    private void mark(final String type) {
        if (sessionDir == null) return;
        final long elapsed = elapsedSessionMs();
        final String utc = utcIso();
        final File dir = sessionDir;
        io.execute(new Runnable() {
            @Override public void run() {
                try {
                    JSONObject marker = new JSONObject();
                    marker.put("utc", utc);
                    marker.put("elapsed_ms", elapsed);
                    marker.put("type", type);
                    appendText(new File(dir, "markers.jsonl"), marker.toString() + "\n");
                    if ("LAG".equals(type)) {
                        writeGameEvents(dir);
                        writeGameEventSummary(dir);
                        writeFrameSpikes(dir);
                        File lagDir = new File(new File(dir, "lag-snapshots"), "lag-" + elapsed);
                        if (!lagDir.exists()) lagDir.mkdirs();
                        captureProcessDiagnostics(lagDir);
                    }
                } catch (Throwable t) {
                    appendError(dir, "marker", t);
                }
            }
        });
    }

    private void persistSample(final MetricSample sample) {
        totalSamples++;
        final File dir = sessionDir;
        final File csv = sessionCsv;
        io.execute(new Runnable() {
            @Override public void run() {
                try {
                    appendText(csv, sample.csv() + "\n");
                    JSONObject current = sample.json();
                    current.put("session_id", sessionId);
                    current.put("tested_sha", testedSha);
                    current.put("render_mode", renderMode);
                    writeText(new File(dir, "latest.json"), current.toString(2));
                    writeText(latestJson, current.toString(2));
                } catch (Throwable t) {
                    appendError(dir, "sample_io", t);
                }
            }
        });
    }

    private MetricSample collectSample() {
        long nowWall = android.os.SystemClock.elapsedRealtime();
        long nowCpu = android.os.Process.getElapsedCpuTime();
        double cpuOne = 0.0;
        if (lastWallMs > 0L && nowWall > lastWallMs && lastCpuMs >= 0L) {
            cpuOne = 100.0 * (double) (nowCpu - lastCpuMs) / (double) (nowWall - lastWallMs);
        }
        lastWallMs = nowWall;
        lastCpuMs = nowCpu;

        double pssMb = latestPssMb;
        double javaMb = latestJavaMb;
        double nativeMb = latestNativeMb;
        long gcCount = latestGcCount;
        long gcTime = latestGcTimeMs;
        int thermal = latestThermal;

        double fps = frameNsWindow > 0L ? (1_000_000_000.0 * frameCountWindow / (double) frameNsWindow) : 0.0;
        double maxFrameMs = maxFrameNsWindow / 1_000_000.0;
        int j24 = jank24Window;
        int j50 = jank50Window;
        resetFrameWindow();

        return new MetricSample(
            elapsedSessionMs(), utcIso(), cpuOne, cpuOne / cores, pssMb, javaMb, nativeMb,
            gcCount, gcTime, thermal, fps, j24, j50, maxFrameMs, cores
        );
    }

    private void scheduleHeavyMetrics(boolean force) {
        long now = android.os.SystemClock.elapsedRealtime();
        if (!force && lastHeavySampleElapsedMs > 0L && (now - lastHeavySampleElapsedMs) < HEAVY_SAMPLE_MS) return;
        if (!heavySampleInFlight.compareAndSet(false, true)) return;
        lastHeavySampleElapsedMs = now;
        final Context appContext = activity.getApplicationContext();
        sampler.execute(new Runnable() {
            @Override public void run() {
                try {
                    Debug.MemoryInfo mi = new Debug.MemoryInfo();
                    Debug.getMemoryInfo(mi);
                    Runtime rt = Runtime.getRuntime();
                    latestPssMb = mi.getTotalPss() / 1024.0;
                    latestJavaMb = (rt.totalMemory() - rt.freeMemory()) / 1048576.0;
                    latestNativeMb = Debug.getNativeHeapAllocatedSize() / 1048576.0;
                    latestGcCount = runtimeStat("art.gc.gc-count");
                    latestGcTimeMs = runtimeStat("art.gc.gc-time");
                    int thermal = -1;
                    if (Build.VERSION.SDK_INT >= 29) {
                        try {
                            PowerManager pm = (PowerManager) appContext.getSystemService(Context.POWER_SERVICE);
                            if (pm != null) thermal = pm.getCurrentThermalStatus();
                        } catch (Throwable ignored) {}
                    }
                    latestThermal = thermal;
                } catch (Throwable ignored) {
                } finally {
                    heavySampleInFlight.set(false);
                }
            }
        });
    }

    private static void captureProcessDiagnostics(File dir) {
        if (dir == null) return;
        try {
            StringBuilder threads = new StringBuilder();
            Map<Thread, StackTraceElement[]> all = Thread.getAllStackTraces();
            for (Map.Entry<Thread, StackTraceElement[]> entry : all.entrySet()) {
                Thread thread = entry.getKey();
                threads.append('"').append(thread.getName()).append('"').append(" id=").append(thread.getId()).append(" state=").append(thread.getState()).append('\n');
                StackTraceElement[] stack = entry.getValue();
                if (stack != null) for (StackTraceElement frame : stack) threads.append("    at ").append(frame.toString()).append('\n');
                threads.append('\n');
            }
            writeText(new File(dir, "threads.txt"), threads.toString());
        } catch (Throwable t) {
            appendError(dir, "thread_dump", t);
        }
        writeGameEvents(dir);
        writeGameEventSummary(dir);
        writeFrameSpikes(dir);
        copyProcFile("/proc/self/status", new File(dir, "proc-status.txt"), 1024 * 1024);
        copyProcFile("/proc/self/stat", new File(dir, "proc-stat.txt"), 1024 * 1024);
        copyProcFile("/proc/self/sched", new File(dir, "proc-sched.txt"), 1024 * 1024);
        copyProcFile("/proc/self/smaps_rollup", new File(dir, "smaps-rollup.txt"), 1024 * 1024);
        captureOwnLogcat(dir);
    }

    private static void copyProcFile(String source, File destination, int maxBytes) {
        BufferedInputStream in = null;
        FileOutputStream out = null;
        try {
            File src = new File(source);
            if (!src.exists()) return;
            in = new BufferedInputStream(new FileInputStream(src));
            out = new FileOutputStream(destination, false);
            byte[] buffer = new byte[8192];
            int total = 0;
            int read;
            while ((read = in.read(buffer)) != -1 && total < maxBytes) {
                int allowed = Math.min(read, maxBytes - total);
                out.write(buffer, 0, allowed);
                total += allowed;
            }
        } catch (Throwable t) {
            appendError(destination.getParentFile(), "proc_capture:" + source, t);
        } finally {
            try { if (in != null) in.close(); } catch (Throwable ignored) {}
            try { if (out != null) out.close(); } catch (Throwable ignored) {}
        }
    }

    private static void captureOwnLogcat(File dir) {
        if (Build.VERSION.SDK_INT < 24) return;
        Process process = null;
        BufferedReader reader = null;
        try {
            process = new ProcessBuilder("logcat", "-d", "-v", "threadtime", "--pid=" + android.os.Process.myPid()).redirectErrorStream(true).start();
            reader = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8));
            StringBuilder out = new StringBuilder();
            String line;
            final int cap = 2 * 1024 * 1024;
            while ((line = reader.readLine()) != null && out.length() < cap) out.append(line).append('\n');
            process.waitFor();
            writeText(new File(dir, "logcat-own-process.txt"), out.toString());
        } catch (Throwable t) {
            appendError(dir, "logcat_own_process", t);
        } finally {
            try { if (reader != null) reader.close(); } catch (Throwable ignored) {}
            if (process != null) try { process.destroy(); } catch (Throwable ignored) {}
        }
    }

    private void renderSample(MetricSample s) {
        if (metricsView == null || !panelVisible) return;
        String fpsText = recording ? String.format(Locale.US, "%.1f", s.vsyncFps) : "—";
        metricsView.setText(
            String.format(Locale.US,
                "CPU %.0f%% (%.0f%%/%d cores)\nRAM PSS %.0f MB · Java %.0f MB · Native %.0f MB\nGC %s / %s ms · Thermal %d\nVSYNC %s · jank>24 %d · >50 %d · max %.1f ms",
                s.cpuOneCorePct, s.cpuNormalizedPct, s.cores,
                s.pssMb, s.javaUsedMb, s.nativeMb,
                s.gcCount < 0 ? "?" : Long.toString(s.gcCount),
                s.gcTimeMs < 0 ? "?" : Long.toString(s.gcTimeMs),
                s.thermal, fpsText, s.jank24, s.jank50, s.maxFrameMs
            )
        );
    }

    private void flushFlightRecorderAsync() {
        final File dir = sessionDir;
        if (dir == null) return;
        io.execute(new Runnable() {
            @Override public void run() {
                writeGameEvents(dir);
                writeGameEventSummary(dir);
                writeFrameSpikes(dir);
            }
        });
    }

    private void ensureSampleLoop() {
        if (sampleLoopActive) return;
        sampleLoopActive = true;
        main.post(sampleRunnable);
    }

    private void startFrameLoop() {
        if (frameLoopActive) return;
        frameLoopActive = true;
        lastFrameNs = 0L;
        Choreographer.getInstance().postFrameCallback(frameCallback);
    }

    private void resetFrameWindow() {
        frameCountWindow = 0;
        frameNsWindow = 0L;
        jank24Window = 0;
        jank50Window = 0;
        maxFrameNsWindow = 0L;
    }

    private void dispose() {
        recording = false;
        main.removeCallbacks(sampleRunnable);
        if (frameLoopActive) {
            try { Choreographer.getInstance().removeFrameCallback(frameCallback); } catch (Throwable ignored) {}
        }
        frameLoopActive = false;
        io.shutdown();
        sampler.shutdown();
        if (root != null && root.getParent() instanceof ViewGroup) {
            ((ViewGroup) root.getParent()).removeView(root);
        }
    }

    private long elapsedSessionMs() {
        if (sessionStartElapsed <= 0L) return 0L;
        return Math.max(0L, android.os.SystemClock.elapsedRealtime() - sessionStartElapsed);
    }

    private void readBuildMetadata() {
        try {
            ApplicationInfo ai = activity.getPackageManager().getApplicationInfo(activity.getPackageName(), 128);
            if (ai.metaData != null) {
                String sha = ai.metaData.getString("armyattack.tested_sha");
                String mode = ai.metaData.getString("armyattack.render_mode");
                if (sha != null && sha.length() > 0) testedSha = sha;
                if (mode != null && mode.length() > 0) renderMode = mode;
            }
        } catch (Throwable ignored) {}
    }

    private JSONObject buildDeviceJson() throws Exception {
        JSONObject obj = new JSONObject();
        obj.put("generated_utc", utcIso());
        obj.put("package", activity.getPackageName());
        obj.put("tested_sha", testedSha);
        obj.put("render_mode", renderMode);
        obj.put("manufacturer", Build.MANUFACTURER);
        obj.put("model", Build.MODEL);
        obj.put("device", Build.DEVICE);
        obj.put("android_release", Build.VERSION.RELEASE);
        obj.put("api", Build.VERSION.SDK_INT);
        obj.put("cores", cores);
        if (Build.VERSION.SDK_INT >= 21) obj.put("abis", join(Build.SUPPORTED_ABIS));
        try {
            PackageInfo pi = activity.getPackageManager().getPackageInfo(activity.getPackageName(), 0);
            obj.put("version_name", pi.versionName);
            if (Build.VERSION.SDK_INT >= 28) obj.put("version_code", pi.getLongVersionCode());
            else obj.put("version_code", pi.versionCode);
        } catch (Throwable ignored) {}
        return obj;
    }

    private long runtimeStat(String key) {
        if (Build.VERSION.SDK_INT < 23) return -1L;
        try {
            String value = Debug.getRuntimeStat(key);
            if (value == null) return -1L;
            String digits = value.replaceAll("[^0-9]", "");
            return digits.length() == 0 ? -1L : Long.parseLong(digits);
        } catch (Throwable ignored) {
            return -1L;
        }
    }

    private void status(String text) {
        if (statusView != null) statusView.setText(text);
    }

    private Button button(String label) {
        Button b = new Button(activity);
        b.setText(label);
        b.setTextSize(12f);
        b.setAllCaps(false);
        b.setMinHeight(0);
        b.setMinWidth(0);
        return b;
    }

    private TextView text(String value, float sp, int color) {
        TextView t = new TextView(activity);
        t.setText(value);
        t.setTextSize(sp);
        t.setTextColor(color);
        return t;
    }

    private LinearLayout.LayoutParams weighted() {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(44), 1f);
        lp.setMargins(dp(2), dp(2), dp(2), dp(2));
        return lp;
    }

    private int dp(int value) {
        return Math.round(value * activity.getResources().getDisplayMetrics().density);
    }

    private static void zipDirectory(File sourceDir, File zipFile) throws Exception {
        ZipOutputStream zos = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(zipFile)));
        try {
            zipRecursive(sourceDir, sourceDir, zos);
        } finally {
            zos.close();
        }
    }

    private static void zipRecursive(File root, File file, ZipOutputStream zos) throws Exception {
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) {
                for (File child : children) zipRecursive(root, child, zos);
            }
            return;
        }
        String name = root.toURI().relativize(file.toURI()).getPath();
        zos.putNextEntry(new ZipEntry(name));
        BufferedInputStream in = new BufferedInputStream(new FileInputStream(file));
        try {
            byte[] buffer = new byte[8192];
            int read;
            while ((read = in.read(buffer)) != -1) zos.write(buffer, 0, read);
        } finally {
            in.close();
            zos.closeEntry();
        }
    }

    private static void writeText(File file, String value) throws Exception {
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();
        BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(new FileOutputStream(file, false), StandardCharsets.UTF_8));
        try { writer.write(value); } finally { writer.close(); }
    }

    private static void appendText(File file, String value) throws Exception {
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();
        BufferedWriter writer = new BufferedWriter(new FileWriter(file, true));
        try { writer.write(value); } finally { writer.close(); }
    }

    private static void appendError(File dir, String phase, Throwable t) {
        if (dir == null) return;
        try {
            String message = utcIso() + " phase=" + phase + " " + t.getClass().getName() + ": " + String.valueOf(t.getMessage()) + "\n";
            appendText(new File(dir, "errors.txt"), message);
        } catch (Throwable ignored) {}
    }

    private static String join(String[] values) {
        if (values == null) return "";
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < values.length; i++) {
            if (i > 0) b.append(',');
            b.append(values[i]);
        }
        return b.toString();
    }

    private static String utcCompact() {
        SimpleDateFormat fmt = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US);
        fmt.setTimeZone(TimeZone.getTimeZone("UTC"));
        return fmt.format(new Date());
    }

    private static String utcIso() {
        return utcIso(System.currentTimeMillis());
    }

    private static String utcIso(long wallTimeMs) {
        SimpleDateFormat fmt = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        fmt.setTimeZone(TimeZone.getTimeZone("UTC"));
        return fmt.format(new Date(wallTimeMs));
    }

    private static final class MetricSample {
        final long elapsedMs;
        final String utc;
        final double cpuOneCorePct;
        final double cpuNormalizedPct;
        final double pssMb;
        final double javaUsedMb;
        final double nativeMb;
        final long gcCount;
        final long gcTimeMs;
        final int thermal;
        final double vsyncFps;
        final int jank24;
        final int jank50;
        final double maxFrameMs;
        final int cores;

        MetricSample(long elapsedMs, String utc, double cpuOneCorePct, double cpuNormalizedPct,
                     double pssMb, double javaUsedMb, double nativeMb, long gcCount, long gcTimeMs,
                     int thermal, double vsyncFps, int jank24, int jank50, double maxFrameMs, int cores) {
            this.elapsedMs = elapsedMs;
            this.utc = utc;
            this.cpuOneCorePct = cpuOneCorePct;
            this.cpuNormalizedPct = cpuNormalizedPct;
            this.pssMb = pssMb;
            this.javaUsedMb = javaUsedMb;
            this.nativeMb = nativeMb;
            this.gcCount = gcCount;
            this.gcTimeMs = gcTimeMs;
            this.thermal = thermal;
            this.vsyncFps = vsyncFps;
            this.jank24 = jank24;
            this.jank50 = jank50;
            this.maxFrameMs = maxFrameMs;
            this.cores = cores;
        }

        String csv() {
            return String.format(Locale.US,
                "%d,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%.2f,%d,%d,%.2f,%d",
                elapsedMs, utc, cpuOneCorePct, cpuNormalizedPct, pssMb, javaUsedMb, nativeMb,
                gcCount, gcTimeMs, thermal, vsyncFps, jank24, jank50, maxFrameMs, cores);
        }

        JSONObject json() throws Exception {
            JSONObject obj = new JSONObject();
            obj.put("elapsed_ms", elapsedMs);
            obj.put("utc", utc);
            obj.put("cpu_onecore_pct", cpuOneCorePct);
            obj.put("cpu_normalized_pct", cpuNormalizedPct);
            obj.put("pss_mb", pssMb);
            obj.put("java_used_mb", javaUsedMb);
            obj.put("native_mb", nativeMb);
            obj.put("gc_count", gcCount);
            obj.put("gc_time_ms", gcTimeMs);
            obj.put("thermal", thermal);
            obj.put("vsync_fps", vsyncFps);
            obj.put("jank_24ms", jank24);
            obj.put("jank_50ms", jank50);
            obj.put("max_frame_ms", maxFrameMs);
            obj.put("cores", cores);
            return obj;
        }
    }
}
