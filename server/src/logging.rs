//! `anicat.log` in the data directory, one per launch, three earlier
//! launches kept as `.1` to `.3`. Mirrors `AnicatApple/.../AppLog.swift`.
//!
//! core's `env_logger` writes to stderr, and a Windows build with the
//! `windows` subsystem (or a Mac binary started from launchd) has stderr
//! attached to nothing: every `[resolve]` timing line a bug report needs
//! would be dropped. Pointing the process's own stdout and stderr at the
//! file catches every writer at once without any of them knowing.

use std::io::IsTerminal;
use std::path::{Path, PathBuf};

const KEPT_LAUNCHES: u32 = 3;

pub fn log_path(data_dir: &Path) -> PathBuf {
    data_dir.join("anicat.log")
}

/// Rotates, then redirects stdout and stderr to the log when stderr is not
/// a terminal. Returns whether it redirected.
///
/// Must run before `AnicatEngine::new`, which installs `env_logger`;
/// anything said before the redirect is not recoverable.
pub fn start(data_dir: &Path) -> bool {
    let _ = std::fs::create_dir_all(data_dir);
    rotate(data_dir);
    let file = match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path(data_dir))
    {
        Ok(f) => f,
        Err(_) => return false,
    };
    if std::io::stderr().is_terminal() {
        // Run from a terminal the output stays there. The file still exists
        // so the debug report has something to point at.
        use std::io::Write;
        let mut file = file;
        let _ = writeln!(file, "stderr is a terminal; process output went there, not here");
        return false;
    }
    redirect_std(file)
}

fn rotate(data_dir: &Path) {
    let name = |i: u32| data_dir.join(format!("anicat.log.{i}"));
    let _ = std::fs::remove_file(name(KEPT_LAUNCHES));
    for i in (1..KEPT_LAUNCHES).rev() {
        let _ = std::fs::rename(name(i), name(i + 1));
    }
    let _ = std::fs::rename(log_path(data_dir), name(1));
}

#[cfg(unix)]
fn redirect_std(file: std::fs::File) -> bool {
    use std::os::fd::AsRawFd;
    let fd = file.as_raw_fd();
    // SAFETY: dup2 onto the process's own standard descriptors with a valid
    // open fd. `file` is dropped afterwards; 1 and 2 hold their own copies.
    unsafe { libc::dup2(fd, 1) >= 0 && libc::dup2(fd, 2) >= 0 }
}

/// Win32 has no descriptor table to dup onto. Rust's std looks up
/// `GetStdHandle` on every write to stdout and stderr, so replacing the
/// handles is enough for env_logger and every `eprintln!`. The handle is
/// leaked on purpose: closing it would leave both pointing at nothing.
#[cfg(windows)]
fn redirect_std(file: std::fs::File) -> bool {
    use std::os::windows::io::IntoRawHandle;
    use windows_sys::Win32::System::Console::{SetStdHandle, STD_ERROR_HANDLE, STD_OUTPUT_HANDLE};
    let handle = file.into_raw_handle();
    // SAFETY: a valid, owned file handle that is never closed.
    unsafe {
        SetStdHandle(STD_OUTPUT_HANDLE, handle as _) != 0
            && SetStdHandle(STD_ERROR_HANDLE, handle as _) != 0
    }
}

/// The last `lines` lines of the current log, for the debug report.
pub fn tail(data_dir: &Path, lines: usize) -> String {
    let text = match std::fs::read(log_path(data_dir)) {
        Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
        Err(e) => return format!("(log unreadable: {e})"),
    };
    let all: Vec<&str> = text.lines().filter(|l| !is_librqbit_span_line(l)).collect();
    all[all.len().saturating_sub(lines)..].join("\n")
}

/// librqbit's tracing spans reach env_logger as bare `ERROR` records that
/// carry only the span name and its fields (`manage_peer; peer="1.2.3.4:5"`),
/// one per peer, past the `librqbit=warn` filter. Measured on the first
/// live play: 1259 of 1283 lines in the log, so a 200-line tail was nothing
/// but peer addresses. Dropped from the report only; the file keeps them.
fn is_librqbit_span_line(line: &str) -> bool {
    let Some((head, message)) = line.split_once("] ") else {
        return false;
    };
    if !head.contains(" ERROR ") || !head.contains(" librqbit") {
        return false;
    }
    let Some((name, fields)) = message.split_once(';') else {
        return false;
    };
    !name.is_empty()
        && name.chars().all(|c| c.is_ascii_lowercase() || c == '_')
        && fields.split_whitespace().all(|f| f.contains('='))
}

#[cfg(test)]
mod tests {
    use super::is_librqbit_span_line;

    #[test]
    fn drops_span_records_and_keeps_messages() {
        assert!(is_librqbit_span_line(
            r#"[2026-09-12T18:54:19.099Z ERROR librqbit::torrent_state::live] manage_peer; peer="187.15.162.31:47834""#
        ));
        assert!(is_librqbit_span_line(
            r#"[2026-09-12T18:53:29.348Z ERROR librqbit_dht::dht] find_node; target="2d72" addr="185.157.221.247:25401""#
        ));
        assert!(!is_librqbit_span_line(
            "[2026-09-12T18:54:14.938Z INFO  anicat_core::torrent] [resolve] torrent lookup media=anilist:154587 ep=1"
        ));
        assert!(!is_librqbit_span_line(
            "[2026-09-12T18:54:14.938Z ERROR librqbit::session] error adding torrent; reason: timed out"
        ));
    }
}
