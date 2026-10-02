package com.anicat.android;

/** The engine: the server crate built as libanicat_android.so. */
final class Native {
    static {
        System.loadLibrary("anicat_android");
    }

    /**
     * Starts the engine and its HTTP server, once per process, and returns the
     * port the page is served on, or -1 when the engine could not start.
     * Blocks for the engine's startup: call it off the main thread. {@code host}
     * is asked to show the player when something is played.
     */
    static native int start(String dataDir, Player host);

    /** The player screen is gone; the engine's session finishes on this. */
    static native void mpvEnded();

    private Native() {}
}
