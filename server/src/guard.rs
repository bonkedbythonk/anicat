//! Keeps a web page the viewer happens to have open from driving the API.
//!
//! The server binds loopback only, but a browser on the same machine can
//! still reach it, two ways. DNS rebinding points an attacker's hostname at
//! 127.0.0.1 after the page loads, which makes the API same-origin to that
//! page: it can then read `/api/viewer` and `/api/debug-report` and `POST`
//! `/api/token`. Its requests carry the attacker's hostname in `Host`. And a
//! plain cross-site form `POST` needs no rebinding at all: `/api/stop` takes
//! no body, so nothing makes the browser ask first. Those carry the right
//! `Host` and a foreign `Origin`.

use axum::extract::{Request, State};
use axum::http::{header, Method, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

/// Whether a request may reach the API.
///
/// A missing `Origin` is allowed: browsers always send one on a cross-site
/// `POST`, and refusing its absence would break curl and the instance probe
/// in `main.rs`.
fn allowed(method: &Method, host: Option<&str>, origin: Option<&str>, port: u16) -> bool {
    let Some(host) = host else { return false };
    let host = host.to_ascii_lowercase();
    if host != format!("127.0.0.1:{port}") && host != format!("localhost:{port}") {
        return false;
    }
    if method == Method::GET || method == Method::HEAD {
        return true;
    }
    match origin {
        None => true,
        Some(origin) => {
            let origin = origin.to_ascii_lowercase();
            origin == format!("http://127.0.0.1:{port}") || origin == format!("http://localhost:{port}")
        }
    }
}

pub async fn guard(State(port): State<u16>, request: Request, next: Next) -> Response {
    // Owned copies, and nothing borrowed from `request` alive across the
    // await below: a request body is `Send` but not `Sync`, so a held
    // reference makes the whole handler future non-`Send` and axum refuses it.
    let (ok, summary) = inspect(&request, port);
    if ok {
        return next.run(request).await;
    }
    log::warn!("refused {summary}");
    (StatusCode::FORBIDDEN, "forbidden").into_response()
}

fn inspect(request: &Request, port: u16) -> (bool, String) {
    let header = |name| request.headers().get(name).and_then(|v| v.to_str().ok());
    let (host, origin) = (header(header::HOST), header(header::ORIGIN));
    let summary = format!("{} {}: Host {host:?}, Origin {origin:?}", request.method(), request.uri().path());
    (allowed(request.method(), host, origin, port), summary)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PORT: u16 = 7777;

    #[test]
    fn the_page_served_from_loopback_is_allowed() {
        assert!(allowed(&Method::GET, Some("127.0.0.1:7777"), None, PORT));
        assert!(allowed(&Method::POST, Some("localhost:7777"), Some("http://localhost:7777"), PORT));
        assert!(allowed(&Method::POST, Some("127.0.0.1:7777"), Some("http://127.0.0.1:7777"), PORT));
    }

    #[test]
    fn a_rebound_hostname_is_refused() {
        assert!(!allowed(&Method::GET, Some("evil.example:7777"), None, PORT));
        assert!(!allowed(&Method::GET, Some("127.0.0.1.evil.example:7777"), None, PORT));
        assert!(!allowed(&Method::GET, Some("127.0.0.1"), None, PORT));
        assert!(!allowed(&Method::GET, None, None, PORT));
    }

    #[test]
    fn a_cross_site_post_is_refused_but_a_bare_one_is_not() {
        assert!(!allowed(&Method::POST, Some("127.0.0.1:7777"), Some("https://evil.example"), PORT));
        assert!(!allowed(&Method::POST, Some("127.0.0.1:7777"), Some("null"), PORT));
        assert!(!allowed(&Method::DELETE, Some("127.0.0.1:7777"), Some("http://127.0.0.1:9999"), PORT));
        assert!(allowed(&Method::POST, Some("127.0.0.1:7777"), None, PORT));
    }
}
