use crate::model::AlertConfig;
use rand::RngExt;
use serde::{Deserialize, Serialize};
use std::fs;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    #[serde(default = "default_bind")]
    pub bind: String,

    /// Optional bearer token. Empty (default) uses Tailscale-only peer IP + anti-browser
    /// request guards with zero token friction on a personal Tailnet. Set a 24+ char token
    /// to enforce Bearer auth (required if `tailscale_only` is false).
    #[serde(default)]
    pub token: String,

    /// When true (default), fleetd rejects any HTTP connection whose source IP is not
    /// loopback (127.0.0.0/8, ::1) or Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48).
    #[serde(default = "default_true")]
    pub tailscale_only: bool,

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

fn default_true() -> bool {
    true
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

pub fn is_tailscale_ipv4(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    // Tailscale uses CGNAT 100.64.0.0/10
    o[0] == 100 && (64..=127).contains(&o[1])
}

pub fn is_tailscale_ipv6(ip: Ipv6Addr) -> bool {
    let seg = ip.segments();
    // Tailscale ULA prefix fd7a:115c:a1e0::/48
    seg[0] == 0xfd7a && seg[1] == 0x115c && seg[2] == 0xa1e0
}

pub fn is_allowed_peer_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_loopback() || is_tailscale_ipv4(v4),
        IpAddr::V6(v6) => {
            if let Some(mapped) = v6.to_ipv4_mapped() {
                return mapped.is_loopback() || is_tailscale_ipv4(mapped);
            }
            v6.is_loopback() || is_tailscale_ipv6(v6)
        }
    }
}

/// Validates the HTTP `Host` header against DNS-rebinding attacks when `tailscale_only` is active.
/// Allows loopback, Tailscale IPs, `*.ts.net` / `*.tailscale.net`, and single-label MagicDNS names.
pub fn is_allowed_host_header(raw_host: &str) -> bool {
    let trimmed = raw_host.trim();
    if trimmed.is_empty() || trimmed.chars().any(|c| c.is_whitespace() || c == '/' || c == '\\') {
        return false;
    }

    let host_only = if let Some(rest) = trimmed.strip_prefix('[') {
        let Some((inside, after)) = rest.split_once(']') else {
            return false;
        };
        if !after.is_empty() && !after.starts_with(':') {
            return false;
        }
        inside
    } else if let Some((left, right)) = trimmed.rsplit_once(':') {
        // Distinguish host:port from unbracketed IPv6
        if !left.contains(':') && right.chars().all(|c| c.is_ascii_digit()) {
            left
        } else {
            trimmed
        }
    } else {
        trimmed
    };

    let lower = host_only.to_ascii_lowercase();
    if lower.is_empty() {
        return false;
    }
    if lower == "localhost" {
        return true;
    }
    if let Ok(ip) = lower.parse::<IpAddr>() {
        return is_allowed_peer_ip(ip);
    }
    if lower.ends_with(".ts.net") || lower.ends_with(".tailscale.net") {
        return true;
    }
    // Single-label MagicDNS hostname (e.g. "mini", "linux-tower")
    !lower.contains('.')
        && !lower.contains(':')
        && lower
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// Detect local Tailscale IPv4/IPv6 addresses via POSIX `getifaddrs`.
pub fn detect_tailscale_ips() -> Vec<IpAddr> {
    let mut found = Vec::new();
    unsafe {
        let mut ifap: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut ifap) == 0 && !ifap.is_null() {
            let mut cur = ifap;
            while !cur.is_null() {
                let ifa = &*cur;
                if !ifa.ifa_addr.is_null() {
                    let family = (*ifa.ifa_addr).sa_family as i32;
                    if family == libc::AF_INET {
                        let sin = &*(ifa.ifa_addr as *const libc::sockaddr_in);
                        let v4 = Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr));
                        if is_tailscale_ipv4(v4) {
                            let ip = IpAddr::V4(v4);
                            if !found.contains(&ip) {
                                found.push(ip);
                            }
                        }
                    } else if family == libc::AF_INET6 {
                        let sin6 = &*(ifa.ifa_addr as *const libc::sockaddr_in6);
                        let v6 = Ipv6Addr::from(sin6.sin6_addr.s6_addr);
                        if is_tailscale_ipv6(v6) {
                            let ip = IpAddr::V6(v6);
                            if !found.contains(&ip) {
                                found.push(ip);
                            }
                        }
                    }
                }
                cur = ifa.ifa_next;
            }
            libc::freeifaddrs(ifap);
        }
    }
    found
}

/// Resolve `bind` string into concrete socket addresses.
/// `"tailscale:9470"` binds `127.0.0.1:9470` plus every active Tailscale interface IP
/// on port `9470`, never exposing LAN or public NICs.
pub fn resolve_bind_addresses(bind: &str) -> Vec<String> {
    if let Some(port_str) = bind.strip_prefix("tailscale:") {
        let mut addrs = vec![format!("127.0.0.1:{port_str}")];
        for ip in detect_tailscale_ips() {
            match ip {
                IpAddr::V4(v4) => addrs.push(format!("{v4}:{port_str}")),
                IpAddr::V6(v6) => addrs.push(format!("[{v6}]:{port_str}")),
            }
        }
        addrs
    } else {
        vec![bind.to_string()]
    }
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            bind: default_bind(),
            token: String::new(),
            tailscale_only: true,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tailscale_peer_allowlist() {
        assert!(is_allowed_peer_ip(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1))));
        assert!(is_allowed_peer_ip(IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1))));
        assert!(is_allowed_peer_ip(IpAddr::V4(Ipv4Addr::new(100, 127, 255, 254))));
        assert!(is_allowed_peer_ip(IpAddr::V6(Ipv6Addr::LOCALHOST)));
        assert!(is_allowed_peer_ip(IpAddr::V6(
            "fd7a:115c:a1e0::1".parse().unwrap()
        )));

        // Non-Tailscale LAN & public IPs must be rejected
        assert!(!is_allowed_peer_ip(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 10))));
        assert!(!is_allowed_peer_ip(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 5))));
        assert!(!is_allowed_peer_ip(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8))));
        assert!(!is_allowed_peer_ip(IpAddr::V4(Ipv4Addr::new(100, 128, 0, 1))));
    }

    #[test]
    fn host_header_dns_rebinding_guard() {
        assert!(is_allowed_host_header("127.0.0.1:9470"));
        assert!(is_allowed_host_header("localhost:9470"));
        assert!(is_allowed_host_header("[::1]:9470"));
        assert!(is_allowed_host_header("100.109.43.46:9470"));
        assert!(is_allowed_host_header("[fd7a:115c:a1e0::1]:9470"));
        assert!(is_allowed_host_header("mini:9470"));
        assert!(is_allowed_host_header("mini.tail1234.ts.net:9470"));

        // External domains & LAN IPs must be rejected to defeat DNS rebinding
        assert!(!is_allowed_host_header("evil.com:9470"));
        assert!(!is_allowed_host_header("rebind.attacker.io"));
        assert!(!is_allowed_host_header("192.168.1.5:9470"));
        assert!(!is_allowed_host_header("10.0.0.5:9470"));
        assert!(!is_allowed_host_header(""));
    }
}
