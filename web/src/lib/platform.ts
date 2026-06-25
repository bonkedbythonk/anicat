// Synchronous platform detection from the webview user agent. Tauri's webview
// reports the host OS, so this is reliable and avoids an async plugin call.
const ua = typeof navigator !== "undefined" ? navigator.userAgent : "";

export const isWindows = /Windows/i.test(ua);
export const isMacOS = /Macintosh|Mac OS X/i.test(ua);
export const isLinux = /Linux/i.test(ua) && !/Android/i.test(ua);

// macOS uses an overlay titlebar (no native bar), so the app draws its own
// drag region and leaves room for the traffic lights. Windows and Linux use a
// native titlebar, so that chrome should be skipped.
export const usesOverlayTitlebar = isMacOS;
