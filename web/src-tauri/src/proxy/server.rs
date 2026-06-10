use axum::{
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use std::net::SocketAddr;

#[derive(serde::Deserialize)]
struct ProxyQuery {
    url: String,
}

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
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind HLS proxy port 13370");
    let bound = listener.local_addr().unwrap();

    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    bound
}

async fn health_handler() -> &'static str {
    "ok"
}

async fn proxy_handler(
    State(state): State<ProxyState>,
    Query(params): Query<ProxyQuery>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    let url = &params.url;

    let mut req_builder = state.client.get(url);

    if let Some(range) = headers.get("range") {
        req_builder = req_builder.header("range", range);
    }

    // Forward critical headers
    if let Some(ua) = headers.get("user-agent") {
        req_builder = req_builder.header("user-agent", ua);
    } else {
        req_builder = req_builder.header(
            "user-agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
        );
    }

    if let Some(referer) = headers.get("referer") {
        req_builder = req_builder.header("referer", referer);
    }

    req_builder = req_builder.header("accept", "*/*");

    let upstream = req_builder
        .send()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;

    let status = upstream.status();
    let upstream_headers = upstream.headers().clone();

    let body_bytes = upstream
        .bytes()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;

    let mut response = Response::builder().status(status);

    // Copy upstream headers, skipping hop-by-hop
    for (key, value) in upstream_headers.iter() {
        let key_lower = key.as_str().to_lowercase();
        if matches!(
            key_lower.as_str(),
            "transfer-encoding" | "connection" | "keep-alive" | "trailer" | "upgrade"
        ) {
            continue;
        }
        if let Ok(hv) = HeaderValue::from_bytes(value.as_bytes()) {
            response = response.header(key.as_str(), hv);
        }
    }

    // CORS for webview playback
    response = response
        .header("access-control-allow-origin", "*")
        .header("access-control-expose-headers", "*");

    response
        .body(Body::from(body_bytes))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}
