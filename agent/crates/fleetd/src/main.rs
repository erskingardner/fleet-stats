mod alerts;
mod collector;
mod config;
mod model;
mod server;
mod storage;

use alerts::AlertEngine;
use clap::{Parser, Subcommand};
use config::{AgentConfig, default_config_path};
use model::StreamMessage;
use server::AppState;
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
        /// Override bind address (e.g. 127.0.0.1:9470 or 0.0.0.0:9470)
        #[arg(long)]
        bind: Option<String>,
        /// Override bearer token
        #[arg(long)]
        token: Option<String>,
        /// Override SQLite database path
        #[arg(long)]
        db: Option<PathBuf>,
    },
    /// Initialize config file and print the generated bearer token
    Init {
        /// Bind address to write into config.toml
        #[arg(long, default_value = "0.0.0.0:9470")]
        bind: String,
        /// Explicit token (auto-generated if omitted)
        #[arg(long)]
        token: Option<String>,
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

    match cli.command.unwrap_or(Commands::Serve {
        bind: None,
        token: None,
        db: None,
    }) {
        Commands::Init { bind, token } => {
            let mut cfg = AgentConfig::load_or_create(&cfg_path).unwrap_or_default();
            cfg.bind = bind;
            if let Some(t) = token {
                cfg.token = t;
            }
            if let Err(e) = cfg.save(&cfg_path) {
                eprintln!("Error saving config: {e}");
                std::process::exit(1);
            }
            println!("Config written to {}", cfg_path.display());
            println!("Bind:  {}", cfg.bind);
            println!("Token: {}", cfg.token);
        }
        Commands::PrintToken => match AgentConfig::load_or_create(&cfg_path) {
            Ok(cfg) => println!("{}", cfg.token),
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
        Commands::Serve { bind, token, db } => {
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
            if let Some(t) = token {
                cfg.token = t;
            }
            if let Some(d) = db {
                cfg.db_path = d;
            }

            if let Err(e) = run_server(cfg, cfg_path).await {
                error!("fleetd exited with error: {e}");
                std::process::exit(1);
            }
        }
    }
}

async fn run_server(cfg: AgentConfig, config_path: PathBuf) -> Result<(), String> {
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
    let bind_addr = cfg.bind.clone();
    let interval_secs = cfg.sample_interval_secs.max(1);
    let alert_engine = Mutex::new(AlertEngine::new(cfg.alerts.clone()));

    let state = Arc::new(AppState {
        config: RwLock::new(cfg),
        config_path,
        latest_snapshot: RwLock::new(None),
        storage: storage.clone(),
        alert_engine,
        tx: tx.clone(),
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

    let app = server::router(state.clone());
    let listener = tokio::net::TcpListener::bind(&bind_addr)
        .await
        .map_err(|e| format!("failed binding {bind_addr}: {e}"))?;

    info!(
        bind = %bind_addr,
        version = env!("CARGO_PKG_VERSION"),
        "fleetd listening"
    );

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|e| format!("server error: {e}"))?;

    storage.mark_clean_shutdown();
    info!("fleetd shut down cleanly");
    Ok(())
}

async fn shutdown_signal() {
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

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}
