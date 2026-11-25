use crate::model::AlertConfig;
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    #[serde(default = "default_bind")]
    pub bind: String,

    #[serde(default = "default_token")]
    pub token: String,

    #[serde(default = "default_sample_interval")]
    pub sample_interval_secs: u64,

    #[serde(default = "default_db_path")]
    pub db_path: PathBuf,

    #[serde(default = "default_raw_retention_hours")]
    pub raw_retention_hours: u64,

    #[serde(default = "default_rollup_retention_days")]
    pub rollup_retention_days: u64,

    #[serde(default)]
    pub alerts: AlertConfig,
}

fn default_bind() -> String {
    "127.0.0.1:9470".to_string()
}

fn default_token() -> String {
    generate_token()
}

fn default_sample_interval() -> u64 {
    2
}

fn default_raw_retention_hours() -> u64 {
    2
}

fn default_rollup_retention_days() -> u64 {
    7
}

pub fn default_config_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("fleetd");
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        if !home.is_empty() {
            #[cfg(target_os = "macos")]
            {
                return PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
                    .join("FleetStats")
                    .join("fleetd");
            }
            #[cfg(not(target_os = "macos"))]
            {
                return PathBuf::from(home).join(".config").join("fleetd");
            }
        }
    }
    PathBuf::from("/etc/fleetd")
}

pub fn default_data_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("fleetd");
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        if !home.is_empty() {
            #[cfg(target_os = "macos")]
            {
                return PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
                    .join("FleetStats")
                    .join("fleetd");
            }
            #[cfg(not(target_os = "macos"))]
            {
                return PathBuf::from(home)
                    .join(".local")
                    .join("share")
                    .join("fleetd");
            }
        }
    }
    PathBuf::from("/var/lib/fleetd")
}

pub fn default_config_path() -> PathBuf {
    default_config_dir().join("config.toml")
}

fn default_db_path() -> PathBuf {
    default_data_dir().join("fleetd.db")
}

pub fn generate_token() -> String {
    const CHARSET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut rng = rand::rng();
    let mut out = String::with_capacity(48);
    out.push_str("fls_");
    for _ in 0..44 {
        let idx = rng.random_range(0..CHARSET.len());
        out.push(CHARSET[idx] as char);
    }
    out
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            bind: default_bind(),
            token: default_token(),
            sample_interval_secs: default_sample_interval(),
            db_path: default_db_path(),
            raw_retention_hours: default_raw_retention_hours(),
            rollup_retention_days: default_rollup_retention_days(),
            alerts: AlertConfig::default(),
        }
    }
}

impl AgentConfig {
    pub fn load_or_create(path: &Path) -> Result<Self, String> {
        if path.exists() {
            let raw = fs::read_to_string(path)
                .map_err(|e| format!("failed reading config {}: {e}", path.display()))?;
            let cfg: Self = toml::from_str(&raw)
                .map_err(|e| format!("failed parsing config {}: {e}", path.display()))?;
            return Ok(cfg);
        }

        let cfg = Self::default();
        cfg.save(path)?;
        Ok(cfg)
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("failed creating dir {}: {e}", parent.display()))?;
        }
        let encoded = toml::to_string_pretty(self)
            .map_err(|e| format!("failed serializing config: {e}"))?;
        fs::write(path, encoded)
            .map_err(|e| format!("failed writing config {}: {e}", path.display()))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
        }

        Ok(())
    }
}
