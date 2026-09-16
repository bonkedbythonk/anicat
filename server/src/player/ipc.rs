//! mpv's JSON IPC: one JSON object per line, over a unix socket or a
//! Windows named pipe.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

/// How long to keep trying to connect after spawning mpv. mpv creates the
/// socket after reading its config, which on a cold Windows start with a
/// user config and scripts takes a noticeable fraction of a second.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const CONNECT_RETRY: Duration = Duration::from_millis(100);
/// A command mpv never answers would otherwise hold `play` open forever.
const REPLY_TIMEOUT: Duration = Duration::from_secs(5);

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, String>>>>>;
type BoxWrite = Box<dyn AsyncWrite + Send + Unpin>;

/// Sends commands. Events (property changes, `file-loaded`) arrive on the
/// receiver `connect` returns.
#[derive(Clone)]
pub struct IpcClient {
    write: Arc<tokio::sync::Mutex<BoxWrite>>,
    pending: Pending,
    next_id: Arc<AtomicU64>,
}

/// The endpoint for this server process. Named after the server's pid, not
/// mpv's: the name has to exist before mpv does.
#[cfg(windows)]
pub fn endpoint(_data_dir: &Path) -> PathBuf {
    PathBuf::from(format!(r"\\.\pipe\anicat-{}", std::process::id()))
}

/// A socket path is limited to 104 bytes on macOS (108 on Linux), and bind
/// fails past it with an error mpv only prints to its own terminal. A data
/// dir inside a deep checkout crosses that, so the temp dir is the fallback.
#[cfg(not(windows))]
pub fn endpoint(data_dir: &Path) -> PathBuf {
    let name = format!("anicat-mpv-{}.sock", std::process::id());
    let preferred = data_dir.join(&name);
    if preferred.as_os_str().len() < 100 {
        preferred
    } else {
        std::env::temp_dir().join(name)
    }
}

impl IpcClient {
    /// Connects, retrying while mpv starts. `alive` is polled between
    /// attempts so an mpv that exited on a bad argument fails fast rather
    /// than after the whole timeout.
    pub async fn connect(
        endpoint: &Path,
        mut alive: impl FnMut() -> bool,
    ) -> Result<(Self, mpsc::UnboundedReceiver<Value>), String> {
        let deadline = Instant::now() + CONNECT_TIMEOUT;
        loop {
            match open(endpoint).await {
                Ok((read, write)) => return Ok(Self::start(read, write)),
                Err(e) => {
                    if !alive() {
                        return Err("mpv exited before its IPC endpoint came up".into());
                    }
                    if Instant::now() >= deadline {
                        return Err(format!("could not connect to mpv at {}: {e}", endpoint.display()));
                    }
                    tokio::time::sleep(CONNECT_RETRY).await;
                }
            }
        }
    }

    fn start(
        read: Box<dyn AsyncRead + Send + Unpin>,
        write: BoxWrite,
    ) -> (Self, mpsc::UnboundedReceiver<Value>) {
        let pending: Pending = Arc::default();
        let (events_tx, events_rx) = mpsc::unbounded_channel();
        let reader_pending = pending.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(read).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(msg) = serde_json::from_str::<Value>(&line) else {
                    log::warn!("[player] unparseable IPC line: {line}");
                    continue;
                };
                if let Some(id) = msg.get("request_id").and_then(Value::as_u64) {
                    let waiter = reader_pending.lock().ok().and_then(|mut p| p.remove(&id));
                    if let Some(waiter) = waiter {
                        let result = match msg.get("error").and_then(Value::as_str) {
                            Some("success") | None => Ok(msg.get("data").cloned().unwrap_or(Value::Null)),
                            Some(err) => Err(err.to_string()),
                        };
                        let _ = waiter.send(result);
                    }
                    continue;
                }
                if msg.get("event").is_some() && events_tx.send(msg).is_err() {
                    break;
                }
            }
            // Wakes anyone still waiting on a reply: the connection is gone
            // and the reply with it.
            if let Ok(mut p) = reader_pending.lock() {
                p.clear();
            }
        });
        let client = Self {
            write: Arc::new(tokio::sync::Mutex::new(write)),
            pending,
            next_id: Arc::new(AtomicU64::new(1)),
        };
        (client, events_rx)
    }

    /// Sends `command` and waits for mpv's reply.
    pub async fn command(&self, command: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .map_err(|_| "IPC state poisoned".to_string())?
            .insert(id, tx);
        let mut line = serde_json::to_vec(&json!({ "command": command, "request_id": id }))
            .map_err(|e| e.to_string())?;
        line.push(b'\n');
        {
            let mut w = self.write.lock().await;
            if let Err(e) = async {
                w.write_all(&line).await?;
                w.flush().await
            }
            .await
            {
                self.forget(id);
                return Err(format!("IPC write failed: {e}"));
            }
        }
        match tokio::time::timeout(REPLY_TIMEOUT, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("mpv closed the IPC connection".into()),
            Err(_) => {
                self.forget(id);
                Err(format!("mpv did not answer {command} in time"))
            }
        }
    }

    fn forget(&self, id: u64) {
        if let Ok(mut p) = self.pending.lock() {
            p.remove(&id);
        }
    }
}

#[cfg(unix)]
async fn open(
    endpoint: &Path,
) -> std::io::Result<(Box<dyn AsyncRead + Send + Unpin>, BoxWrite)> {
    let stream = tokio::net::UnixStream::connect(endpoint).await?;
    let (r, w) = stream.into_split();
    Ok((Box::new(r), Box::new(w)))
}

#[cfg(windows)]
async fn open(
    endpoint: &Path,
) -> std::io::Result<(Box<dyn AsyncRead + Send + Unpin>, BoxWrite)> {
    // Not found until mpv creates the pipe, busy while another client holds
    // the instance; both are "retry" to the caller.
    let client = tokio::net::windows::named_pipe::ClientOptions::new().open(endpoint.as_os_str())?;
    let (r, w) = tokio::io::split(client);
    Ok((Box::new(r), Box::new(w)))
}
