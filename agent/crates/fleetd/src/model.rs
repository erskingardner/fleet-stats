use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OsKind {
    Macos,
    Linux,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoreKind {
    Performance,
    Efficiency,
    Standard,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PressureLevel {
    Normal,
    Warn,
    Critical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlertSeverity {
    Info,
    Warning,
    Critical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    OomKill,
    UnexpectedReboot,
    AlertTriggered,
    AlertResolved,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthResponse {
    pub status: String,
    pub version: String,
    pub hostname: String,
    pub os: OsKind,
    pub os_version: String,
    pub arch: String,
    pub uptime_secs: u64,
    pub boot_id: String,
    pub cpu_model: String,
    pub cpu_cores: usize,
    pub memory_total_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostInfo {
    pub hostname: String,
    pub os: OsKind,
    pub os_version: String,
    pub arch: String,
    pub uptime_secs: u64,
    pub boot_id: String,
    pub cpu_model: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostSnapshot {
    pub timestamp: i64,
    pub host: HostInfo,
    pub cpu: CpuMetrics,
    pub memory: MemoryMetrics,
    pub disks: DiskMetrics,
    pub network: NetworkMetrics,
    pub active_alerts: Vec<ActiveAlert>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CpuMetrics {
    pub total_pct: f64,
    pub user_pct: f64,
    pub system_pct: f64,
    pub iowait_pct: f64,
    pub idle_pct: f64,
    pub load_avg: [f64; 3],
    pub cores: Vec<CoreUsage>,
    pub top_processes: Vec<ProcessCpu>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoreUsage {
    pub index: usize,
    pub usage_pct: f64,
    pub kind: CoreKind,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessCpu {
    pub pid: u32,
    pub name: String,
    pub user: String,
    pub cpu_pct: f64,
    pub memory_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryMetrics {
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub used_pct: f64,
    pub app_bytes: u64,
    pub wired_bytes: u64,
    pub compressed_bytes: u64,
    pub cached_bytes: u64,
    pub free_bytes: u64,
    pub swap_used_bytes: u64,
    pub swap_total_bytes: u64,
    pub pressure_level: PressureLevel,
    pub pressure_pct: f64,
    pub psi_some_avg10: Option<f64>,
    pub psi_full_avg10: Option<f64>,
    pub top_processes: Vec<ProcessMemory>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessMemory {
    pub pid: u32,
    pub name: String,
    pub user: String,
    pub memory_bytes: u64,
    pub oom_score: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskMetrics {
    pub primary_used_pct: f64,
    pub total_read_bps: u64,
    pub total_write_bps: u64,
    pub volumes: Vec<DiskVolume>,
    pub top_processes: Vec<ProcessDiskIo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskVolume {
    pub id: String,
    pub name: String,
    pub mount_point: String,
    pub filesystem: String,
    pub is_external: bool,
    pub is_primary: bool,
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub free_bytes: u64,
    pub used_pct: f64,
    pub read_bps: u64,
    pub write_bps: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessDiskIo {
    pub pid: u32,
    pub name: String,
    pub user: String,
    pub read_bps: u64,
    pub write_bps: u64,
    pub total_bps: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkMetrics {
    pub upload_bps: u64,
    pub download_bps: u64,
    pub interfaces: Vec<NetworkInterface>,
    pub top_processes: Vec<ProcessNetIo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkInterface {
    pub name: String,
    pub display_name: String,
    pub is_up: bool,
    pub is_physical: bool,
    pub ipv4: Vec<String>,
    pub ipv6: Vec<String>,
    pub upload_bps: u64,
    pub download_bps: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessNetIo {
    pub pid: u32,
    pub name: String,
    pub user: String,
    pub upload_bps: u64,
    pub download_bps: u64,
    pub total_bps: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActiveAlert {
    pub id: String,
    pub metric: String,
    pub severity: AlertSeverity,
    pub title: String,
    pub detail: String,
    pub value: f64,
    pub threshold: f64,
    pub triggered_at: i64,
    pub top_process: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryResponse {
    pub window: String,
    pub resolution_secs: u64,
    pub points: Vec<HistoryPoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryPoint {
    pub timestamp: i64,
    pub cpu_pct: f64,
    pub cpu_max_pct: f64,
    pub mem_used_pct: f64,
    pub mem_max_pct: f64,
    pub mem_pressure_pct: f64,
    pub swap_used_pct: f64,
    pub disk_primary_pct: f64,
    pub disk_read_bps: u64,
    pub disk_write_bps: u64,
    pub net_up_bps: u64,
    pub net_down_bps: u64,
    pub top_cpu_proc: Option<String>,
    pub top_mem_proc: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetEvent {
    pub id: i64,
    pub timestamp: i64,
    pub kind: EventKind,
    pub severity: AlertSeverity,
    pub metric: Option<String>,
    pub title: String,
    pub detail: String,
    pub process_name: Option<String>,
    pub process_pid: Option<u32>,
    pub value: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventsResponse {
    pub events: Vec<FleetEvent>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WebhookKind {
    Ntfy,
    Pushover,
    Discord,
    Generic,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebhookTarget {
    pub name: String,
    pub kind: WebhookKind,
    pub url: String,
    #[serde(default)]
    pub token_or_key: Option<String>,
    #[serde(default)]
    pub user_key: Option<String>,
    #[serde(default = "default_min_severity")]
    pub min_severity: AlertSeverity,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_min_severity() -> AlertSeverity {
    AlertSeverity::Critical
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlertConfig {
    #[serde(default = "default_cpu_warn")]
    pub cpu_warn_pct: f64,
    #[serde(default = "default_cpu_crit")]
    pub cpu_crit_pct: f64,
    #[serde(default = "default_cpu_duration")]
    pub cpu_duration_secs: u64,

    #[serde(default = "default_mem_warn")]
    pub mem_warn_pct: f64,
    #[serde(default = "default_mem_crit")]
    pub mem_crit_pct: f64,
    #[serde(default = "default_mem_duration")]
    pub mem_duration_secs: u64,

    #[serde(default = "default_disk_warn")]
    pub disk_warn_pct: f64,
    #[serde(default = "default_disk_crit")]
    pub disk_crit_pct: f64,

    #[serde(default = "default_true")]
    pub oom_alerts_enabled: bool,

    #[serde(default = "default_cooldown")]
    pub cooldown_secs: u64,

    #[serde(default)]
    pub webhooks: Vec<WebhookTarget>,
}

fn default_cpu_warn() -> f64 {
    90.0
}
fn default_cpu_crit() -> f64 {
    97.0
}
fn default_cpu_duration() -> u64 {
    180
}
fn default_mem_warn() -> f64 {
    85.0
}
fn default_mem_crit() -> f64 {
    92.0
}
fn default_mem_duration() -> u64 {
    60
}
fn default_disk_warn() -> f64 {
    85.0
}
fn default_disk_crit() -> f64 {
    93.0
}
fn default_cooldown() -> u64 {
    300
}

impl Default for AlertConfig {
    fn default() -> Self {
        Self {
            cpu_warn_pct: default_cpu_warn(),
            cpu_crit_pct: default_cpu_crit(),
            cpu_duration_secs: default_cpu_duration(),
            mem_warn_pct: default_mem_warn(),
            mem_crit_pct: default_mem_crit(),
            mem_duration_secs: default_mem_duration(),
            disk_warn_pct: default_disk_warn(),
            disk_crit_pct: default_disk_crit(),
            oom_alerts_enabled: true,
            cooldown_secs: default_cooldown(),
            webhooks: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StreamMessage {
    Snapshot { data: HostSnapshot },
    Event { data: FleetEvent },
}
