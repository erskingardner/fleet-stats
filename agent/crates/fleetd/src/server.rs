use crate::alerts::AlertEngine;
use crate::config::AgentConfig;
use crate::model::{
    AlertConfig, EventsResponse, HealthResponse, HostSnapshot, StreamMessage,
};
use crate::storage::Storage;
use axum::extract::{Query, Request, State};
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
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use subtle::ConstantTimeEq;
use tokio::sync::{Mutex, RwLock, broadcast};
use tokio_stream::StreamExt;
use tokio_stream::wrappers::BroadcastStream;

pub struct AppState {
    pub config: RwLock<AgentConfig>,
    pub config_path: PathBuf,
    pub latest_snapshot: RwLock<Option<HostSnapshot>>,
    pub storage: Arc<Storage>,
    pub alert_engine: Mutex<AlertEngine>,
    pub tx: broadcast::Sender<StreamMessage>,
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
        .layer(middleware::from_fn_with_state(state.clone(), bearer_auth));

    Router::new().merge(protected).with_state(state)
}

async fn bearer_auth(
    State(state): State<Arc<AppState>>,
    req: Request,
    next: Next,
) -> Response {
    let expected = state.config.read().await.token.clone();
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

async fn get_stream(
    State(state): State<Arc<AppState>>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let initial = state.latest_snapshot.read().await.clone();
    let rx = state.tx.subscribe();

    let initial_stream = futures_util::stream::iter(initial.into_iter().filter_map(|s| {
        let msg = StreamMessage::Snapshot { data: s };
        serde_json::to_string(&msg)
            .ok()
            .map(|json| Ok(Event::default().event("snapshot").data(json)))
    }));

    let live_stream = BroadcastStream::new(rx).filter_map(|item| match item {
        Ok(msg) => {
            let ev_name = match &msg {
                StreamMessage::Snapshot { .. } => "snapshot",
                StreamMessage::Event { .. } => "event",
            };
            serde_json::to_string(&msg)
                .ok()
                .map(|json| Ok(Event::default().event(ev_name).data(json)))
        }
        Err(_) => None,
    });

    let combined = initial_stream.chain(live_stream);

    Sse::new(combined).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("ping"),
    )
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
