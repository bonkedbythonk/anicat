//! The player's own routes, merged into the main router by `main.rs`.

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};

use super::Snapshot;
use crate::state::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/player", get(player))
        .route("/api/player/stop", post(stop))
}

async fn player(State(s): State<AppState>) -> Json<Snapshot> {
    Json(s.player.snapshot())
}

async fn stop(State(s): State<AppState>) -> StatusCode {
    s.player.stop().await;
    StatusCode::NO_CONTENT
}
