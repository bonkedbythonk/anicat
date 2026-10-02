package com.anicat.android;

import android.app.Application;

import java.util.concurrent.CompletableFuture;

/**
 * The engine lives in the process, not in an activity: rotation or a
 * relaunch recreates activities, and a second engine on the same registry
 * and torrent cache evicts and pins files under the first.
 */
public class App extends Application {
    /** The port the page is served on; -1 when the engine failed to start. */
    static final CompletableFuture<Integer> PORT = new CompletableFuture<>();
    static Player player;

    @Override
    public void onCreate() {
        super.onCreate();
        player = new Player(this);
        String dataDir = getFilesDir().getAbsolutePath();
        new Thread(() -> PORT.complete(Native.start(dataDir, player)), "anicat-engine").start();
    }
}
