//! HTTP range streaming of an in-progress torrent file to the player.
//! librqbit's `FileStream` reprioritizes pieces at the read position, so seeks
//! in mpv jump the download along with them.
//!
//! This has to be a loopback HTTP server rather than a path handed to the
//! player: the file on disk is sparse while the torrent is downloading, so
//! anything opening it directly reads holes. It also has to live *here*,
//! beside the librqbit `Session`, because a `FileStream` is a Rust object with
//! no representation on the other side of the FFI — a host that was handed
//! only `(torrent_id, file_id)` would have nothing to read bytes from.
//!
//! **The port is assigned by the OS and reported, never assumed.** The Tauri
//! build's Lua script hardcoded 13370 while the proxy only *preferred* it, so
//! whenever something else held that port the video played and every callback
//! went to a stranger. Binding :0 and returning the real port removes the
//! class of bug rather than the instance: there is no number for a caller to
//! guess wrong.

use std::sync::Arc;

use axum::{
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::Response,
    routing::get,
    Router,
};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use super::TorrentManager;

/// Bind a range server on loopback and return the port the OS gave it.
///
/// Loopback only: every caller is the player in this same app, and the server
/// hands out whatever file id it is asked for with no authentication of any
/// kind. Binding anything but 127.0.0.1 would publish the user's downloads to
/// the network.
pub async fn serve(manager: Arc<TorrentManager>) -> Result<u16, String> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .map_err(|e| format!("range server could not bind loopback: {e}"))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let app = Router::new()
        .route("/torrent-stream", get(torrent_stream_handler))
        .with_state(manager);
    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app).await {
            log::error!("torrent range server stopped: {e}");
        }
    });
    log::info!("torrent range server listening on 127.0.0.1:{port}");
    Ok(port)
}

#[derive(serde::Deserialize)]
pub struct StreamQuery {
    /// librqbit torrent id
    t: usize,
    /// file index inside the torrent
    f: usize,
}

fn error_response(status: StatusCode, msg: &str) -> Response {
    Response::builder()
        .status(status)
        .body(Body::from(msg.to_string()))
        .unwrap()
}

fn content_type_for(name: &str) -> &'static str {
    let lower = name.to_lowercase();
    if lower.ends_with(".mp4") || lower.ends_with(".m4v") {
        "video/mp4"
    } else if lower.ends_with(".webm") {
        "video/webm"
    } else if lower.ends_with(".ts") {
        "video/mp2t"
    } else if lower.ends_with(".avi") {
        "video/x-msvideo"
    } else {
        "video/x-matroska"
    }
}

/// Parse "bytes=start-end" / "bytes=start-" / "bytes=-suffix".
fn parse_range(headers: &HeaderMap, file_len: u64) -> Option<(u64, u64)> {
    let raw = headers.get(http::header::RANGE)?.to_str().ok()?;
    let spec = raw.strip_prefix("bytes=")?.split(',').next()?.trim();
    let (start_s, end_s) = spec.split_once('-')?;
    if start_s.is_empty() {
        let suffix: u64 = end_s.parse().ok()?;
        if suffix == 0 {
            return None;
        }
        let start = file_len.saturating_sub(suffix);
        return Some((start, file_len - 1));
    }
    let start: u64 = start_s.parse().ok()?;
    let end: u64 = if end_s.is_empty() {
        file_len - 1
    } else {
        end_s.parse::<u64>().ok()?.min(file_len - 1)
    };
    if start > end || start >= file_len {
        return None;
    }
    Some((start, end))
}

pub async fn torrent_stream_handler(
    State(manager): State<Arc<TorrentManager>>,
    Query(q): Query<StreamQuery>,
    headers: HeaderMap,
) -> Response {
    let session = match manager.session().await {
        Ok(s) => s,
        Err(e) => return error_response(StatusCode::SERVICE_UNAVAILABLE, &e),
    };
    let Some(handle) = session.get(q.t.into()) else {
        return error_response(StatusCode::NOT_FOUND, "torrent not found");
    };
    manager.spawn_stall_logger(&session, q.t);
    let file_info = handle.with_metadata(|m| {
        m.file_infos
            .get(q.f)
            .map(|f| (f.relative_filename.to_string_lossy().to_string(), f.len))
    });
    let Ok(Some((file_name, file_len))) = file_info else {
        return error_response(StatusCode::NOT_FOUND, "file not found in torrent");
    };
    if file_len == 0 {
        return error_response(StatusCode::NOT_FOUND, "empty file");
    }

    let range = parse_range(&headers, file_len);
    let (start, end) = range.unwrap_or((0, file_len - 1));
    let len = end - start + 1;

    let mut stream = match handle.stream(q.f) {
        Ok(s) => s,
        Err(e) => {
            return error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("stream open failed: {}", e),
            )
        }
    };
    if start > 0 {
        if let Err(e) = stream.seek(std::io::SeekFrom::Start(start)).await {
            return error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("seek failed: {}", e),
            );
        }
    }

    let reader = stream.take(len);
    let body = Body::from_stream(tokio_util::io::ReaderStream::with_capacity(
        reader,
        256 * 1024,
    ));

    let mut builder = Response::builder()
        .header(http::header::CONTENT_TYPE, content_type_for(&file_name))
        .header(http::header::ACCEPT_RANGES, "bytes")
        .header(http::header::CONTENT_LENGTH, len.to_string());
    builder = if range.is_some() {
        builder
            .status(StatusCode::PARTIAL_CONTENT)
            .header(
                http::header::CONTENT_RANGE,
                format!("bytes {}-{}/{}", start, end, file_len),
            )
    } else {
        builder.status(StatusCode::OK)
    };
    builder.body(body).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers_with_range(v: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert(http::header::RANGE, v.parse().unwrap());
        h
    }

    /// The gap this closes: `resolve_stream` returns a URL, and for a while
    /// nothing in the crate served it. Binding and answering proves the route
    /// exists on the port the engine reports — a 404 for a torrent that was
    /// never added is the handler running, not the server missing.
    #[tokio::test]
    async fn the_range_server_binds_loopback_and_answers_on_the_port_it_reports() {
        let mgr = std::sync::Arc::new(TorrentManager::with_cache_dir(
            std::env::temp_dir().join("anicat-stream-bind-test"),
        ));
        let port = serve(mgr).await.unwrap();
        assert_ne!(port, 0);

        let resp = reqwest::Client::new()
            .get(format!("http://127.0.0.1:{port}/torrent-stream?t=99&f=0"))
            .send()
            .await
            .expect("range server did not answer on the port it reported");
        assert_eq!(resp.status().as_u16(), 404);
        assert_eq!(resp.text().await.unwrap(), "torrent not found");
    }

    #[test]
    fn range_parsing() {
        let len = 1000;
        assert_eq!(parse_range(&HeaderMap::new(), len), None);
        assert_eq!(parse_range(&headers_with_range("bytes=0-499"), len), Some((0, 499)));
        assert_eq!(parse_range(&headers_with_range("bytes=500-"), len), Some((500, 999)));
        assert_eq!(parse_range(&headers_with_range("bytes=-100"), len), Some((900, 999)));
        assert_eq!(parse_range(&headers_with_range("bytes=0-99999"), len), Some((0, 999)));
        assert_eq!(parse_range(&headers_with_range("bytes=1000-"), len), None);
        assert_eq!(parse_range(&headers_with_range("bytes=9-3"), len), None);
    }
}

