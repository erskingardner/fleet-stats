use crate::collector::OomEvent;
use crate::model::{
    ActiveAlert, AlertConfig, AlertSeverity, EventKind, FleetEvent, HostSnapshot, PressureLevel,
    WebhookKind, WebhookTarget,
};
use crate::storage::Storage;
use std::collections::HashMap;
use std::sync::Arc;
use tracing::{info, warn};

struct RuleTracker {
    breach_since_ms: Option<i64>,
    active_severity: Option<AlertSeverity>,
    last_notified_ms: i64,
    triggered_at_ms: i64,
}

impl Default for RuleTracker {
    fn default() -> Self {
        Self {
            breach_since_ms: None,
            active_severity: None,
            last_notified_ms: 0,
            triggered_at_ms: 0,
        }
    }
}

pub struct AlertEngine {
    config: AlertConfig,
    trackers: HashMap<String, RuleTracker>,
    http: reqwest::Client,
}

impl AlertEngine {
    pub fn new(config: AlertConfig) -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(8))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap_or_default();
        Self {
            config,
            trackers: HashMap::new(),
            http,
        }
    }

    pub fn config(&self) -> &AlertConfig {
        &self.config
    }

    pub fn update_config(&mut self, config: AlertConfig) {
        self.config = config;
    }

    /// Evaluate sustained thresholds on a new snapshot plus any immediate OOM events.
    /// Returns `(active_alerts, newly_emitted_events)`.
    pub fn evaluate(
        &mut self,
        snap: &HostSnapshot,
        oom_events: &[OomEvent],
        storage: &Arc<Storage>,
    ) -> (Vec<ActiveAlert>, Vec<FleetEvent>) {
        let now_ms = snap.timestamp;
        let mut active = Vec::new();
        let mut emitted = Vec::new();

        // 1. CPU sustained rule
        let top_cpu_proc = snap
            .cpu
            .top_processes
            .first()
            .map(|p| format!("{} ({:.0}%)", p.name, p.cpu_pct));
        self.check_threshold(
            "cpu",
            "cpu",
            "High CPU Load",
            snap.cpu.total_pct,
            self.config.cpu_warn_pct,
            self.config.cpu_crit_pct,
            self.config.cpu_duration_secs,
            now_ms,
            &snap.host.hostname,
            top_cpu_proc,
            storage,
            &mut active,
            &mut emitted,
        );

        // 2. Memory & Memory Pressure sustained rule
        let top_mem_proc = snap
            .memory
            .top_processes
            .first()
            .map(|p| format!("{} ({})", p.name, format_bytes(p.memory_bytes)));
        let effective_mem_pct = match snap.memory.pressure_level {
            PressureLevel::Critical => snap.memory.used_pct.max(self.config.mem_crit_pct),
            PressureLevel::Warn => snap.memory.used_pct.max(self.config.mem_warn_pct),
            PressureLevel::Normal => snap.memory.used_pct,
        };
        self.check_threshold(
            "memory",
            "memory",
            "High Memory Pressure",
            effective_mem_pct,
            self.config.mem_warn_pct,
            self.config.mem_crit_pct,
            self.config.mem_duration_secs,
            now_ms,
            &snap.host.hostname,
            top_mem_proc,
            storage,
            &mut active,
            &mut emitted,
        );

        // 3. Per-volume disk space rules (immediate once crossed, with cooldown)
        for vol in &snap.disks.volumes {
            let key = format!("disk:{}", vol.mount_point);
            let title = format!("Low Disk Space ({})", vol.name);
            self.check_threshold(
                &key,
                "disk",
                &title,
                vol.used_pct,
                self.config.disk_warn_pct,
                self.config.disk_crit_pct,
                0,
                now_ms,
                &snap.host.hostname,
                Some(format!("{} free", format_bytes(vol.free_bytes))),
                storage,
                &mut active,
                &mut emitted,
            );
        }

        // 5. Immediate Linux OOM Killer events
        if self.config.oom_alerts_enabled {
            for oom in oom_events {
                let title = match &oom.process_name {
                    Some(name) => format!("OOM Killer Terminated {name}"),
                    None => "Linux OOM Killer Triggered".to_string(),
                };
                if let Ok(ev) = storage.insert_event(
                    now_ms,
                    EventKind::OomKill,
                    AlertSeverity::Critical,
                    Some("oom"),
                    &title,
                    &oom.detail,
                    oom.process_name.as_deref(),
                    oom.pid,
                    Some(snap.memory.used_pct),
                ) {
                    self.dispatch_webhooks(&snap.host.hostname, &ev);
                    emitted.push(ev);
                }
            }
        }

        (active, emitted)
    }

    #[allow(clippy::too_many_arguments)]
    fn check_threshold(
        &mut self,
        id: &str,
        metric: &str,
        title: &str,
        value: f64,
        warn_thresh: f64,
        crit_thresh: f64,
        duration_secs: u64,
        now_ms: i64,
        hostname: &str,
        top_process: Option<String>,
        storage: &Arc<Storage>,
        active: &mut Vec<ActiveAlert>,
        emitted: &mut Vec<FleetEvent>,
    ) {
        let desired_severity = if value >= crit_thresh {
            Some((AlertSeverity::Critical, crit_thresh))
        } else if value >= warn_thresh {
            Some((AlertSeverity::Warning, warn_thresh))
        } else {
            None
        };

        let cooldown_ms = (self.config.cooldown_secs as i64) * 1000;
        let duration_ms = (duration_secs as i64) * 1000;
        let mut webhook_event: Option<FleetEvent> = None;

        {
            let tracker = self.trackers.entry(id.to_string()).or_default();

            match desired_severity {
                Some((sev, thresh)) => {
                    let since = *tracker.breach_since_ms.get_or_insert(now_ms);
                    if now_ms - since >= duration_ms {
                        let escalated = tracker
                            .active_severity
                            .map(|prev| sev > prev)
                            .unwrap_or(true);
                        let cooldown_elapsed = now_ms - tracker.last_notified_ms >= cooldown_ms;

                        if tracker.active_severity.is_none() {
                            tracker.triggered_at_ms = now_ms;
                        }

                        if escalated || (tracker.active_severity.is_none() && cooldown_elapsed) {
                            tracker.active_severity = Some(sev);
                            tracker.last_notified_ms = now_ms;
                            let detail = format!(
                                "{title} at {:.1}% (threshold {:.0}%){}",
                                value,
                                thresh,
                                top_process
                                    .as_ref()
                                    .map(|p| format!(" — top: {p}"))
                                    .unwrap_or_default()
                            );
                            if let Ok(ev) = storage.insert_event(
                                now_ms,
                                EventKind::AlertTriggered,
                                sev,
                                Some(metric),
                                title,
                                &detail,
                                top_process.as_deref(),
                                None,
                                Some(value),
                            ) {
                                webhook_event = Some(ev.clone());
                                emitted.push(ev);
                            }
                        } else {
                            tracker.active_severity = Some(sev);
                        }

                        let detail = format!(
                            "{:.1}% (threshold {:.0}%){}",
                            value,
                            thresh,
                            top_process
                                .as_ref()
                                .map(|p| format!(" · {p}"))
                                .unwrap_or_default()
                        );
                        active.push(ActiveAlert {
                            id: id.to_string(),
                            metric: metric.to_string(),
                            severity: sev,
                            title: title.to_string(),
                            detail,
                            value,
                            threshold: thresh,
                            triggered_at: tracker.triggered_at_ms,
                            top_process,
                        });
                    }
                }
                None => {
                    // Hysteresis: clear when value drops 3% below warning threshold
                    if value < (warn_thresh - 3.0).max(0.0) {
                        if let Some(prev_sev) = tracker.active_severity.take() {
                            let detail = format!("{title} recovered (now {:.1}%)", value);
                            if let Ok(ev) = storage.insert_event(
                                now_ms,
                                EventKind::AlertResolved,
                                AlertSeverity::Info,
                                Some(metric),
                                &format!("Resolved: {title}"),
                                &detail,
                                None,
                                None,
                                Some(value),
                            ) {
                                if prev_sev >= AlertSeverity::Critical {
                                    webhook_event = Some(ev.clone());
                                }
                                emitted.push(ev);
                            }
                        }
                        tracker.breach_since_ms = None;
                    } else if let Some(sev) = tracker.active_severity {
                        active.push(ActiveAlert {
                            id: id.to_string(),
                            metric: metric.to_string(),
                            severity: sev,
                            title: title.to_string(),
                            detail: format!("{:.1}%", value),
                            value,
                            threshold: warn_thresh,
                            triggered_at: tracker.triggered_at_ms,
                            top_process,
                        });
                    }
                }
            }
        }

        if let Some(ev) = webhook_event {
            self.dispatch_webhooks(hostname, &ev);
        }
    }

    fn dispatch_webhooks(&self, hostname: &str, event: &FleetEvent) {
        for target in &self.config.webhooks {
            if !target.enabled {
                continue;
            }
            if event.kind != EventKind::AlertResolved && event.severity < target.min_severity {
                continue;
            }
            let client = self.http.clone();
            let target = target.clone();
            let host = hostname.to_string();
            let ev = event.clone();
            tokio::spawn(async move {
                if let Err(err) = send_webhook(&client, &target, &host, &ev).await {
                    warn!(webhook = %target.name, error = %err, "failed sending alert webhook");
                } else {
                    info!(webhook = %target.name, event = %ev.title, "dispatched alert webhook");
                }
            });
        }
    }
}

async fn send_webhook(
    client: &reqwest::Client,
    target: &WebhookTarget,
    hostname: &str,
    ev: &FleetEvent,
) -> Result<(), String> {
    let header_title = format!("[{hostname}] {}", ev.title);
    match target.kind {
        WebhookKind::Ntfy => {
            let priority = match ev.severity {
                AlertSeverity::Critical => "urgent",
                AlertSeverity::Warning => "high",
                AlertSeverity::Info => "default",
            };
            let mut req = client
                .post(&target.url)
                .header("Title", header_title)
                .header("Priority", priority)
                .body(ev.detail.clone());
            if let Some(tok) = &target.token_or_key {
                if !tok.is_empty() {
                    req = req.bearer_auth(tok);
                }
            }
            req.send()
                .await
                .map_err(|e| e.to_string())?
                .error_for_status()
                .map_err(|e| e.to_string())?;
        }
        WebhookKind::Pushover => {
            let url = if target.url.is_empty() {
                "https://api.pushover.net/1/messages.json"
            } else {
                &target.url
            };
            let priority = if ev.severity == AlertSeverity::Critical {
                "1"
            } else {
                "0"
            };
            let payload = serde_json::json!({
                "token": target.token_or_key.clone().unwrap_or_default(),
                "user": target.user_key.clone().unwrap_or_default(),
                "title": header_title,
                "message": ev.detail,
                "priority": priority,
            });
            client
                .post(url)
                .json(&payload)
                .send()
                .await
                .map_err(|e| e.to_string())?
                .error_for_status()
                .map_err(|e| e.to_string())?;
        }
        WebhookKind::Discord => {
            let color = match ev.severity {
                AlertSeverity::Critical => 0xEF4444_u32,
                AlertSeverity::Warning => 0xF59E0B_u32,
                AlertSeverity::Info => 0x22C55E_u32,
            };
            let payload = serde_json::json!({
                "embeds": [{
                    "title": header_title,
                    "description": ev.detail,
                    "color": color,
                }]
            });
            client
                .post(&target.url)
                .json(&payload)
                .send()
                .await
                .map_err(|e| e.to_string())?
                .error_for_status()
                .map_err(|e| e.to_string())?;
        }
        WebhookKind::Generic => {
            let payload = serde_json::json!({
                "hostname": hostname,
                "event": ev,
            });
            let mut req = client.post(&target.url).json(&payload);
            if let Some(tok) = &target.token_or_key {
                if !tok.is_empty() {
                    req = req.bearer_auth(tok);
                }
            }
            req.send()
                .await
                .map_err(|e| e.to_string())?
                .error_for_status()
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut val = bytes as f64;
    let mut idx = 0;
    while val >= 1024.0 && idx < UNITS.len() - 1 {
        val /= 1024.0;
        idx += 1;
    }
    if idx <= 1 {
        format!("{:.0} {}", val, UNITS[idx])
    } else {
        format!("{:.1} {}", val, UNITS[idx])
    }
}

/// Validate webhook targets to block SSRF against localhost, metadata IPs, or plaintext endpoints.
pub fn validate_alert_config(cfg: &AlertConfig) -> Result<(), String> {
    if cfg.webhooks.len() > 8 {
        return Err("at most 8 webhooks are allowed".to_string());
    }
    for wh in &cfg.webhooks {
        if wh.kind == WebhookKind::Pushover && wh.url.trim().is_empty() {
            continue;
        }
        validate_webhook_url(&wh.url)?;
    }
    Ok(())
}

pub fn validate_webhook_url(raw: &str) -> Result<(), String> {
    let parsed = reqwest::Url::parse(raw.trim())
        .map_err(|_| format!("invalid webhook URL: {raw}"))?;
    if parsed.scheme() != "https" {
        return Err("webhook URLs must use https://".to_string());
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| "webhook URL must include a host".to_string())?
        .to_ascii_lowercase();
    if host == "localhost"
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || host.ends_with(".internal")
    {
        return Err(format!("webhook host '{host}' is not allowed"));
    }
    if let Ok(ip) = host.trim_matches(|c| c == '[' || c == ']').parse::<std::net::IpAddr>() {
        if is_private_or_special_ip(ip) {
            return Err(format!("webhook IP '{ip}' is not allowed"));
        }
    }
    Ok(())
}

fn is_private_or_special_ip(ip: std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_unspecified()
                || v4.is_multicast()
                || (o[0] == 100 && (64..=127).contains(&o[1]))
        }
        std::net::IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_private_or_special_ip(std::net::IpAddr::V4(v4));
            }
            let seg = v6.segments();
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (seg[0] & 0xfe00) == 0xfc00 // ULA fc00::/7
                || (seg[0] & 0xffc0) == 0xfe80 // Link-local fe80::/10
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn webhook_ssrf_validation() {
        assert!(validate_webhook_url("https://ntfy.sh/my-fleet-alerts").is_ok());
        assert!(validate_webhook_url("https://discord.com/api/webhooks/123/abc").is_ok());

        assert!(validate_webhook_url("http://ntfy.sh/my-fleet-alerts").is_err());
        assert!(validate_webhook_url("https://127.0.0.1:8080/hook").is_err());
        assert!(validate_webhook_url("https://localhost/hook").is_err());
        assert!(validate_webhook_url("https://169.254.169.254/latest/meta-data/").is_err());
        assert!(validate_webhook_url("https://10.0.0.1/internal").is_err());
        assert!(validate_webhook_url("https://100.64.1.2/tailnet").is_err());
    }
}
