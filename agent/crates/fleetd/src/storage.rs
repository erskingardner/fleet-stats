use crate::model::{
    AlertSeverity, EventKind, FleetEvent, HistoryPoint, HistoryResponse, HostSnapshot,
};
use rusqlite::{Connection, params};
use std::path::Path;
use std::sync::Mutex;

pub struct Storage {
    conn: Mutex<Connection>,
    raw_retention_ms: i64,
    rollup_retention_ms: i64,
    last_rollup_bucket: Mutex<i64>,
    last_prune_ms: Mutex<i64>,
}

impl Storage {
    pub fn open(
        path: &Path,
        raw_retention_hours: u64,
        rollup_retention_days: u64,
    ) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("failed creating db dir {}: {e}", parent.display()))?;
        }
        let conn = Connection::open(path)
            .map_err(|e| format!("failed opening sqlite db {}: {e}", path.display()))?;

        conn.execute_batch(
            "
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA temp_store = MEMORY;
            PRAGMA busy_timeout = 5000;

            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS samples_raw (
                ts INTEGER PRIMARY KEY,
                cpu_pct REAL NOT NULL,
                mem_used_pct REAL NOT NULL,
                mem_pressure_pct REAL NOT NULL,
                swap_used_pct REAL NOT NULL,
                disk_primary_pct REAL NOT NULL,
                disk_read_bps INTEGER NOT NULL,
                disk_write_bps INTEGER NOT NULL,
                net_up_bps INTEGER NOT NULL,
                net_down_bps INTEGER NOT NULL,
                top_cpu_proc TEXT,
                top_mem_proc TEXT
            );

            CREATE TABLE IF NOT EXISTS samples_1m (
                bucket_ts INTEGER PRIMARY KEY,
                sample_count INTEGER NOT NULL,
                cpu_avg REAL NOT NULL,
                cpu_max REAL NOT NULL,
                mem_avg REAL NOT NULL,
                mem_max REAL NOT NULL,
                mem_pressure_max REAL NOT NULL,
                swap_max REAL NOT NULL,
                disk_primary_max REAL NOT NULL,
                disk_read_bps INTEGER NOT NULL,
                disk_write_bps INTEGER NOT NULL,
                net_up_bps INTEGER NOT NULL,
                net_down_bps INTEGER NOT NULL,
                top_cpu_proc TEXT,
                top_mem_proc TEXT
            );

            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                kind TEXT NOT NULL,
                severity TEXT NOT NULL,
                metric TEXT,
                title TEXT NOT NULL,
                detail TEXT NOT NULL,
                process_name TEXT,
                process_pid INTEGER,
                value REAL
            );
            CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts DESC);
            ",
        )
        .map_err(|e| format!("failed initializing schema: {e}"))?;

        Ok(Self {
            conn: Mutex::new(conn),
            raw_retention_ms: (raw_retention_hours.max(1) as i64) * 3_600_000,
            rollup_retention_ms: (rollup_retention_days.max(1) as i64) * 86_400_000,
            last_rollup_bucket: Mutex::new(0),
            last_prune_ms: Mutex::new(0),
        })
    }

    /// Compare persisted boot_id with current boot_id. If changed and we had a recent
    /// heartbeat without clean shutdown, record an `UnexpectedReboot` forensics event.
    pub fn check_boot_and_record_startup(
        &self,
        boot_id: &str,
        now_ms: i64,
    ) -> Result<Option<FleetEvent>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let prev_boot: Option<String> = conn
            .query_row("SELECT value FROM meta WHERE key = 'boot_id'", [], |r| {
                r.get(0)
            })
            .ok();
        let prev_clean: Option<String> = conn
            .query_row(
                "SELECT value FROM meta WHERE key = 'clean_shutdown'",
                [],
                |r| r.get(0),
            )
            .ok();
        let prev_seen: Option<i64> = conn
            .query_row(
                "SELECT value FROM meta WHERE key = 'last_seen_ms'",
                [],
                |r| r.get::<_, String>(0),
            )
            .ok()
            .and_then(|s| s.parse().ok());

        conn.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('boot_id', ?1)",
            params![boot_id],
        )
        .map_err(|e| e.to_string())?;
        conn.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('clean_shutdown', '0')",
            [],
        )
        .map_err(|e| e.to_string())?;
        conn.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_seen_ms', ?1)",
            params![now_ms.to_string()],
        )
        .map_err(|e| e.to_string())?;

        if let Some(old_boot) = prev_boot {
            if old_boot != boot_id && prev_clean.as_deref() != Some("1") {
                // Find peak memory & top process from the last 5 minutes before last_seen
                let detail = if let Some(seen) = prev_seen {
                    let window_start = seen - 300_000;
                    let pre_crash: Option<(f64, Option<String>)> = conn
                        .query_row(
                            "SELECT MAX(mem_used_pct), top_mem_proc FROM samples_raw WHERE ts BETWEEN ?1 AND ?2 ORDER BY mem_used_pct DESC LIMIT 1",
                            params![window_start, seen],
                            |r| Ok((r.get::<_, Option<f64>>(0)?.unwrap_or(0.0), r.get(1)?)),
                        )
                        .ok();
                    if let Some((peak_mem, top_proc)) = pre_crash {
                        if peak_mem > 0.0 {
                            format!(
                                "System rebooted unexpectedly (previous boot ended cleanly=false). Peak RAM before crash: {:.1}%{}",
                                peak_mem,
                                top_proc
                                    .map(|p| format!(" (top process: {p})"))
                                    .unwrap_or_default()
                            )
                        } else {
                            "System rebooted unexpectedly since last fleetd heartbeat.".to_string()
                        }
                    } else {
                        "System rebooted unexpectedly since last fleetd heartbeat.".to_string()
                    }
                } else {
                    "System rebooted unexpectedly since last fleetd heartbeat.".to_string()
                };

                drop(conn);
                let ev = self.insert_event(
                    now_ms,
                    EventKind::UnexpectedReboot,
                    AlertSeverity::Critical,
                    Some("host"),
                    "Unexpected Reboot Detected",
                    &detail,
                    None,
                    None,
                    None,
                )?;
                return Ok(Some(ev));
            }
        }

        Ok(None)
    }

    pub fn mark_clean_shutdown(&self) {
        if let Ok(conn) = self.conn.lock() {
            let _ = conn.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('clean_shutdown', '1')",
                [],
            );
        }
    }

    pub fn record_snapshot(&self, snap: &HostSnapshot) -> Result<(), String> {
        let swap_pct = if snap.memory.swap_total_bytes > 0 {
            (snap.memory.swap_used_bytes as f64 / snap.memory.swap_total_bytes as f64) * 100.0
        } else {
            0.0
        };
        let top_cpu = snap.cpu.top_processes.first().map(|p| p.name.clone());
        let top_mem = snap.memory.top_processes.first().map(|p| p.name.clone());

        {
            let conn = self.conn.lock().map_err(|e| e.to_string())?;
            conn.execute(
                "INSERT OR REPLACE INTO samples_raw (
                    ts, cpu_pct, mem_used_pct, mem_pressure_pct, swap_used_pct,
                    disk_primary_pct, disk_read_bps, disk_write_bps,
                    net_up_bps, net_down_bps, top_cpu_proc, top_mem_proc
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![
                    snap.timestamp,
                    snap.cpu.total_pct,
                    snap.memory.used_pct,
                    snap.memory.pressure_pct,
                    swap_pct,
                    snap.disks.primary_used_pct,
                    snap.disks.total_read_bps as i64,
                    snap.disks.total_write_bps as i64,
                    snap.network.upload_bps as i64,
                    snap.network.download_bps as i64,
                    top_cpu,
                    top_mem,
                ],
            )
            .map_err(|e| format!("failed inserting raw sample: {e}"))?;

            // Update 1-minute rollup bucket incrementally
            let bucket_ts = (snap.timestamp / 60_000) * 60_000;
            let mut last_bucket = self.last_rollup_bucket.lock().map_err(|e| e.to_string())?;
            if bucket_ts >= *last_bucket {
                *last_bucket = bucket_ts;
                conn.execute(
                    "INSERT INTO samples_1m (
                        bucket_ts, sample_count, cpu_avg, cpu_max, mem_avg, mem_max,
                        mem_pressure_max, swap_max, disk_primary_max,
                        disk_read_bps, disk_write_bps, net_up_bps, net_down_bps,
                        top_cpu_proc, top_mem_proc
                    ) VALUES (?1, 1, ?2, ?2, ?3, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                    ON CONFLICT(bucket_ts) DO UPDATE SET
                        cpu_avg = ((cpu_avg * sample_count) + excluded.cpu_avg) / (sample_count + 1),
                        cpu_max = MAX(cpu_max, excluded.cpu_max),
                        mem_avg = ((mem_avg * sample_count) + excluded.mem_avg) / (sample_count + 1),
                        mem_max = MAX(mem_max, excluded.mem_max),
                        mem_pressure_max = MAX(mem_pressure_max, excluded.mem_pressure_max),
                        swap_max = MAX(swap_max, excluded.swap_max),
                        disk_primary_max = MAX(disk_primary_max, excluded.disk_primary_max),
                        disk_read_bps = ((disk_read_bps * sample_count) + excluded.disk_read_bps) / (sample_count + 1),
                        disk_write_bps = ((disk_write_bps * sample_count) + excluded.disk_write_bps) / (sample_count + 1),
                        net_up_bps = ((net_up_bps * sample_count) + excluded.net_up_bps) / (sample_count + 1),
                        net_down_bps = ((net_down_bps * sample_count) + excluded.net_down_bps) / (sample_count + 1),
                        top_cpu_proc = CASE WHEN excluded.cpu_max >= cpu_max THEN excluded.top_cpu_proc ELSE top_cpu_proc END,
                        top_mem_proc = CASE WHEN excluded.mem_max >= mem_max THEN excluded.top_mem_proc ELSE top_mem_proc END,
                        sample_count = sample_count + 1",
                    params![
                        bucket_ts,
                        snap.cpu.total_pct,
                        snap.memory.used_pct,
                        snap.memory.pressure_pct,
                        swap_pct,
                        snap.disks.primary_used_pct,
                        snap.disks.total_read_bps as i64,
                        snap.disks.total_write_bps as i64,
                        snap.network.upload_bps as i64,
                        snap.network.download_bps as i64,
                        top_cpu,
                        top_mem,
                    ],
                )
                .map_err(|e| format!("failed upserting 1m rollup: {e}"))?;
            }

            // Periodic heartbeat + retention prune (every 60s)
            let mut last_prune = self.last_prune_ms.lock().map_err(|e| e.to_string())?;
            if snap.timestamp - *last_prune >= 60_000 {
                *last_prune = snap.timestamp;
                let _ = conn.execute(
                    "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_seen_ms', ?1)",
                    params![snap.timestamp.to_string()],
                );
                let raw_cutoff = snap.timestamp - self.raw_retention_ms;
                let rollup_cutoff = snap.timestamp - self.rollup_retention_ms;
                let _ = conn.execute("DELETE FROM samples_raw WHERE ts < ?1", params![raw_cutoff]);
                let _ = conn.execute(
                    "DELETE FROM samples_1m WHERE bucket_ts < ?1",
                    params![rollup_cutoff],
                );
                let _ = conn.execute("DELETE FROM events WHERE ts < ?1", params![rollup_cutoff]);
            }
        }

        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn insert_event(
        &self,
        ts: i64,
        kind: EventKind,
        severity: AlertSeverity,
        metric: Option<&str>,
        title: &str,
        detail: &str,
        process_name: Option<&str>,
        process_pid: Option<u32>,
        value: Option<f64>,
    ) -> Result<FleetEvent, String> {
        let kind_str = serde_json::to_string(&kind)
            .unwrap_or_else(|_| "\"alert_triggered\"".to_string())
            .trim_matches('"')
            .to_string();
        let sev_str = serde_json::to_string(&severity)
            .unwrap_or_else(|_| "\"warning\"".to_string())
            .trim_matches('"')
            .to_string();

        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            "INSERT INTO events (ts, kind, severity, metric, title, detail, process_name, process_pid, value)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                ts,
                kind_str,
                sev_str,
                metric,
                title,
                detail,
                process_name,
                process_pid.map(|p| p as i64),
                value,
            ],
        )
        .map_err(|e| format!("failed inserting event: {e}"))?;
        let id = conn.last_insert_rowid();

        Ok(FleetEvent {
            id,
            timestamp: ts,
            kind,
            severity,
            metric: metric.map(String::from),
            title: title.to_string(),
            detail: detail.to_string(),
            process_name: process_name.map(String::from),
            process_pid,
            value,
        })
    }

    pub fn query_history(&self, window: &str, now_ms: i64) -> Result<HistoryResponse, String> {
        let (duration_ms, use_raw, resolution_secs) = match window {
            "15m" => (15 * 60_000_i64, true, 2),
            "1h" => (3_600_000_i64, true, 10),
            "6h" => (6 * 3_600_000_i64, false, 60),
            "24h" => (24 * 3_600_000_i64, false, 180),
            "7d" => (7 * 86_400_000_i64, false, 900),
            _ => (3_600_000_i64, true, 10),
        };
        let since = now_ms - duration_ms;
        let conn = self.conn.lock().map_err(|e| e.to_string())?;

        let mut raw_points: Vec<HistoryPoint> = if use_raw {
            let mut stmt = conn
                .prepare(
                    "SELECT ts, cpu_pct, mem_used_pct, mem_pressure_pct, swap_used_pct,
                            disk_primary_pct, disk_read_bps, disk_write_bps,
                            net_up_bps, net_down_bps, top_cpu_proc, top_mem_proc
                     FROM samples_raw WHERE ts >= ?1 ORDER BY ts ASC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![since], |r| {
                    let cpu: f64 = r.get(1)?;
                    let mem: f64 = r.get(2)?;
                    Ok(HistoryPoint {
                        timestamp: r.get(0)?,
                        cpu_pct: cpu,
                        cpu_max_pct: cpu,
                        mem_used_pct: mem,
                        mem_max_pct: mem,
                        mem_pressure_pct: r.get(3)?,
                        swap_used_pct: r.get(4)?,
                        disk_primary_pct: r.get(5)?,
                        disk_read_bps: r.get::<_, i64>(6)?.max(0) as u64,
                        disk_write_bps: r.get::<_, i64>(7)?.max(0) as u64,
                        net_up_bps: r.get::<_, i64>(8)?.max(0) as u64,
                        net_down_bps: r.get::<_, i64>(9)?.max(0) as u64,
                        top_cpu_proc: r.get(10)?,
                        top_mem_proc: r.get(11)?,
                    })
                })
                .map_err(|e| e.to_string())?;
            rows.filter_map(Result::ok).collect()
        } else {
            let mut stmt = conn
                .prepare(
                    "SELECT bucket_ts, cpu_avg, cpu_max, mem_avg, mem_max, mem_pressure_max,
                            swap_max, disk_primary_max, disk_read_bps, disk_write_bps,
                            net_up_bps, net_down_bps, top_cpu_proc, top_mem_proc
                     FROM samples_1m WHERE bucket_ts >= ?1 ORDER BY bucket_ts ASC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![since], |r| {
                    Ok(HistoryPoint {
                        timestamp: r.get(0)?,
                        cpu_pct: r.get(1)?,
                        cpu_max_pct: r.get(2)?,
                        mem_used_pct: r.get(3)?,
                        mem_max_pct: r.get(4)?,
                        mem_pressure_pct: r.get(5)?,
                        swap_used_pct: r.get(6)?,
                        disk_primary_pct: r.get(7)?,
                        disk_read_bps: r.get::<_, i64>(8)?.max(0) as u64,
                        disk_write_bps: r.get::<_, i64>(9)?.max(0) as u64,
                        net_up_bps: r.get::<_, i64>(10)?.max(0) as u64,
                        net_down_bps: r.get::<_, i64>(11)?.max(0) as u64,
                        top_cpu_proc: r.get(12)?,
                        top_mem_proc: r.get(13)?,
                    })
                })
                .map_err(|e| e.to_string())?;
            rows.filter_map(Result::ok).collect()
        };

        // Downsample to at most ~240 points so charts stay crisp and fast over mobile/Tailscale
        if raw_points.len() > 240 {
            raw_points = downsample_points(&raw_points, 240);
        }

        Ok(HistoryResponse {
            window: window.to_string(),
            resolution_secs,
            points: raw_points,
        })
    }

    pub fn query_events(&self, limit: usize) -> Result<Vec<FleetEvent>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare(
                "SELECT id, ts, kind, severity, metric, title, detail, process_name, process_pid, value
                 FROM events ORDER BY ts DESC LIMIT ?1",
            )
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map(params![limit.min(500) as i64], |r| {
                let kind_s: String = r.get(2)?;
                let sev_s: String = r.get(3)?;
                let kind = serde_json::from_str(&format!("\"{kind_s}\""))
                    .unwrap_or(EventKind::AlertTriggered);
                let severity = serde_json::from_str(&format!("\"{sev_s}\""))
                    .unwrap_or(AlertSeverity::Warning);
                Ok(FleetEvent {
                    id: r.get(0)?,
                    timestamp: r.get(1)?,
                    kind,
                    severity,
                    metric: r.get(4)?,
                    title: r.get(5)?,
                    detail: r.get(6)?,
                    process_name: r.get(7)?,
                    process_pid: r.get::<_, Option<i64>>(8)?.map(|p| p as u32),
                    value: r.get(9)?,
                })
            })
            .map_err(|e| e.to_string())?;

        Ok(rows.filter_map(Result::ok).collect())
    }
}

fn downsample_points(points: &[HistoryPoint], target: usize) -> Vec<HistoryPoint> {
    if points.len() <= target || target == 0 {
        return points.to_vec();
    }
    let chunk_size = (points.len() as f64 / target as f64).ceil() as usize;
    points
        .chunks(chunk_size.max(1))
        .map(|chunk| {
            let n = chunk.len() as f64;
            let last = &chunk[chunk.len() - 1];
            let peak_cpu_pt = chunk
                .iter()
                .max_by(|a, b| a.cpu_max_pct.total_cmp(&b.cpu_max_pct))
                .unwrap_or(last);
            let peak_mem_pt = chunk
                .iter()
                .max_by(|a, b| a.mem_max_pct.total_cmp(&b.mem_max_pct))
                .unwrap_or(last);
            HistoryPoint {
                timestamp: last.timestamp,
                cpu_pct: chunk.iter().map(|p| p.cpu_pct).sum::<f64>() / n,
                cpu_max_pct: peak_cpu_pt.cpu_max_pct,
                mem_used_pct: chunk.iter().map(|p| p.mem_used_pct).sum::<f64>() / n,
                mem_max_pct: peak_mem_pt.mem_max_pct,
                mem_pressure_pct: chunk
                    .iter()
                    .map(|p| p.mem_pressure_pct)
                    .fold(0.0, f64::max),
                swap_used_pct: chunk.iter().map(|p| p.swap_used_pct).fold(0.0, f64::max),
                disk_primary_pct: chunk
                    .iter()
                    .map(|p| p.disk_primary_pct)
                    .fold(0.0, f64::max),
                disk_read_bps: (chunk.iter().map(|p| p.disk_read_bps as u128).sum::<u128>()
                    / chunk.len() as u128) as u64,
                disk_write_bps: (chunk.iter().map(|p| p.disk_write_bps as u128).sum::<u128>()
                    / chunk.len() as u128) as u64,
                net_up_bps: (chunk.iter().map(|p| p.net_up_bps as u128).sum::<u128>()
                    / chunk.len() as u128) as u64,
                net_down_bps: (chunk.iter().map(|p| p.net_down_bps as u128).sum::<u128>()
                    / chunk.len() as u128) as u64,
                top_cpu_proc: peak_cpu_pt.top_cpu_proc.clone(),
                top_mem_proc: peak_mem_pt.top_mem_proc.clone(),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::*;

    fn sample_snapshot(ts: i64, cpu: f64, mem: f64) -> HostSnapshot {
        HostSnapshot {
            timestamp: ts,
            host: HostInfo {
                hostname: "test-box".into(),
                os: OsKind::Linux,
                os_version: "Debian 12".into(),
                arch: "x86_64".into(),
                uptime_secs: 100,
                boot_id: "boot-1".into(),
                cpu_model: "Test CPU".into(),
            },
            cpu: CpuMetrics {
                total_pct: cpu,
                user_pct: cpu,
                system_pct: 0.0,
                iowait_pct: 0.0,
                idle_pct: 100.0 - cpu,
                load_avg: [1.0, 1.0, 1.0],
                cores: vec![],
                top_processes: vec![ProcessCpu {
                    pid: 10,
                    name: "agent".into(),
                    user: "jeff".into(),
                    cpu_pct: cpu,
                    memory_bytes: 1024,
                }],
            },
            memory: MemoryMetrics {
                total_bytes: 1000,
                used_bytes: (mem * 10.0) as u64,
                used_pct: mem,
                app_bytes: (mem * 10.0) as u64,
                wired_bytes: 0,
                compressed_bytes: 0,
                cached_bytes: 0,
                free_bytes: 1000 - (mem * 10.0) as u64,
                swap_used_bytes: 0,
                swap_total_bytes: 0,
                pressure_level: PressureLevel::Normal,
                pressure_pct: mem,
                psi_some_avg10: None,
                psi_full_avg10: None,
                top_processes: vec![ProcessMemory {
                    pid: 10,
                    name: "leaky-worker".into(),
                    user: "jeff".into(),
                    memory_bytes: 900,
                    oom_score: Some(850),
                }],
            },
            disks: DiskMetrics {
                primary_used_pct: 55.0,
                total_read_bps: 100,
                total_write_bps: 200,
                volumes: vec![],
                top_processes: vec![],
            },
            network: NetworkMetrics {
                upload_bps: 300,
                download_bps: 400,
                interfaces: vec![],
                top_processes: vec![],
            },
            active_alerts: vec![],
        }
    }

    #[test]
    fn records_history_and_detects_unexpected_reboot() {
        let dir = std::env::temp_dir().join(format!("fleetd-test-{}", uuid::Uuid::new_v4()));
        let db = dir.join("test.db");
        let st = Storage::open(&db, 2, 7).expect("open db");

        let t0 = 1_700_000_000_000_i64;
        assert!(st.check_boot_and_record_startup("boot-1", t0).unwrap().is_none());
        st.record_snapshot(&sample_snapshot(t0 + 2_000, 40.0, 96.5)).unwrap();
        st.record_snapshot(&sample_snapshot(t0 + 4_000, 50.0, 98.2)).unwrap();

        let hist = st.query_history("1h", t0 + 5_000).unwrap();
        assert_eq!(hist.points.len(), 2);
        assert_eq!(hist.points[1].top_mem_proc.as_deref(), Some("leaky-worker"));

        // Simulate crash (no mark_clean_shutdown) + new boot_id
        let reboot_ev = st
            .check_boot_and_record_startup("boot-2", t0 + 30_000)
            .unwrap()
            .expect("should detect unexpected reboot");
        assert_eq!(reboot_ev.kind, EventKind::UnexpectedReboot);
        assert!(reboot_ev.detail.contains("leaky-worker"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
