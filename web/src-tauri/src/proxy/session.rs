//! Per-user auth for the headless multi-user server (Stage 2). Same
//! philosophy as `mobile_auth.rs`'s single shared PIN — recompute a token
//! from live DB state on every request, no server-side session store, no
//! expiry — just scoped per registered row instead of one shared config
//! value. The primary boundary is Tailscale (only invited devices can reach
//! this server at all); on top of that, `login` is rate-limited per client IP
//! (see `throttle`) so an invited-but-malicious friend can't script-guess
//! another friend's PIN. Behind `tailscale serve` every request's TCP peer is
//! loopback, so the throttle keys on the forwarded client IP — see
//! `throttle::client_ip`.
//!
//! Unlike `require_mobile_auth`, there is no loopback bypass: multi-user
//! mode has no legitimate same-host caller (mpv doesn't run in the headless
//! binary that would ever enable this mode).

use axum::{
    extract::{ConnectInfo, FromRequestParts, Request, State},
    http::{request::Parts, HeaderMap, StatusCode},
    middleware::Next,
    response::Response,
    Json,
};
use std::net::SocketAddr;
use serde::{Deserialize, Serialize};

use super::secret::{derive_token, tokens_match};
use super::server::ProxyState;

/// Keyed on the install secret for the same reason as `mobile_auth::pin_token`:
/// without it, the token was a plain hash of `user_id:pin` over a numeric PIN,
/// so a leaked token gave up that friend's PIN to an offline search.
pub(crate) fn user_token(secret: &str, user_id: i64, pin: &str) -> String {
    derive_token(secret, "user", &format!("{}:{}", user_id, pin))
}

#[derive(Deserialize)]
pub struct LoginBody {
    display_name: String,
    pin: String,
}

#[derive(Serialize)]
pub struct LoginResponse {
    token: String,
    user_id: i64,
    display_name: String,
}

pub async fn login(
    State(state): State<ProxyState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(body): Json<LoginBody>,
) -> Result<Json<LoginResponse>, StatusCode> {
    let ip = super::throttle::client_ip(addr.ip(), &headers);
    if state.login_throttle.check(ip).await.is_some() {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    let db = state.app_state.open_db().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let user = crate::registry::service::get_user_by_name(&db, &body.display_name)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    // Wrong name and wrong PIN are both a failed attempt — count them, and
    // return the same UNAUTHORIZED for each so the response can't be used to
    // probe which display names exist.
    let user = match user {
        Some(u) if u.pin == body.pin => u,
        _ => {
            state.login_throttle.record_failure(ip).await;
            return Err(StatusCode::UNAUTHORIZED);
        }
    };
    state.login_throttle.record_success(ip).await;
    let secret = super::secret::server_secret(&state.app_state.db_path);
    Ok(Json(LoginResponse {
        token: user_token(secret, user.id, &user.pin),
        user_id: user.id,
        display_name: user.display_name,
    }))
}

/// The authenticated caller, attached to request extensions by
/// `require_user_session` and pulled out by any handler that needs to know
/// which registered user is asking (to build a scoped `AppState` via
/// `AppState::scoped_for_user`, or to filter `user_id`-columned DB rows).
#[derive(Clone, Copy)]
pub struct AuthedUser(pub i64);

impl<S> FromRequestParts<S> for AuthedUser
where
    S: Send + Sync,
{
    type Rejection = StatusCode;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        parts
            .extensions
            .get::<AuthedUser>()
            .copied()
            .ok_or(StatusCode::UNAUTHORIZED)
    }
}

pub async fn require_user_session(
    State(state): State<ProxyState>,
    mut req: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let token = req
        .headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .ok_or(StatusCode::UNAUTHORIZED)?
        .to_string();

    let db = state.app_state.open_db().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let users = crate::registry::service::list_users(&db).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let secret = super::secret::server_secret(&state.app_state.db_path);
    let matched = users
        .into_iter()
        .find(|u| tokens_match(&user_token(secret, u.id, &u.pin), &token));

    match matched {
        Some(user) => {
            req.extensions_mut().insert(AuthedUser(user.id));
            Ok(next.run(req).await)
        }
        None => Err(StatusCode::UNAUTHORIZED),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: &str = "test-secret";

    #[test]
    fn user_token_is_deterministic_and_scoped_by_id() {
        assert_eq!(user_token(S, 1, "1234"), user_token(S, 1, "1234"));
        // Same PIN, different user id: must not collide.
        assert_ne!(user_token(S, 1, "1234"), user_token(S, 2, "1234"));
        // Same user id, different PIN: must not collide.
        assert_ne!(user_token(S, 1, "1234"), user_token(S, 1, "4321"));
    }

    #[test]
    fn a_token_cannot_be_derived_without_the_install_secret() {
        // A friend's leaked token must not be invertible to their PIN, which
        // a bare hash of "user_id:pin" over a numeric PIN plainly was.
        assert_ne!(user_token(S, 1, "1234"), user_token("another-secret", 1, "1234"));
    }
}
