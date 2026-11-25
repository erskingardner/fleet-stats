use crate::alerts::{AlertEngine, validate_alert_config};
use crate::config::{AgentConfig, is_allowed_host_header, is_allowed_peer_ip};
use crate::model::{
    AlertConfig, EventsResponse, HealthResponse, HostSnapshot, StreamMessage,
};
use crate::storage::Storage;
use axum::extract::{ConnectInfo, DefaultBodyLimit, Query, Request, State};
use axum::http::{StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, put};
use axum::{Json, Router};
use chrono::Utc;
use futures_util::stream::Stream;
use serde::Deserialize;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use subtle::ConstantTimeEq;
use tokio::sync::{Mutex, OwnedSemaphorePermit, RwLock, Semaphore, broadcast};
use tokio_stream::StreamExt;
use tokio_stream::wrappers::BroadcastStream;
use tracing::warn;

const MAX_SSE_CLIENTS: usize = 16;

pub struct AppState {
    pub config: RwLock<AgentConfig>,
    pub config_path: PathBuf,
    pub latest_snapshot: RwLock<Option<HostSnapshot>>,
    pub storage: Arc<Storage>,
    pub alert_engine: Mutex<AlertEngine>,
    pub tx: broadcast::Sender<StreamMessage>,
    pub sse_slots: Arc<Semaphore>,
}

impl AppState {
    pub fn new_sse_semaphore() -> Arc<Semaphore> {
        Arc::new(Semaphore::new(MAX_SSE_CLIENTS))
    }
}

pub fn router(state: Arc<AppState>) -> Router {
    let protected = Router::new()
        .route("/v1/health", get(get_health))
        .route("/v1/snapshot", get(get_snapshot))
        .route("/v1/stream", get(get_stream))
        .route("/v1/history", get(get_history))
        .route("/v1/events", get(get_events))
        .route("/v1/alerts/config", get(get_alert_config))
        .route("/v1/alerts/config", put(put_alert_config))
        .layer(DefaultBodyLimit::max(64 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), bearer_auth))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            browser_request_guard,
        ))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            peer_ip_guard,
        ));

    Router::new().merge(protected).with_state(state)
}

async fn peer_ip_guard(
    State(state): State<Arc<AppState>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    let tailscale_only = state.config.read().await.tailscale_only;
    if tailscale_only && !is_allowed_peer_ip(addr.ip()) {
        warn!(peer = %addr.ip(), "rejected non-Tailscale/non-loopback request");
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({ "error": "forbidden: tailscale or loopback peer required" })),
        )
            .into_response();
    }
    next.run(req).await
}

/// Blocks browser-originated requests (CSRF, cross-origin fetch/EventSource, form posts, and
/// DNS-rebinding attacks) while allowing native FleetStats / CLI clients.
async fn browser_request_guard(
    State(state): State<Arc<AppState>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    let headers = req.headers();

    // 1. Browsers automatically attach Origin / Referer / Sec-Fetch-* on cross-origin or page requests.
    //    Native FleetStats clients never send these headers.
    let has_browser_headers = headers.contains_key(header::ORIGIN)
        || headers.contains_key(header::REFERER)
        || headers.contains_key("sec-fetch-site")
        || headers.contains_key("sec-fetch-mode")
        || headers.contains_key("sec-fetch-dest");

    if has_browser_headers {
        warn!(peer = %addr.ip(), path = %req.uri().path(), "blocked browser-originated request");
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({ "error": "forbidden: browser requests are blocked" })),
        )
            .into_response();
    }

    // 2. Require explicit non-simple custom client header `X-FleetStats: 1`.
    //    Browsers cannot attach custom headers to simple CORS/EventSource/form requests without a
    //    CORS preflight, which fleetd denies.
    let is_fleetstats_client = headers
        .get("x-fleetstats")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.trim() == "1")
        .unwrap_or(false);

    if !is_fleetstats_client {
        warn!(peer = %addr.ip(), path = %req.uri().path(), "blocked request missing X-FleetStats header");
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({ "error": "forbidden: X-FleetStats client header required" })),
        )
            .into_response();
    }

    // 3. Defeat DNS-rebinding attacks by verifying Host header resolves to loopback/Tailscale.
    let tailscale_only = state.config.read().await.tailscale_only;
    if tailscale_only {
        if let Some(host_val) = headers.get(header::HOST).and_then(|v| v.to_str().ok()) {
            if !is_allowed_host_header(host_val) {
                warn!(peer = %addr.ip(), host = %host_val, "blocked disallowed Host header");
                return (
                    StatusCode::FORBIDDEN,
                    Json(serde_json::json!({ "error": "forbidden: disallowed Host header" })),
                )
                    .into_response();
            }
        }
    }

    next.run(req).await
}

async fn bearer_auth(
    State(state): State<Arc<AppState>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    let expected = state.config.read().await.token.trim().to_string();
    // Optional bearer token: when unset/empty (default on private Tailnets), rely on
    // tailscale_only peer IP allowlist + anti-browser request guard.
    if expected.is_empty() {
        return next.run(req).await;
    }

    let authorized = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .map(|provided| {
            let a = provided.as_bytes();
            let b = expected.as_bytes();
            a.len() == b.len() && bool::from(a.ct_eq(b))
        })
        .unwrap_or(false);

    if !authorized {
        warn!(peer = %addr.ip(), path = %req.uri().path(), "unauthorized API request");
        tokio::time::sleep(Duration::from_millis(150)).await;
        return (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({ "error": "unauthorized" })),
        )
            .into_response();
    }

    next.run(req).await
}

async fn get_health(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let snap = state.latest_snapshot.read().await.clone();
    match snap {
        Some(s) => (
            StatusCode::OK,
            Json(HealthResponse {
                status: "ok".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
                hostname: s.host.hostname,
                os: s.host.os,
                os_version: s.host.os_version,
                arch: s.host.arch,
                uptime_secs: s.host.uptime_secs,
                boot_id: s.host.boot_id,
                cpu_model: s.host.cpu_model,
                cpu_cores: s.cpu.cores.len(),
                memory_total_bytes: s.memory.total_bytes,
            }),
        )
            .into_response(),
        None => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({ "status": "starting" })),
        )
            .into_response(),
    }
}

async fn get_snapshot(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let snap = state.latest_snapshot.read().await.clone();
    match snap {
        Some(s) => (StatusCode::OK, Json(s)).into_response(),
        None => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({ "error": "warming up" })),
        )
            .into_response(),
    }
}

struct PermitGuardedStream<S> {
    inner: S,
    _permit: OwnedSemaphorePermit,
}

impl<S: Stream + Unpin> Stream for PermitGuardedStream<S> {
    type Item = S::Item;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        Pin::new(&mut self.inner).poll_next(cx)
    }
}

async fn get_stream(State(state): State<Arc<AppState>>) -> Response {
    let Ok(permit) = state.sse_slots.clone().try_acquire_owned() else {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Json(serde_json::json!({ "error": "too many concurrent stream clients" })),
        )
            .into_response();
    };

    let initial = state.latest_snapshot.read().await.clone();
    let rx = state.tx.subscribe();

    let initial_stream = futures_util::stream::iter(initial.into_iter().filter_map(|s| {
        let msg = StreamMessage::Snapshot { data: s };
        serde_json::to_string(&msg)
            .ok()
            .map(|json| Ok::<Event, Infallible>(Event::default().event("snapshot").data(json)))
    }));

    let live_stream = BroadcastStream::new(rx).filter_map(|item| match item {
        Ok(msg) => {
            let ev_name = match &msg {
                StreamMessage::Snapshot { .. } => "snapshot",
                StreamMessage::Event { .. } => "event",
            };
            serde_json::to_string(&msg)
                .ok()
                .map(|json| Ok::<Event, Infallible>(Event::default().event(ev_name).data(json)))
        }
        Err(_) => None,
    });

    let combined = PermitGuardedStream {
        inner: Box::pin(initial_stream.chain(live_stream)),
        _permit: permit,
    };

    Sse::new(combined)
        .keep_alive(
            KeepAlive::new()
                .interval(Duration::from_secs(15))
                .text("ping"),
        )
        .into_response()
}

#[derive(Deserialize)]
struct HistoryQuery {
    #[serde(default = "default_window")]
    window: String,
}

fn default_window() -> String {
    "1h".to_string()
}

async fn get_history(
    State(state): State<Arc<AppState>>,
    Query(q): Query<HistoryQuery>,
) -> impl IntoResponse {
    let now_ms = Utc::now().timestamp_millis();
    match state.storage.query_history(&q.window, now_ms) {
        Ok(resp) => (StatusCode::OK, Json(resp)).into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": e })),
        )
            .into_response(),
    }
}

#[derive(Deserialize)]
struct EventsQuery {
    #[serde(default = "default_events_limit")]
    limit: usize,
}

fn default_events_limit() -> usize {
    100
}

async fn get_events(
    State(state): State<Arc<AppState>>,
    Query(q): Query<EventsQuery>,
) -> impl IntoResponse {
    match state.storage.query_events(q.limit) {
        Ok(events) => (StatusCode::OK, Json(EventsResponse { events })).into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": e })),
        )
            .into_response(),
    }
}

async fn get_alert_config(State(state): State<Arc<AppState>>) -> Json<AlertConfig> {
    let engine = state.alert_engine.lock().await;
    Json(engine.config().clone())
}

async fn put_alert_config(
    State(state): State<Arc<AppState>>,
    Json(new_cfg): Json<AlertConfig>,
) -> impl IntoResponse {
    if let Err(err) = validate_alert_config(&new_cfg) {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": err })),
        )
            .into_response();
    }
    {
        let mut engine = state.alert_engine.lock().await;
        engine.update_config(new_cfg.clone());
    }
    {
        let mut cfg = state.config.write().await;
        cfg.alerts = new_cfg.clone();
        if let Err(e) = cfg.save(&state.config_path) {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": e })),
            )
                .into_response();
        }
    }
    (StatusCode::OK, Json(new_cfg)).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request as HttpRequest;
    use std::net::{IpAddr, Ipv4Addr};
    use tower::ServiceExt;

    fn test_app(token: &str, tailscale_only: bool) -> Router {
        let dir = std::env::temp_dir().join(format!(
            "fleetd-srv-test-{}-{}",
            std::process::id(),
            rand::random::<u64>()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let db_path = dir.join("test.db");
        let cfg_path = dir.join("config.toml");

        let mut cfg = AgentConfig::default();
        cfg.token = token.to_string();
        cfg.tailscale_only = tailscale_only;
        cfg.db_path = db_path.clone();

        let storage = Arc::new(Storage::open(&db_path, 2, 7).expect("open storage"));
        let (tx, _) = broadcast::channel::<StreamMessage>(8);
        let state = Arc::new(AppState {
            config: RwLock::new(cfg.clone()),
            config_path: cfg_path,
            latest_snapshot: RwLock::new(None),
            storage,
            alert_engine: Mutex::new(AlertEngine::new(cfg.alerts)),
            tx,
            sse_slots: AppState::new_sse_semaphore(),
        });
        router(state)
    }

    fn req_from(ip: IpAddr, builder: axum::http::request::Builder) -> HttpRequest<Body> {
        let mut req = builder.body(Body::empty()).unwrap();
        req.extensions_mut()
            .insert(ConnectInfo(SocketAddr::new(ip, 55000)));
        req
    }

    #[tokio::test]
    async fn zero_token_allows_fleetstats_client_and_blocks_browsers() {
        let app = test_app("", true);
        let ts_ip = IpAddr::V4(Ipv4Addr::new(100, 100, 1, 2));

        // 1. Valid FleetStats client on Tailscale with no token -> allowed (503 warming up, NOT 401/403)
        let ok_req = req_from(
            ts_ip,
            HttpRequest::builder()
                .uri("/v1/health")
                .header(header::HOST, "100.100.1.2:9470")
                .header("x-fleetstats", "1"),
        );
        let resp = app.clone().oneshot(ok_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);

        // 2. Missing X-FleetStats header -> 403
        let missing_hdr = req_from(
            ts_ip,
            HttpRequest::builder()
                .uri("/v1/health")
                .header(header::HOST, "100.100.1.2:9470"),
        );
        assert_eq!(
            app.clone().oneshot(missing_hdr).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );

        // 3. Browser Origin header -> 403 even with X-FleetStats
        let origin_req = req_from(
            ts_ip,
            HttpRequest::builder()
                .uri("/v1/health")
                .header(header::HOST, "127.0.0.1:9470")
                .header(header::ORIGIN, "https://evil.example")
                .header("x-fleetstats", "1"),
        );
        assert_eq!(
            app.clone().oneshot(origin_req).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );

        // 4. Browser Sec-Fetch-Site header -> 403
        let fetch_req = req_from(
            ts_ip,
            HttpRequest::builder()
                .uri("/v1/health")
                .header(header::HOST, "127.0.0.1:9470")
                .header("sec-fetch-site", "cross-site")
                .header("x-fleetstats", "1"),
        );
        assert_eq!(
            app.clone().oneshot(fetch_req).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );

        // 5. DNS rebinding Host header -> 403
        let rebind_req = req_from(
            ts_ip,
            HttpRequest::builder()
                .uri("/v1/health")
                .header(header::HOST, "evil.example:9470")
                .header("x-fleetstats", "1"),
        );
        assert_eq!(
            app.clone().oneshot(rebind_req).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );

        // 6. Non-Tailscale LAN peer -> 403
        let lan_req = req_from(
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 50)),
            HttpRequest::builder()
                .uri("/v1/health")
                .header(header::HOST, "127.0.0.1:9470")
                .header("x-fleetstats", "1"),
        );
        assert_eq!(
            app.oneshot(lan_req).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
    }

    #[tokio::test]
    async fn optional_bearer_token_enforced_when_configured() {
        let secret = "fls_test_secret_token_1234567890abcdef";
        let app = test_app(secret, true);
        let ts_ip = IpAddr::V4(Ipv4Addr::new(100, 100, 1, 2));

        let no_auth = req_from(
            ts_ip,
            HttpRequest::builder()
                .uri("/v1/health")
                .header(header::HOST, "100.100.1.2:9470")
                .header("x-fleetstats", "1"),
        );
        assert_eq!(
            app.clone().oneshot(no_auth).await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );

        let with_auth = req_from(
            ts_ip,
            HttpRequest::builder()
                .uri("/v1/health")
                .header(header::HOST, "100.100.1.2:9470")
                .header("x-fleetstats", "1")
                .header(header::AUTHORIZATION, format!("Bearer {secret}")),
        );
        assert_eq!(
            app.oneshot(with_auth).await.unwrap().status(),
            StatusCode::SERVICE_UNAVAILABLE
        );
    }
}
