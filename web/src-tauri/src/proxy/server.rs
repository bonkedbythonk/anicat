use axum::{
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use std::collections::HashMap;
use std::net::SocketAddr;

#[derive(Clone)]
pub struct ProxyState {
    pub client: reqwest::Client,
}

pub async fn start_proxy(client: reqwest::Client) -> SocketAddr {
    let state = ProxyState { client };

    let app = Router::new()
        .route("/proxy", get(proxy_handler))
        .route("/health", get(health_handler))
        .with_state(state);

    let addr = SocketAddr::from(([127, 0, 0, 1], 13370));
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    let bound = listener.local_addr().unwrap();

    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    bound
}

async fn health_handler() -> &'static str {
    "ok"
}

#[derive(serde::Deserialize)]
struct ProxyQuery {
    url: String,
    #[serde(rename = "type")]
    _type: Option<String>,
}

async fn proxy_handler(
    State(state): State<ProxyState>,
    Query(params): Query<ProxyQuery>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    let url = params.url;

    let mut req_builder = state.client.get(&url);

    if let Some(range) = headers.get("range") {
        req_builder = req_builder.header("range", range);
    }

    req_builder = req_builder
        .header("user-agent", "Anicat/5.0")
        .header("accept", "*/*");

    let resp = req_builder
        .send()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;

    let status = resp.status();
    let resp_headers = resp.headers().clone();

    let body_bytes = resp
        .bytes()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;

    let mut response = Response::builder().status(status);

    for (key, value) in resp_headers.iter() {
        if key != "transfer-encoding" && key != "content-encoding" && key != "connection" {
            response = response.header(key, value);
        }
    }

    response
        .header("access-control-allow-origin", "*")
        .header("access-control-allow-headers", "*")
        .body(Body::from(body_bytes))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}
