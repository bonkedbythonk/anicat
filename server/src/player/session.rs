//! One running mpv and everything that happens while it plays: the IO half
//! of the player loop. The decisions are `policy::Tracker`'s.

use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anicat_core::ffi::{AnicatEngine, FfiCatalog, StreamRequest};
use serde_json::{json, Value};
use tokio::process::Command;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

use super::ipc::{self, IpcClient};
use super::policy::{self, Tracker};
use super::{mpv, PlayRequest, Snapshot};
use crate::writer::Writer;

/// After `quit`, how long mpv gets before it is killed. A quit it never
/// processes (stuck in a network read on a stalled piece) would otherwise
/// leave the stop request, and the tray's Quit, hanging.
const QUIT_GRACE: Duration = Duration::from_secs(3);

pub enum Cmd {
    Replace {
        url: String,
        request: PlayRequest,
        reply: oneshot::Sender<Result<(), String>>,
    },
    Quit,
}

pub struct Handle {
    pub cmd: mpsc::UnboundedSender<Cmd>,
    pub join: JoinHandle<()>,
}

enum Internal {
    Episodes {
        catalog: FfiCatalog,
        catalog_id: i64,
        list: Vec<(i64, bool)>,
    },
    Preloaded {
        generation: u64,
        episode: i64,
        url: String,
    },
}

/// Registry writes, in the order the ticks asked for them. Spawning one
/// task per write would not keep that order, and a later tick landing
/// before an earlier one moves the resume point backwards (see `writer.rs`).
enum Write {
    Progress(FfiCatalog, i64, i64, i64, i64),
    Completed(FfiCatalog, i64, i64),
}

struct Session {
    engine: Arc<AnicatEngine>,
    writer: Writer,
    snapshot: Arc<Mutex<Snapshot>>,
    ipc: IpcClient,
    tracker: Tracker,
    title: Option<String>,
    prefer_dub: bool,
    internal_tx: mpsc::UnboundedSender<Internal>,
    writes: mpsc::UnboundedSender<Write>,
}

pub async fn start(
    engine: Arc<AnicatEngine>,
    writer: Writer,
    snapshot: Arc<Mutex<Snapshot>>,
    url: String,
    request: PlayRequest,
) -> Result<Handle, String> {
    let binary = mpv::locate().ok_or_else(|| mpv::NOT_FOUND.to_string())?;
    let endpoint = ipc::endpoint(&crate::config::data_dir());
    remove_socket(&endpoint);
    let config_dir = mpv::bundled_config_dir();
    let user_config = mpv::user_config();
    let extra = mpv::extra_args();
    let media_title = media_title(&request);
    let args = mpv::args(&mpv::Launch {
        url: &url,
        start_seconds: request.start_seconds,
        media_title: &media_title,
        ipc: &endpoint,
        config_dir: config_dir.as_deref(),
        user_config: user_config.as_deref(),
        extra: &extra,
    });
    log::info!("[player] spawning {} {:?}", binary.display(), args);
    let mut child = Command::new(&binary)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        // The server exiting any way but through `stop` must not leave a
        // player behind reading from a range server that is gone.
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("could not start mpv at {}: {e}", binary.display()))?;
    #[cfg(windows)]
    bind_to_server_lifetime(&child);

    let (ipc, mut events) = match IpcClient::connect(&endpoint, || matches!(child.try_wait(), Ok(None))).await {
        Ok(pair) => pair,
        Err(e) => {
            let _ = child.kill().await;
            remove_socket(&endpoint);
            return Err(e);
        }
    };
    for (id, name) in [(1, "time-pos"), (2, "duration"), (3, "pause"), (4, "playlist-pos")] {
        if let Err(e) = ipc.command(json!(["observe_property", id, name])).await {
            log::warn!("[player] observe_property {name} failed: {e}");
        }
    }

    let mut tracker = Tracker::new(request.catalog, request.catalog_id, request.episode, url);
    // A local stream can finish loading before the connect retry lands, and
    // its `file-loaded` went to nobody. `time-pos` only answers once a file
    // is loaded, so a success here stands in for the missed event; without
    // it the episode waited for a file that had already arrived and nothing
    // was ever recorded.
    if ipc.command(json!(["get_property", "time-pos"])).await.is_ok() {
        tracker.file_loaded(Instant::now());
    }

    let (internal_tx, mut internal_rx) = mpsc::unbounded_channel();
    let (writes_tx, writes_rx) = mpsc::unbounded_channel();
    let write_task = tokio::spawn(run_writes(writer.clone(), writes_rx));
    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel();

    let mut session = Session {
        engine,
        writer,
        snapshot,
        ipc,
        tracker,
        title: request.title.clone(),
        prefer_dub: request.prefer_dub,
        internal_tx,
        writes: writes_tx,
    };
    session.fetch_episodes();
    session.publish();

    let join = tokio::spawn(async move {
        let mut events_open = true;
        let mut cmds_open = true;
        let mut kill_at: Option<tokio::time::Instant> = None;
        loop {
            let kill_sleep = async {
                match kill_at {
                    Some(at) => tokio::time::sleep_until(at).await,
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                status = child.wait() => {
                    log::info!("[player] mpv exited: {status:?}");
                    break;
                }
                ev = events.recv(), if events_open => match ev {
                    Some(ev) => session.on_event(ev).await,
                    None => events_open = false,
                },
                cmd = cmd_rx.recv(), if cmds_open => match cmd {
                    Some(Cmd::Replace { url, request, reply }) => {
                        let _ = reply.send(session.replace(url, request).await);
                    }
                    Some(Cmd::Quit) | None => {
                        cmds_open = false;
                        let ipc = session.ipc.clone();
                        tokio::spawn(async move { let _ = ipc.command(json!(["quit"])).await; });
                        kill_at = Some(tokio::time::Instant::now() + QUIT_GRACE);
                    }
                },
                Some(msg) = internal_rx.recv() => session.on_internal(msg).await,
                _ = kill_sleep => {
                    log::warn!("[player] mpv ignored quit, killing it");
                    let _ = child.kill().await;
                    kill_at = None;
                }
            }
        }
        session.finish(write_task).await;
        remove_socket(&endpoint);
    });
    Ok(Handle { cmd: cmd_tx, join })
}

impl Session {
    async fn on_event(&mut self, ev: Value) {
        match ev.get("event").and_then(Value::as_str) {
            Some("file-loaded") => self.tracker.file_loaded(Instant::now()),
            Some("property-change") => {
                let data = ev.get("data");
                match ev.get("name").and_then(Value::as_str) {
                    Some("time-pos") => {
                        if let Some(t) = data.and_then(Value::as_f64) {
                            let actions = self.tracker.time_pos(t, Instant::now());
                            self.perform(actions);
                        }
                    }
                    Some("duration") => self.tracker.set_duration(data.and_then(Value::as_f64)),
                    Some("pause") => {
                        if let Some(p) = data.and_then(Value::as_bool) {
                            self.tracker.set_paused(p);
                        }
                    }
                    Some("playlist-pos") => {
                        let pos = data.and_then(Value::as_i64).unwrap_or(-1);
                        // Record where the outgoing episode ended before the
                        // tracker forgets it.
                        let outgoing = (self.tracker.episode(), self.tracker.final_record());
                        if let Some(entry) = self.tracker.playlist_pos(pos) {
                            if let (ep, Some((stop, dur))) = outgoing {
                                let _ = self.writes.send(Write::Progress(
                                    self.tracker.catalog,
                                    self.tracker.catalog_id,
                                    ep,
                                    stop,
                                    dur,
                                ));
                            }
                            log::info!("[player] mpv advanced to episode {}", entry.episode);
                            self.claim_pin(entry.episode);
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
        self.publish();
    }

    fn perform(&mut self, actions: policy::Actions) {
        let (catalog, id, episode) = (self.tracker.catalog, self.tracker.catalog_id, self.tracker.episode());
        if let Some((stop, dur)) = actions.record {
            let _ = self.writes.send(Write::Progress(catalog, id, episode, stop, dur));
        }
        if actions.mark_watched {
            log::info!("[player] {catalog:?}:{id} episode {episode} passed 85%, marking watched");
            let _ = self.writes.send(Write::Completed(catalog, id, episode));
            if catalog == FfiCatalog::Anilist {
                tokio::spawn(advance_anilist(self.engine.clone(), self.writer.clone(), id, episode));
            }
        }
        if actions.advance {
            log::info!("[player] episode {episode} is at its end, advancing mpv's playlist");
            let ipc = self.ipc.clone();
            tokio::spawn(async move {
                if let Err(e) = ipc.command(json!(["playlist-next", "force"])).await {
                    log::warn!("[player] playlist-next failed: {e}");
                }
            });
        }
        if let Some(next) = actions.preload {
            let req = StreamRequest {
                catalog,
                catalog_id: id,
                episode: next,
                title: self.title.clone(),
                prefer_dub: self.prefer_dub,
                chosen_name: None,
                resume_fraction: None,
                preload: true,
            };
            let (engine, tx, generation) = (self.engine.clone(), self.internal_tx.clone(), self.tracker.generation);
            log::info!("[player] preloading {catalog:?}:{id} episode {next}");
            tokio::spawn(async move {
                match engine.resolve_stream(req).await {
                    Ok(handle) => {
                        let _ = tx.send(Internal::Preloaded { generation, episode: next, url: handle.url });
                    }
                    // Costs nothing visible: mpv ends at this episode, and
                    // the next play resolves cold as it would have anyway.
                    Err(e) => log::warn!("[player] episode {next} not preloaded: {e}"),
                }
            });
        }
    }

    async fn on_internal(&mut self, msg: Internal) {
        match msg {
            Internal::Episodes { catalog, catalog_id, list } => {
                if self.tracker.catalog == catalog && self.tracker.catalog_id == catalog_id {
                    self.tracker.set_episodes(list);
                }
            }
            Internal::Preloaded { generation, episode, url } => {
                if !self.tracker.accept_preload(generation, episode, url.clone()) {
                    log::info!("[player] preload of episode {episode} arrived for an episode no longer playing");
                    return;
                }
                let options = json!({ "force-media-title": self.title_for(episode) });
                match self.ipc.command(json!(["loadfile", url, "append", -1, options])).await {
                    Ok(_) => log::info!("[player] episode {episode} appended to mpv's playlist"),
                    Err(e) => {
                        log::warn!("[player] mpv refused to append episode {episode}: {e}");
                        self.tracker.retract_append(episode);
                    }
                }
            }
        }
        self.publish();
    }

    async fn replace(&mut self, url: String, request: PlayRequest) -> Result<(), String> {
        let mut options = json!({ "force-media-title": media_title(&request) });
        if request.start_seconds > 0.0 {
            options["start"] = json!(format!("{:.0}", request.start_seconds));
        }
        self.ipc
            .command(json!(["loadfile", url.clone(), "replace", -1, options]))
            .await
            .map_err(|e| format!("mpv did not take the new file: {e}"))?;
        // The outgoing episode's position, before the tracker forgets it.
        if let Some((stop, dur)) = self.tracker.final_record() {
            let _ = self.writes.send(Write::Progress(
                self.tracker.catalog,
                self.tracker.catalog_id,
                self.tracker.episode(),
                stop,
                dur,
            ));
        }
        let title_changed = self
            .tracker
            .replace(request.catalog, request.catalog_id, request.episode, url);
        self.title = request.title;
        self.prefer_dub = request.prefer_dub;
        if title_changed {
            self.fetch_episodes();
        }
        self.publish();
        Ok(())
    }

    /// A playlist advance is a play nobody asked the engine for: the pin
    /// still names the previous episode, and the next preload into the same
    /// pack could evict the file mpv is now reading. A non-preload resolve of
    /// an episode already in the reuse cache moves the pin and costs a lookup.
    fn claim_pin(&self, episode: i64) {
        let req = StreamRequest {
            catalog: self.tracker.catalog,
            catalog_id: self.tracker.catalog_id,
            episode,
            title: self.title.clone(),
            prefer_dub: self.prefer_dub,
            chosen_name: None,
            resume_fraction: None,
            preload: false,
        };
        let engine = self.engine.clone();
        tokio::spawn(async move {
            if let Err(e) = engine.resolve_stream(req).await {
                log::warn!("[player] could not move the playing-file pin to episode {episode}: {e}");
            }
        });
    }

    fn fetch_episodes(&self) {
        let (catalog, catalog_id) = (self.tracker.catalog, self.tracker.catalog_id);
        if !matches!(catalog, FfiCatalog::Anilist | FfiCatalog::TmdbTv) {
            return;
        }
        let (engine, tx) = (self.engine.clone(), self.internal_tx.clone());
        tokio::spawn(async move {
            let detail = if catalog == FfiCatalog::Anilist {
                engine.media_detail(catalog_id, false).await
            } else {
                engine.cinema_detail(catalog, catalog_id).await
            };
            match detail {
                Ok(d) => {
                    let list = d.episodes.iter().map(|e| (e.number as i64, e.is_aired)).collect();
                    let _ = tx.send(Internal::Episodes { catalog, catalog_id, list });
                }
                Err(e) => log::warn!("[player] no episode list for {catalog:?}:{catalog_id}, no auto-next: {e}"),
            }
        });
    }

    fn title_for(&self, episode: i64) -> String {
        title_text(self.title.as_deref(), self.tracker.catalog, episode)
    }

    fn publish(&self) {
        let t = &self.tracker;
        let snap = Snapshot {
            active: true,
            catalog: Some(t.catalog),
            catalog_id: Some(t.catalog_id),
            episode: Some(t.episode()),
            title: self.title.clone(),
            position: t.position,
            duration: t.duration,
            paused: t.paused,
            next_ready: t.next_ready(),
        };
        if let Ok(mut s) = self.snapshot.lock() {
            *s = snap;
        }
    }

    async fn finish(self, write_task: JoinHandle<()>) {
        if let Some((stop, dur)) = self.tracker.final_record() {
            let _ = self.writes.send(Write::Progress(
                self.tracker.catalog,
                self.tracker.catalog_id,
                self.tracker.episode(),
                stop,
                dur,
            ));
        }
        if let Ok(mut s) = self.snapshot.lock() {
            *s = Snapshot::default();
        }
        let engine = self.engine.clone();
        // Closing the queue lets the write task drain and end, so the final
        // position is in the registry before the session is paused.
        drop(self);
        let _ = write_task.await;
        log::info!("[player] playback stopped, pausing the torrent session");
        engine.playback_stopped().await;
    }
}

async fn run_writes(writer: Writer, mut rx: mpsc::UnboundedReceiver<Write>) {
    while let Some(w) = rx.recv().await {
        let result = match w {
            Write::Progress(c, id, ep, stop, dur) => writer.record_progress(c, id, ep, stop, dur).await,
            Write::Completed(c, id, ep) => writer.mark_episode_completed(c, id, ep).await,
        };
        if let Err(e) = result {
            log::warn!("[player] registry write failed: {}", e.message);
        }
    }
}

/// `AppModel.advanceAniListProgress` without a detail page: read the list
/// entry from AniList first. Re-sending a progress the list has already
/// passed drags it backwards on a rewatch. Attempted signed out too, as the
/// Mac does; it fails there and is only logged.
async fn advance_anilist(engine: Arc<AnicatEngine>, writer: Writer, catalog_id: i64, episode: i64) {
    let detail = match engine.media_detail(catalog_id, false).await {
        Ok(d) => d,
        Err(e) => {
            log::warn!("[player] AniList progress not advanced for {catalog_id}: {e}");
            return;
        }
    };
    let listed = i64::from(detail.list_progress.unwrap_or(0));
    if listed >= episode {
        return;
    }
    let count = detail.episode_count.or(detail.chapter_count).map(i64::from);
    let (progress, status) = policy::list_entry_update(episode, count, detail.list_status.as_deref());
    match writer.update_list_entry(catalog_id, status, None, Some(progress)).await {
        Ok(()) => log::info!("[player] AniList progress for {catalog_id} advanced to {progress}"),
        Err(e) => log::warn!("[player] AniList progress not advanced for {catalog_id}: {}", e.message),
    }
}

fn media_title(request: &PlayRequest) -> String {
    title_text(request.title.as_deref(), request.catalog, request.episode)
}

fn title_text(title: Option<&str>, catalog: FfiCatalog, episode: i64) -> String {
    let title = title.filter(|t| !t.trim().is_empty()).unwrap_or("Anicat");
    if catalog == FfiCatalog::TmdbMovie {
        title.to_string()
    } else {
        format!("{title} - Episode {episode}")
    }
}

#[cfg(unix)]
fn remove_socket(endpoint: &std::path::Path) {
    let _ = std::fs::remove_file(endpoint);
}

/// A named pipe goes away with its last handle; there is no file to remove.
#[cfg(windows)]
fn remove_socket(_endpoint: &std::path::Path) {}

/// Puts mpv in a job object that dies with this process. `kill_on_drop` only
/// runs when the server unwinds normally; Task Manager, a crash, or the
/// installer's `Stop-Process` end the server without dropping anything, and
/// mpv would stay open on a stream whose server is gone. The job handle is
/// deliberately leaked: closing it is what kills the children, and the OS
/// closes it when this process exits, however it exits.
#[cfg(windows)]
fn bind_to_server_lifetime(child: &tokio::process::Child) {
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    let Some(process) = child.raw_handle() else { return };
    unsafe {
        let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        if job.is_null() {
            log::warn!("[player] could not create a job object; mpv may outlive a crashed server");
            return;
        }
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let ok = SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &info as *const _ as *const core::ffi::c_void,
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        );
        if ok == 0 || AssignProcessToJobObject(job, process as _) == 0 {
            log::warn!("[player] could not bind mpv to the server's lifetime; mpv may outlive a crashed server");
        }
    }
}
