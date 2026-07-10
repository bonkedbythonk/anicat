use std::fs;
use std::path::Path;

/// Mobile PWA assets Tauri's `resources` array bundles into the app (see
/// tauri.conf.json's `bundle.resources` entries for `mobile-dist/**/*`).
/// Copied here (not just referenced from `../dist` directly) because that
/// list needs a stable, narrow destination folder name — "mobile-dist" — that
/// doesn't collide with the desktop webview's own `../dist` output, and
/// Tauri's array-form resources preserve each entry's relative path verbatim,
/// so the destination folder name comes from wherever the source file lives.
const MOBILE_DIST_FILES: &[&str] = &[
    "mobile.html",
    "mobile-manifest.webmanifest",
    "sw.js",
    "anicat_logo.png",
    "favicon.png",
    "paw_icon.png",
];

fn sync_mobile_dist() {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let dist_dir = manifest_dir.join("..").join("dist");
    if !dist_dir.exists() {
        // `npm run build` hasn't run yet (e.g. `cargo check`/`clippy` in CI,
        // which never builds the frontend). tauri_build::build() validates
        // tauri.conf.json's `mobile-dist/**/*` resource glob and treats zero
        // matches as a hard error, not a no-op — so leaving the directory
        // missing here fails the whole build, not just the mobile bundling.
        // A placeholder keeps the glob non-empty; real `npm run build` +
        // `tauri build` runs (package.json's `build` script) always populate
        // this for real before it matters.
        let mobile_dist_dir = manifest_dir.join("mobile-dist");
        let _ = fs::create_dir_all(&mobile_dist_dir);
        let _ = fs::write(mobile_dist_dir.join(".placeholder"), b"populated by npm run build");
        return;
    }

    let mobile_dist_dir = manifest_dir.join("mobile-dist");
    let _ = fs::remove_dir_all(&mobile_dist_dir);
    let _ = fs::create_dir_all(&mobile_dist_dir);
    let _ = fs::create_dir_all(mobile_dist_dir.join("assets"));
    let _ = fs::create_dir_all(mobile_dist_dir.join("mobile-icons"));

    for name in MOBILE_DIST_FILES {
        let src = dist_dir.join(name);
        if src.exists() {
            let _ = fs::copy(&src, mobile_dist_dir.join(name));
        }
    }
    copy_dir_flat(&dist_dir.join("assets"), &mobile_dist_dir.join("assets"));
    copy_dir_flat(&dist_dir.join("mobile-icons"), &mobile_dist_dir.join("mobile-icons"));
    copy_matching(&dist_dir, &mobile_dist_dir, "workbox-", ".js");
}

fn copy_dir_flat(src: &Path, dest: &Path) {
    let Ok(entries) = fs::read_dir(src) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_file() {
            if let Some(name) = path.file_name() {
                let _ = fs::copy(&path, dest.join(name));
            }
        }
    }
}

fn copy_matching(src: &Path, dest: &Path, prefix: &str, suffix: &str) {
    let Ok(entries) = fs::read_dir(src) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else { continue };
        if path.is_file() && name.starts_with(prefix) && name.ends_with(suffix) {
            let _ = fs::copy(&path, dest.join(name));
        }
    }
}

fn main() {
    sync_mobile_dist();
    tauri_build::build()
}
