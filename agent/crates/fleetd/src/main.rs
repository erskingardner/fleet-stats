mod alerts;
mod collector;
mod config;
mod model;
mod server;
mod storage;

use alerts::AlertEngine;
use clap::{Parser, Subcommand};
use config::{AgentConfig, default_config_path, resolve_bind_addresses};
use model::StreamMessage;
use server::AppState;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use storage::Storage;
use tokio::sync::{Mutex, RwLock, broadcast};
use tracing::{error, info, warn};

#[derive(Parser)]
#[command(
    name = "fleetd",
    version,
    about = "Lightweight telemetry agent for FleetStats"
)]
struct Cli {
    /// Path to config.toml
    #[arg(long, global = true)]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Run the telemetry daemon (default)
    Serve {
        /// Override bind address (e.g. 127.0.0.1:9470 or tailscale:9470)
        #[arg(long)]
        bind: Option<String>,
        /// Optional bearer token (prefer FLEETD_TOKEN env var to avoid ps exposure)
        #[arg(long)]
        token: Option<String>,
        /// Disable bearer token authentication for this run (Tailscale-only + anti-browser guards remain active)
        #[arg(long, default_value_t = false)]
        no_token: bool,
        /// Override SQLite database path
        #[arg(long)]
        db: Option<PathBuf>,
        /// Allow non-Tailscale/non-loopback peers (disabled by default; requires a bearer token)
        #[arg(long, default_value_t = false)]
        allow_non_tailscale: bool,
        /// Exit automatically if the given parent PID disappears (used when bundled inside FleetStats.app)
        #[arg(long)]
        parent_pid: Option<i32>,
    },
    /// Initialize config file (zero-token Tailscale-only mode by default)
    Init {
        /// Bind address to write into config.toml (default: tailscale:9470)
        #[arg(long, default_value = "tailscale:9470")]
        bind: String,
        /// Optional explicit bearer token (prefer FLEETD_TOKEN env var)
        #[arg(long)]
        token: Option<String>,
        /// Generate and require a bearer token (optional, for shared Tailnets)
        #[arg(long, default_value_t = false)]
        require_token: bool,
        /// Clear any existing bearer token and use zero-token Tailscale-only mode
        #[arg(long, default_value_t = false)]
        no_token: bool,
    },
    /// Print the configured bearer token
    PrintToken,
    /// Print a single JSON telemetry snapshot and exit
    Snapshot,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("fleetd=info")),
        )
        .init();

    let cli = Cli::parse();
    let cfg_path = cli.config.unwrap_or_else(default_config_path);
    let env_token = std::env::var("FLEETD_TOKEN")
        .ok()
        .filter(|t| !t.trim().is_empty());

    match cli.command.unwrap_or(Commands::Serve {
        bind: None,
        token: None,
        no_token: false,
        db: None,
        allow_non_tailscale: false,
        parent_pid: None,
    }) {
        Commands::Init {
            bind,
            token,
            require_token,
            no_token,
        } => {
            let mut cfg = AgentConfig::load_or_create(&cfg_path).unwrap_or_default();
            cfg.bind = bind;
            cfg.tailscale_only = true;
            if no_token {
                cfg.token.clear();
            } else if let Some(t) = env_token.or(token) {
                cfg.token = t;
            } else if require_token && cfg.token.trim().is_empty() {
                cfg.token = config::generate_token();
            }
            if let Err(e) = cfg.save(&cfg_path) {
                eprintln!("Error saving config: {e}");
                std::process::exit(1);
            }
            println!("Config written to {}", cfg_path.display());
            println!("Bind:  {}", cfg.bind);
            if cfg.token.trim().is_empty() {
                println!("Auth:  Tailscale-only (no bearer token; browser requests blocked)");
            } else {
                println!("Token: {}", cfg.token);
            }
        }
        Commands::PrintToken => match AgentConfig::load_or_create(&cfg_path) {
            Ok(cfg) => {
                if !cfg.token.trim().is_empty() {
                    println!("{}", cfg.token);
                }
            }
            Err(e) => {
                eprintln!("Error loading config: {e}");
                std::process::exit(1);
            }
        },
        Commands::Snapshot => {
            let mut col = collector::create_collector();
            let _ = col.collect();
            std::thread::sleep(Duration::from_millis(500));
            let res = col.collect();
            println!(
                "{}",
                serde_json::to_string_pretty(&res.snapshot).unwrap_or_default()
            );
        }
        Commands::Serve {
            bind,
            token,
            no_token,
            db,
            allow_non_tailscale,
            parent_pid,
        } => {
            let mut cfg = match AgentConfig::load_or_create(&cfg_path) {
                Ok(c) => c,
                Err(e) => {
                    error!("Failed loading config: {e}");
                    std::process::exit(1);
                }
            };
            if let Some(b) = bind {
                cfg.bind = b;
            }
            if no_token {
                cfg.token.clear();
            } else if let Some(t) = env_token.or(token) {
                cfg.token = t;
            }
            if let Some(d) = db {
                cfg.db_path = d;
            }
            if allow_non_tailscale {
                cfg.tailscale_only = false;
            }
            let trimmed_token = cfg.token.trim();
            if !trimmed_token.is_empty() && trimmed_token.len() < 24 {
                error!("Refusing to start with a bearer token shorter than 24 characters");
                std::process::exit(1);
            }
            if !cfg.tailscale_only && trimmed_token.is_empty() {
                error!("Refusing to start with --allow-non-tailscale without a bearer token");
                std::process::exit(1);
            }

            if let Err(e) = run_server(cfg, cfg_path, parent_pid).await {
                error!("fleetd exited with error: {e}");
                std::process::exit(1);
            }
        }
    }
}

async fn run_server(
    cfg: AgentConfig,
    config_path: PathBuf,
    parent_pid: Option<i32>,
) -> Result<(), String> {
    let storage = Arc::new(Storage::open(
        &cfg.db_path,
        cfg.raw_retention_hours,
        cfg.rollup_retention_days,
    )?);

    let mut platform_collector = collector::create_collector();
    let boot_id = platform_collector.boot_id();
    let now_ms = chrono::Utc::now().timestamp_millis();
    if let Ok(Some(reboot_ev)) = storage.check_boot_and_record_startup(&boot_id, now_ms) {
        warn!(detail = %reboot_ev.detail, "detected unexpected reboot since last run");
    }

    // Prime initial counters so first published tick has valid deltas
    let _ = platform_collector.collect();

    let (tx, _) = broadcast::channel::<StreamMessage>(64);
    let bind_addrs = resolve_bind_addresses(&cfg.bind);
    let tailscale_only = cfg.tailscale_only;
    let auth_mode = if cfg.token.trim().is_empty() {
        "tailscale-trust"
    } else {
        "bearer-token"
    };
    let interval_secs = cfg.sample_interval_secs.max(1);
    let alert_engine = Mutex::new(AlertEngine::new(cfg.alerts.clone()));

    let state = Arc::new(AppState {
        config: RwLock::new(cfg),
        config_path,
        latest_snapshot: RwLock::new(None),
        storage: storage.clone(),
        alert_engine,
        tx: tx.clone(),
        sse_slots: AppState::new_sse_semaphore(),
    });

    // Background telemetry sampler loop
    let sampler_state = state.clone();
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(interval_secs));
        let collector = Arc::new(std::sync::Mutex::new(platform_collector));

        loop {
            ticker.tick().await;
            let col_clone = collector.clone();
            let result = tokio::task::spawn_blocking(move || {
                let mut guard = col_clone.lock().unwrap();
                guard.collect()
            })
            .await;

            let Ok(mut collected) = result else {
                continue;
            };

            let (active_alerts, new_events) = {
                let mut engine = sampler_state.alert_engine.lock().await;
                engine.evaluate(
                    &collected.snapshot,
                    &collected.oom_events,
                    &sampler_state.storage,
                )
            };
            collected.snapshot.active_alerts = active_alerts;

            if let Err(e) = sampler_state.storage.record_snapshot(&collected.snapshot) {
                warn!(error = %e, "failed persisting telemetry snapshot");
            }

            {
                let mut latest = sampler_state.latest_snapshot.write().await;
                *latest = Some(collected.snapshot.clone());
            }

            let _ = sampler_state.tx.send(StreamMessage::Snapshot {
                data: collected.snapshot,
            });
            for ev in new_events {
                let _ = sampler_state.tx.send(StreamMessage::Event { data: ev });
            }
        }
    });

    let mut listeners = Vec::new();
    for addr in &bind_addrs {
        match tokio::net::TcpListener::bind(addr).await {
            Ok(l) => {
                info!(
                    bind = %addr,
                    tailscale_only = tailscale_only,
                    auth = auth_mode,
                    version = env!("CARGO_PKG_VERSION"),
                    "fleetd listening"
                );
                listeners.push(l);
            }
            Err(e) => {
                warn!(bind = %addr, error = %e, "failed binding address");
            }
        }
    }

    if listeners.is_empty() {
        return Err(format!("failed binding any address from {bind_addrs:?}"));
    }

    let (shutdown_tx, _) = broadcast::channel::<()>(1);
    let mut handles = Vec::new();
    for listener in listeners {
        let app = server::router(state.clone());
        let mut rx = shutdown_tx.subscribe();
        handles.push(tokio::spawn(async move {
            axum::serve(
                listener,
                app.into_make_service_with_connect_info::<SocketAddr>(),
            )
            .with_graceful_shutdown(async move {
                let _ = rx.recv().await;
            })
            .await
            .map_err(|e| format!("server error: {e}"))
        }));
    }

    shutdown_signal(parent_pid).await;
    let _ = shutdown_tx.send(());
    let _ = tokio::time::timeout(Duration::from_millis(300), async {
        for h in handles {
            let _ = h.await;
        }
    })
    .await;

    storage.mark_clean_shutdown();
    info!("fleetd shut down cleanly");
    Ok(())
}

async fn shutdown_signal(parent_pid: Option<i32>) {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut sig) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            sig.recv().await;
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    let parent_gone = async {
        let Some(ppid) = parent_pid else {
            return std::future::pending::<()>().await;
        };
        let mut ticker = tokio::time::interval(Duration::from_secs(2));
        loop {
            ticker.tick().await;
            #[cfg(unix)]
            {
                let alive = unsafe { libc::kill(ppid, 0) == 0 };
                if !alive {
                    info!(parent_pid = ppid, "parent process exited; shutting down fleetd");
                    break;
                }
            }
        }
    };

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
        _ = parent_gone => {},
    }
}
