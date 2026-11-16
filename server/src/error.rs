//! The one error shape every route answers with.

use anicat_core::ffi::AnicatError;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

const ANILIST_DOWN: &str = "anilist_down:";

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub message: String,
    pub anilist_down: bool,
}

pub type ApiResult<T> = Result<T, ApiError>;

impl ApiError {
    pub fn new(status: StatusCode, message: impl Into<String>) -> Self {
        let message = message.into();
        // The marker is buried inside `AnicatError`'s Display ("network:
        // anilist_down:..."), not at the start. Matched anywhere and cut
        // off, so the page gets AniList's own sentence and a flag, rather
        // than showing an outage as a generic network error with a prefix
        // in it.
        match message.find(ANILIST_DOWN) {
            Some(at) => Self {
                status: StatusCode::SERVICE_UNAVAILABLE,
                message: message[at + ANILIST_DOWN.len()..].trim().to_string(),
                anilist_down: true,
            },
            None => Self { status, message, anilist_down: false },
        }
    }

    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, message)
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, message)
    }
}

impl From<AnicatError> for ApiError {
    fn from(e: AnicatError) -> Self {
        let status = match &e {
            AnicatError::NotFound { .. } => StatusCode::NOT_FOUND,
            // AniList answers a missing id as a GraphQL error that core
            // passes on as Network; as a 502 the page would offer a retry
            // for a title that will never exist.
            AnicatError::Network { msg } if msg.contains("Not Found") => StatusCode::NOT_FOUND,
            AnicatError::Network { .. } => StatusCode::BAD_GATEWAY,
            AnicatError::Storage { .. } | AnicatError::Internal { .. } => {
                StatusCode::INTERNAL_SERVER_ERROR
            }
        };
        Self::new(status, e.to_string())
    }
}

// Axum's own extractor rejections answer in plain text, so a malformed
// request reached the page as a body `response.json()` could not parse and
// the page showed a JSON syntax error instead of what was wrong.
impl From<axum::extract::rejection::JsonRejection> for ApiError {
    fn from(r: axum::extract::rejection::JsonRejection) -> Self {
        Self::new(r.status(), r.body_text())
    }
}

impl From<axum::extract::rejection::QueryRejection> for ApiError {
    fn from(r: axum::extract::rejection::QueryRejection) -> Self {
        Self::new(r.status(), r.body_text())
    }
}

impl From<axum::extract::rejection::PathRejection> for ApiError {
    fn from(r: axum::extract::rejection::PathRejection) -> Self {
        Self::new(r.status(), r.body_text())
    }
}

/// `Json`, `Query` and `Path` with rejections in the error shape above.
#[derive(axum::extract::FromRequest)]
#[from_request(via(axum::Json), rejection(ApiError))]
pub struct ApiJson<T>(pub T);

#[derive(axum::extract::FromRequestParts)]
#[from_request(via(axum::extract::Query), rejection(ApiError))]
pub struct ApiQuery<T>(pub T);

#[derive(axum::extract::FromRequestParts)]
#[from_request(via(axum::extract::Path), rejection(ApiError))]
pub struct ApiPath<T>(pub T);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = serde_json::json!({
            "error": self.message,
            "anilist_down": self.anilist_down,
        });
        (self.status, Json(body)).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status_of(e: AnicatError) -> StatusCode {
        ApiError::from(e).status
    }

    #[test]
    fn engine_errors_map_to_statuses() {
        let msg = |m: &str| m.to_string();
        assert_eq!(status_of(AnicatError::NotFound { msg: msg("x") }), StatusCode::NOT_FOUND);
        assert_eq!(
            status_of(AnicatError::Network { msg: msg("graphql: Not Found.") }),
            StatusCode::NOT_FOUND
        );
        assert_eq!(status_of(AnicatError::Network { msg: msg("timed out") }), StatusCode::BAD_GATEWAY);
        assert_eq!(status_of(AnicatError::Storage { msg: msg("locked") }), StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(status_of(AnicatError::Internal { msg: msg("join") }), StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[test]
    fn anilist_outage_marker_anywhere_becomes_503_with_the_sentence() {
        let e = ApiError::from(AnicatError::Network {
            msg: "anilist_down: The AniList API has been temporarily disabled.".into(),
        });
        assert_eq!(e.status, StatusCode::SERVICE_UNAVAILABLE);
        assert!(e.anilist_down);
        assert_eq!(e.message, "The AniList API has been temporarily disabled.");
        let plain = ApiError::bad_request("catalog must be tmdb_movie or tmdb_tv");
        assert_eq!(plain.status, StatusCode::BAD_REQUEST);
        assert!(!plain.anilist_down);
    }
}
