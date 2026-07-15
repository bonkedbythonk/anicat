//! Anti-accidental-entry gate for the LAN-facing mobile PWA.
//!
//! This is intentionally not hardened security: the app runs on a trusted
//! home network, and the goal is only to stop someone (a parent, a sibling)
//! from stumbling into it, not to withstand an attacker already on the LAN.
//! The PIN is stored and compared in plaintext, and the "token" a client
//! holds is nothing more than sha256(pin) — recomputed from the live config
//! on every request. There is no server-side session store or expiry:
//! changing the PIN in Settings instantly invalidates every previously
//! issued token, for free, since they simply stop matching the new hash.

use axum::{
    extract::{ConnectInfo, Request, State},
    http::{HeaderMap, StatusCode},
    middleware::Next,
    response::Response,
    Json,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::net::SocketAddr;

use super::server::ProxyState;

pub(crate) fn pin_token(pin: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(pin.as_bytes());
    format!("{:x}", hasher.finalize())
}

#[derive(Deserialize)]
pub struct AuthBody {
    pin: String,
}

#[derive(Serialize)]
pub struct AuthResponse {
    token: String,
}

pub async fn authenticate(
    State(state): State<ProxyState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(body): Json<AuthBody>,
) -> Result<Json<AuthResponse>, StatusCode> {
    let ip = super::throttle::client_ip(addr.ip(), &headers);
    if state.login_throttle.check(ip).await.is_some() {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    let cfg = state.app_state.config.read().await;
    if !cfg.mobile.lan_access_enabled {
        return Err(StatusCode::FORBIDDEN);
    }
    let token = match &cfg.mobile.pin {
        Some(configured) if !configured.is_empty() && configured == &body.pin => {
            Some(pin_token(configured))
        }
        _ => None,
    };
    drop(cfg);
    match token {
        Some(token) => {
            state.login_throttle.record_success(ip).await;
            Ok(Json(AuthResponse { token }))
        }
        None => {
            state.login_throttle.record_failure(ip).await;
            Err(StatusCode::UNAUTHORIZED)
        }
    }
}

#[derive(Serialize)]
pub struct LanInfo {
    lan_ip: String,
    port: u16,
    /// Tells the PWA's login screen which flow to show: the single shared
    /// PIN (`/mobile-api/auth`) or per-user login
    /// (`/mobile-api/session/login`, populated from `/mobile-api/users/list-names`).
    multi_user: bool,
}

/// Unauthenticated on purpose — a client needs this before it has a token
/// (it's just informational: what LAN IP to type into the phone, and which
/// login flow to render). Called directly from the desktop Settings page
/// too, whose Tauri webview origin differs from this server's
/// (127.0.0.1:13370) — without an explicit CORS header here, the request
/// still succeeds server-side (nothing to log) but the browser silently
/// discards the response, so `fetch()` in Settings just sees a rejected
/// promise.
pub async fn lan_info(State(state): State<ProxyState>) -> impl axum::response::IntoResponse {
    let multi_user = state.app_state.config.read().await.general.multi_user;
    (
        [(axum::http::header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")],
        Json(LanInfo {
            lan_ip: local_lan_ip().unwrap_or_else(|| "127.0.0.1".to_string()),
            port: state.proxy_port,
            multi_user,
        }),
    )
}

fn local_lan_ip() -> Option<String> {
    // Doesn't actually send traffic — connect() on a UDP socket just picks
    // the local interface/address the OS would use to reach that target,
    // which is a standard trick for finding "our" LAN IP without depending
    // on any specific interface name.
    use std::net::UdpSocket;
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    socket.local_addr().ok().map(|a| a.ip().to_string())
}

pub(crate) fn is_authorized(configured_pin: Option<&str>, provided_token: Option<&str>) -> bool {
    match (configured_pin, provided_token) {
        (Some(pin), Some(token)) if !pin.is_empty() => pin_token(pin) == token,
        _ => false,
    }
}

/// Requests from the machine itself (mpv's Lua script, always same-host) skip
/// the PIN check entirely — this keeps the existing desktop `/player/*` flow
/// working exactly as it did before the mobile feature existed. Anything
/// arriving from elsewhere on the LAN must carry a valid bearer token.
///
/// The bypass only applies when `app_handle` is `Some` — i.e. the desktop
/// build, where a loopback caller can only be mpv's own Lua script. The
/// headless `anicat-server` binary always has `app_handle: None` and never
/// runs mpv, so there is no legitimate same-host caller to exempt there;
/// treating every request as loopback-trusted regardless of origin would be
/// especially dangerous if this process ever sat behind a reverse proxy
/// forwarding from 127.0.0.1, since that would silently defeat the PIN gate
/// for every real client.
pub async fn require_mobile_auth(
    State(state): State<ProxyState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    mut req: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    // Single-PIN mode has no concept of distinct users — insert the same
    // desktop sentinel (0) every downstream handler that calls
    // AppState::scoped_for_user already treats as "not a real second
    // identity," so handlers can use the AuthedUser extractor uniformly
    // whether multi-user mode is on or not.
    req.extensions_mut().insert(super::session::AuthedUser(0));

    if state.app_handle.is_some() && addr.ip().is_loopback() {
        return Ok(next.run(req).await);
    }

    let cfg = state.app_state.config.read().await;
    if !cfg.mobile.lan_access_enabled {
        return Err(StatusCode::FORBIDDEN);
    }
    let configured_pin = cfg.mobile.pin.clone();
    drop(cfg);

    let token = req
        .headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "));

    if is_authorized(configured_pin.as_deref(), token) {
        Ok(next.run(req).await)
    } else {
        Err(StatusCode::UNAUTHORIZED)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pin_token_is_deterministic_and_pin_specific() {
        assert_eq!(pin_token("1234"), pin_token("1234"));
        assert_ne!(pin_token("1234"), pin_token("4321"));
    }

    #[test]
    fn rejects_when_no_pin_configured() {
        assert!(!is_authorized(None, Some(&pin_token("1234"))));
        assert!(!is_authorized(Some(""), Some(&pin_token("1234"))));
    }

    #[test]
    fn rejects_missing_or_wrong_token() {
        assert!(!is_authorized(Some("1234"), None));
        assert!(!is_authorized(Some("1234"), Some("not-a-real-token")));
        assert!(!is_authorized(Some("1234"), Some(&pin_token("4321"))));
    }

    #[test]
    fn accepts_matching_token() {
        assert!(is_authorized(Some("1234"), Some(&pin_token("1234"))));
    }

    #[test]
    fn changing_pin_invalidates_old_token() {
        let old_token = pin_token("1234");
        // PIN changed in Settings — the old token no longer matches.
        assert!(!is_authorized(Some("5678"), Some(&old_token)));
    }
}
