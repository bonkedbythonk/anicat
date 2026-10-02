package com.anicat.android;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.ActivityInfo;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.TextView;

/** The page in a WebView, and the player over it while something plays. */
public class MainActivity extends Activity {
    private static final int BACKGROUND = Color.BLACK;

    private WebView web;
    private SurfaceView surface;
    private TextView status;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(BACKGROUND);

        web = new WebView(this);
        web.setBackgroundColor(BACKGROUND);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            WebView.setWebContentsDebuggingEnabled(true);
        }
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                if ("127.0.0.1".equals(uri.getHost())) return false;
                // AniList, TMDB and the like belong in the browser, not in
                // a WebView with the engine's page behind it.
                startActivity(new Intent(Intent.ACTION_VIEW, uri));
                return true;
            }
        });
        root.addView(web, new FrameLayout.LayoutParams(-1, -1));

        surface = new SurfaceView(this);
        surface.setVisibility(View.GONE);
        GestureDetector taps = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener() {
            // Without this the detector never sees the rest of a tap: a view
            // is only sent a gesture's later events if it took the DOWN.
            @Override
            public boolean onDown(MotionEvent e) {
                return true;
            }

            @Override
            public boolean onSingleTapConfirmed(MotionEvent e) {
                App.player.togglePause();
                return true;
            }

            @Override
            public boolean onDoubleTap(MotionEvent e) {
                App.player.seek(e.getX() < surface.getWidth() / 2f ? -10 : 10);
                return true;
            }
        });
        surface.setOnTouchListener((v, e) -> taps.onTouchEvent(e));
        root.addView(surface, new FrameLayout.LayoutParams(-1, -1));

        status = new TextView(this);
        status.setTextColor(Color.LTGRAY);
        status.setText("Starting Anicat...");
        FrameLayout.LayoutParams centered = new FrameLayout.LayoutParams(-2, -2);
        centered.gravity = android.view.Gravity.CENTER;
        root.addView(status, centered);

        setContentView(root);
        App.player.attach(this, surface);

        new Thread(() -> {
            int port;
            try {
                port = App.PORT.get();
            } catch (Exception e) {
                port = -1;
            }
            int p = port;
            runOnUiThread(() -> {
                if (p < 0) {
                    status.setText("Anicat could not start its engine.");
                    return;
                }
                status.setVisibility(View.GONE);
                web.loadUrl("http://127.0.0.1:" + p + "/");
            });
        }, "anicat-wait-engine").start();
    }

    void showPlayer() {
        setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
        web.setVisibility(View.INVISIBLE);
        surface.setVisibility(View.VISIBLE);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().getAttributes().layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
    }

    void hidePlayer() {
        surface.setVisibility(View.GONE);
        web.setVisibility(View.VISIBLE);
        setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED);
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().getAttributes().layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT;
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_VISIBLE);
    }

    @Override
    public void onBackPressed() {
        if (App.player.playing()) {
            App.player.stop();
        } else if (web.canGoBack()) {
            web.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onPause() {
        App.player.pause();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        App.player.detach(this);
        web.destroy();
        super.onDestroy();
    }
}
