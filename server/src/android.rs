//! Anicat for Android: the server crate as a library the app loads into its
//! own process. Kotlin starts the engine once (`Native.start`), loads the
//! page from the port it returns, and answers the one thing the engine asks
//! of it, showing the player: `MpvHost.startMpv` gets the arguments a desktop
//! mpv would have been started with. Empty off Android; `main.rs` is the
//! binary for everything else.
#![cfg(target_os = "android")]

#[path = "config.rs"]
mod config;
#[path = "error.rs"]
mod error;
#[path = "logging.rs"]
mod logging;
#[path = "player/mod.rs"]
mod player;
#[path = "routes.rs"]
mod routes;
#[path = "state.rs"]
mod state;
#[path = "version.rs"]
mod version;
#[path = "writer.rs"]
mod writer;

use std::sync::{Arc, Mutex, OnceLock};

use anicat_core::ffi::AnicatEngine;
use jni::objects::{GlobalRef, JClass, JObject, JString, JValue};
use jni::sys::jint;
use jni::{JNIEnv, JavaVM};
use tokio::sync::watch;

use crate::player::Player;
use crate::state::AppState;
use crate::writer::Writer;

/// Fixed so the page's origin, and the `localStorage` under it, is the same
/// on every launch. The successors are for a port something else holds.
const PREFERRED_PORT: u16 = 47111;
const PORT_FALLBACKS: u16 = 10;

/// The runtime lives as long as the process; `Native.start` returns and the
/// server keeps running on it.
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static HOST: OnceLock<Host> = OnceLock::new();
/// Whether the player screen is showing an mpv. `true` from the moment the
/// engine asks for one until Kotlin reports it gone.
static MPV_ALIVE: OnceLock<watch::Sender<bool>> = OnceLock::new();

struct Host {
    vm: JavaVM,
    /// The Kotlin `MpvHost`. A global reference cached at start: a tokio
    /// thread has no app class loader, so `FindClass` from one cannot see
    /// the app's own classes.
    object: GlobalRef,
}

fn mpv_alive_channel() -> &'static watch::Sender<bool> {
    MPV_ALIVE.get_or_init(|| watch::channel(false).0)
}

/// `Native.start(dataDir, host): Int`: the port the page is served on, or
/// -1 when the engine could not start. Blocks for the engine's startup, so
/// Kotlin calls it off the main thread. Once per process: a second engine on
/// the same registry and torrent cache evicts and pins under the first.
#[no_mangle]
pub extern "system" fn Java_com_anicat_android_Native_start(
    mut env: JNIEnv,
    _class: JClass,
    data_dir: JString,
    host: JObject,
) -> jint {
    if RUNTIME.get().is_some() {
        return -1;
    }
    let data_dir: String = match env.get_string(&data_dir) {
        Ok(s) => s.into(),
        Err(_) => return -1,
    };
    let (Ok(vm), Ok(object)) = (env.get_java_vm(), env.new_global_ref(&host)) else {
        return -1;
    };
    let _ = HOST.set(Host { vm, object });

    // `dirs` finds no home on Android and `temp_dir` is a folder the app
    // cannot write; both would fail the engine at startup.
    std::env::set_var("ANICAT_DATA_DIR", &data_dir);
    std::env::set_var("TMPDIR", format!("{data_dir}/tmp"));
    let _ = std::fs::create_dir_all(format!("{data_dir}/tmp"));

    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(r) => r,
        Err(_) => return -1,
    };
    let runtime = RUNTIME.get_or_init(|| runtime);
    match runtime.block_on(boot()) {
        Some(port) => port as jint,
        None => -1,
    }
}

/// `MpvHost` reports the player screen has closed or libmpv shut down.
#[no_mangle]
pub extern "system" fn Java_com_anicat_android_Native_mpvEnded(_env: JNIEnv, _class: JClass) {
    mpv_alive_channel().send_replace(false);
}

/// The same start `main.rs` does, minus the browser, the tray and the
/// shutdown: the process is the lifetime.
async fn boot() -> Option<u16> {
    let data_dir = config::data_dir();
    let log_redirected = logging::start(&data_dir);
    let token = config::load_token(&data_dir);
    let proxy = config::tmdb_proxy();
    let engine = match AnicatEngine::new(data_dir.to_string_lossy().into_owned(), token.clone(), None, proxy.clone()) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("engine failed to start: {e}");
            return None;
        }
    };
    log::info!(
        "Anicat server {} on android {}, data at {}, signed in: {}, TMDB proxy: {}",
        version::current(),
        std::env::consts::ARCH,
        data_dir.display(),
        token.is_some(),
        proxy.is_some(),
    );
    {
        let engine = engine.clone();
        tokio::spawn(async move { engine.warm_up().await });
    }
    let (listener, port) = bind().await?;
    let writer = Writer::spawn(engine.clone());
    let http = reqwest::Client::builder()
        .user_agent(format!("Anicat-Server/{} (+https://github.com/bonkedbythonk/anicat)", version::current()))
        .build()
        .expect("reqwest client");
    let prefs = Arc::new(player::prefs::PrefsStore::load(&data_dir));
    let player = Arc::new(Player::new(engine.clone(), writer.clone(), prefs, http.clone()));
    let state = AppState {
        engine,
        writer,
        player,
        data_dir,
        port,
        log_redirected,
        token: Arc::new(Mutex::new(token)),
        http,
    };
    let app = routes::router(state.clone()).merge(player::routes::router().with_state(state));
    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app).await {
            log::error!("server stopped: {e}");
        }
    });
    log::info!("listening on http://127.0.0.1:{port}/");
    Some(port)
}

/// Loopback only, as on desktop: anything wider publishes the watch history
/// and the download cache to the network.
async fn bind() -> Option<(tokio::net::TcpListener, u16)> {
    for port in PREFERRED_PORT..=PREFERRED_PORT + PORT_FALLBACKS {
        match tokio::net::TcpListener::bind(("127.0.0.1", port)).await {
            Ok(l) => return Some((l, port)),
            Err(e) => log::warn!("127.0.0.1:{port} unavailable: {e}"),
        }
    }
    log::error!("no free port in 127.0.0.1:{PREFERRED_PORT}..={}", PREFERRED_PORT + PORT_FALLBACKS);
    None
}

/// Shows the player and starts libmpv in it with `args`. Returns once the
/// request is made; the IPC socket among the arguments is what says mpv is up.
pub fn start_mpv(args: &[String]) -> Result<(), String> {
    mpv_alive_channel().send_replace(true);
    let result = call_start_mpv(args);
    if result.is_err() {
        mpv_alive_channel().send_replace(false);
    }
    result
}

fn call_start_mpv(args: &[String]) -> Result<(), String> {
    let host = HOST.get().ok_or("the app did not register a player host")?;
    // Attached for the duration of the call: the caller is a tokio thread.
    let mut env = host.vm.attach_current_thread().map_err(|e| e.to_string())?;
    let build = |env: &mut JNIEnv| -> jni::errors::Result<()> {
        let array = env.new_object_array(args.len() as i32, "java/lang/String", JObject::null())?;
        for (i, a) in args.iter().enumerate() {
            let s = env.new_string(a)?;
            env.set_object_array_element(&array, i as i32, s)?;
        }
        env.call_method(&host.object, "startMpv", "([Ljava/lang/String;)V", &[JValue::Object(&array)])?;
        Ok(())
    };
    build(&mut env).map_err(|e| {
        // A pending Kotlin exception aborts the next JNI call if left set.
        let _ = env.exception_clear();
        format!("MpvHost.startMpv: {e}")
    })
}

/// Asks the player screen to close; libmpv is in this process, so there is
/// nothing to signal.
pub fn kill_mpv() {
    let Some(host) = HOST.get() else { return };
    let Ok(mut env) = host.vm.attach_current_thread() else { return };
    if let Err(e) = env.call_method(&host.object, "killMpv", "()V", &[]) {
        let _ = env.exception_clear();
        log::warn!("[player] MpvHost.killMpv: {e}");
    }
}

pub fn mpv_alive() -> bool {
    *mpv_alive_channel().borrow()
}

/// Resolves when the player screen has gone.
pub async fn mpv_ended() {
    let mut rx = mpv_alive_channel().subscribe();
    let _ = rx.wait_for(|alive| !*alive).await;
}
