package com.anicat.android;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

import dev.jdtech.mpv.MPVLib;

/**
 * libmpv in the app's process, shown by {@link MainActivity}. The engine asks
 * for it exactly as it would start a desktop mpv: {@link #startMpv} gets the
 * command line. Each {@code --key=value} becomes a libmpv option, among them
 * {@code input-ipc-server}, so the engine drives this mpv over the same JSON
 * IPC it uses on Windows and macOS and everything after the start (progress,
 * 85% watched, next episode) is the code the desktop builds run.
 */
public final class Player implements SurfaceHolder.Callback, MPVLib.EventObserver {
    private static final String TAG = "AnicatPlayer";
    private static final int EVENT_SHUTDOWN = 1;
    /** After a quit, how long libmpv gets before the screen closes anyway. */
    private static final long QUIT_GRACE_MS = 3000;

    /** Set on the command line for a desktop mpv and meaningless here. */
    private static final String[] SKIPPED = {"config-dir", "include"};

    /** Applied before init: what mpv-android sets, plus Anicat's mpv.conf. */
    private static final String[][] BASE = {
            // Direct-to-surface `mediacodec` left the core thread blocked in
            // MediaCodec.dequeueOutputBuffer on the emulator; the copy variant
            // still decodes in hardware. A `hwdec` file in the app's files directory
            // replaces it (`hwdec()`), for testing where MediaCodec is broken.
            {"hwdec", "mediacodec-copy"},
            {"gpu-context", "android"},
            {"opengl-es", "yes"},
            {"ao", "audiotrack,opensles"},
            // There is no yt-dlp on the device to hand a page URL to.
            {"ytdl", "no"},
            {"osc", "no"},
            {"input-default-bindings", "no"},
            {"input-vo-keyboard", "no"},
            {"alang", "ja,jpn,en,eng"},
            {"slang", "en,eng,enUS,en-US"},
            {"sub-auto", "fuzzy"},
            {"cache", "yes"},
            {"demuxer-max-bytes", "64MiB"},
            {"demuxer-readahead-secs", "60"},
    };

    private final Context app;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private MainActivity activity;
    private SurfaceView surface;
    private boolean surfaceReady;
    private String[] pending;
    private MPVLib mpv;

    Player(Context app) {
        this.app = app.getApplicationContext();
    }

    void attach(MainActivity activity, SurfaceView surface) {
        this.activity = activity;
        this.surface = surface;
        surface.getHolder().addCallback(this);
    }

    void detach(MainActivity activity) {
        if (this.activity != activity) return;
        surface.getHolder().removeCallback(this);
        this.activity = null;
        this.surface = null;
        surfaceReady = false;
    }

    /** From the engine, on one of its threads. */
    public void startMpv(String[] args) {
        if (activity == null) {
            // Nothing on screen to play in; the engine reports it to the page.
            throw new IllegalStateException("Anicat is not on screen");
        }
        ui.post(() -> begin(args));
    }

    /** From the engine, when libmpv ignored a quit. */
    public void killMpv() {
        ui.post(this::finishNow);
    }

    private void begin(String[] args) {
        if (activity == null) {
            Native.mpvEnded();
            return;
        }
        if (mpv != null) finishNow();
        pending = args;
        activity.showPlayer();
        if (surfaceReady) launch();
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        surfaceReady = true;
        if (pending != null) {
            launch();
        } else if (mpv != null) {
            mpv.attachSurface(holder.getSurface());
        }
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {}

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        surfaceReady = false;
        if (mpv != null) mpv.detachSurface();
    }

    private void launch() {
        String[] args = pending;
        pending = null;
        String url = null;
        try {
            mpv = MPVLib.create(app);
            for (String[] o : BASE) mpv.setOptionString(o[0], o[1]);
            String hwdec = hwdec();
            if (hwdec != null) mpv.setOptionString("hwdec", hwdec);
            for (int i = 0; i < args.length; i++) {
                String a = args[i];
                if (a.equals("--")) {
                    url = args[i + 1];
                    break;
                }
                if (!a.startsWith("--")) continue;
                int eq = a.indexOf('=');
                String key = eq < 0 ? a.substring(2) : a.substring(2, eq);
                String value = eq < 0 ? "yes" : a.substring(eq + 1);
                if (skipped(key)) continue;
                int rc = mpv.setOptionString(key, value);
                if (rc < 0) Log.w(TAG, "libmpv refused --" + key + "=" + value + " (" + rc + ")");
            }
            mpv.init();
            mpv.addObserver(this);
            mpv.attachSurface(surface.getHolder().getSurface());
            // Only now: the video output needs the surface attached first.
            mpv.setOptionString("force-window", "yes");
            mpv.setOptionString("vo", "gpu");
            mpv.command(new String[]{"loadfile", url});
        } catch (RuntimeException e) {
            Log.e(TAG, "could not start libmpv", e);
            finishNow();
        }
    }

    /** The contents of files/hwdec, when there is such a file. */
    private String hwdec() {
        java.io.File f = new java.io.File(app.getFilesDir(), "hwdec");
        if (!f.isFile()) return null;
        try {
            return new String(java.nio.file.Files.readAllBytes(f.toPath())).trim();
        } catch (java.io.IOException e) {
            return null;
        }
    }

    private static boolean skipped(String key) {
        for (String s : SKIPPED) if (s.equals(key)) return true;
        return false;
    }

    @Override
    public void event(int id) {
        if (id == EVENT_SHUTDOWN) ui.post(this::finishNow);
    }

    @Override public void eventProperty(String name) {}
    @Override public void eventProperty(String name, long value) {}
    @Override public void eventProperty(String name, double value) {}
    @Override public void eventProperty(String name, boolean value) {}
    @Override public void eventProperty(String name, String value) {}

    /** Back on the player: quit through libmpv, so the engine sees a normal end. */
    void stop() {
        if (mpv == null) return;
        mpv.command(new String[]{"quit"});
        ui.postDelayed(this::finishNow, QUIT_GRACE_MS);
    }

    void togglePause() {
        if (mpv != null) mpv.command(new String[]{"cycle", "pause"});
    }

    void seek(int seconds) {
        if (mpv != null) mpv.command(new String[]{"seek", Integer.toString(seconds), "relative"});
    }

    /** The app left the screen: a paused mpv, not a stream nobody watches. */
    void pause() {
        if (mpv != null) mpv.setPropertyBoolean("pause", true);
    }

    boolean playing() {
        return mpv != null || pending != null;
    }

    /** Idempotent: SHUTDOWN, the quit grace timer and the engine's kill can all land. */
    private void finishNow() {
        pending = null;
        MPVLib m = mpv;
        if (m == null) return;
        mpv = null;
        m.removeObserver(this);
        m.detachSurface();
        m.destroy();
        if (activity != null) activity.hidePlayer();
        Native.mpvEnded();
    }
}
