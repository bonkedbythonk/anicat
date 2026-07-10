//! HTTP range streaming of an in-progress torrent file to mpv. librqbit's
//! FileStream reprioritizes pieces at the read position, so seeks in mpv jump
//! the download along with them.

use axum::{
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::Response,
};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use crate::proxy::server::ProxyState;

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
    State(state): State<ProxyState>,
    Query(q): Query<StreamQuery>,
    headers: HeaderMap,
) -> Response {
    let session = match state.app_state.torrent.session().await {
        Ok(s) => s,
        Err(e) => return error_response(StatusCode::SERVICE_UNAVAILABLE, &e),
    };
    let Some(handle) = session.get(q.t.into()) else {
        return error_response(StatusCode::NOT_FOUND, "torrent not found");
    };
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

