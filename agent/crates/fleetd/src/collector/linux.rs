use crate::collector::{CollectionResult, OomEvent, PlatformCollector, username_for_uid};
use crate::model::{
    CoreKind, CoreUsage, CpuMetrics, DiskMetrics, DiskVolume, HostInfo, HostSnapshot,
    MemoryMetrics, NetworkInterface, NetworkMetrics, OsKind, PressureLevel, ProcessCpu,
    ProcessDiskIo, ProcessMemory, ProcessNetIo,
};
use chrono::Utc;
use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::fs;
use std::mem::{size_of, zeroed};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::path::Path;
use std::process::Command;
use std::time::Instant;

struct PrevProc {
    cpu_jiffies: u64,
    disk_read: u64,
    disk_write: u64,
}

#[derive(Default, Clone, Copy)]
struct CpuTicks {
    user: u64,
    nice: u64,
    system: u64,
    idle: u64,
    iowait: u64,
    irq: u64,
    softirq: u64,
    steal: u64,
}

impl CpuTicks {
    fn total(&self) -> u64 {
        self.user
            + self.nice
            + self.system
            + self.idle
            + self.iowait
            + self.irq
            + self.softirq
            + self.steal
    }
    fn active(&self) -> u64 {
        self.total().saturating_sub(self.idle + self.iowait)
    }
}

pub struct LinuxCollector {
    hostname: String,
    os_version: String,
    arch: String,
    cpu_model: String,
    boot_id: String,
    clk_tck: f64,
    page_size: u64,

    prev_sample_at: Option<Instant>,
    prev_total_ticks: Option<CpuTicks>,
    prev_core_ticks: Vec<CpuTicks>,
    prev_procs: HashMap<u32, PrevProc>,
    prev_disk_io: HashMap<String, (u64, u64)>,
    prev_if_bytes: HashMap<String, (u64, u64)>,
    prev_proc_net: HashMap<u32, (u64, u64)>,
    last_oom_kill_count: Option<u64>,
}

impl LinuxCollector {
    pub fn new() -> Self {
        let hostname = read_trimmed("/etc/hostname")
            .or_else(|| read_trimmed("/proc/sys/kernel/hostname"))
            .unwrap_or_else(|| "linux-host".to_string());
        let os_version = read_linux_os_pretty_name();
        let arch = std::env::consts::ARCH.to_string();
        let cpu_model = read_linux_cpu_model().unwrap_or_else(|| format!("Linux ({arch})"));
        let boot_id = read_trimmed("/proc/sys/kernel/random/boot_id")
            .unwrap_or_else(|| format!("linux-boot-{}", Utc::now().timestamp()));
        let clk_tck = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as f64;
        let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) }.max(4096) as u64;
        let last_oom_kill_count = read_vmstat_oom_kills();

        Self {
            hostname,
            os_version,
            arch,
            cpu_model,
            boot_id,
            clk_tck,
            page_size,
            prev_sample_at: None,
            prev_total_ticks: None,
            prev_core_ticks: Vec::new(),
            prev_procs: HashMap::new(),
            prev_disk_io: HashMap::new(),
            prev_if_bytes: HashMap::new(),
            prev_proc_net: HashMap::new(),
            last_oom_kill_count,
        }
    }

    fn collect_cpu(&mut self) -> (f64, f64, f64, f64, f64, Vec<CoreUsage>) {
        let content = fs::read_to_string("/proc/stat").unwrap_or_default();
        let mut total_ticks = None;
        let mut core_ticks = Vec::new();

        for line in content.lines() {
            if line.starts_with("cpu ") {
                total_ticks = parse_cpu_line(line);
            } else if line.starts_with("cpu") {
                if let Some(t) = parse_cpu_line(line) {
                    core_ticks.push(t);
                }
            }
        }

        let (total_pct, user_pct, system_pct, iowait_pct, idle_pct) =
            match (total_ticks, self.prev_total_ticks) {
                (Some(cur), Some(prev)) => {
                    let dt = cur.total().saturating_sub(prev.total());
                    if dt > 0 {
                        let d_user = cur
                            .user
                            .saturating_sub(prev.user)
                            .saturating_add(cur.nice.saturating_sub(prev.nice));
                        let d_sys = cur
                            .system
                            .saturating_sub(prev.system)
                            .saturating_add(cur.irq.saturating_sub(prev.irq))
                            .saturating_add(cur.softirq.saturating_sub(prev.softirq))
                            .saturating_add(cur.steal.saturating_sub(prev.steal));
                        let d_io = cur.iowait.saturating_sub(prev.iowait);
                        let d_idle = cur.idle.saturating_sub(prev.idle);
                        let user_p = clamp_pct((d_user as f64 / dt as f64) * 100.0);
                        let sys_p = clamp_pct((d_sys as f64 / dt as f64) * 100.0);
                        let io_p = clamp_pct((d_io as f64 / dt as f64) * 100.0);
                        let idle_p = clamp_pct((d_idle as f64 / dt as f64) * 100.0);
                        let tot_p = clamp_pct(user_p + sys_p + io_p);
                        (tot_p, user_p, sys_p, io_p, idle_p)
                    } else {
                        (0.0, 0.0, 0.0, 0.0, 100.0)
                    }
                }
                _ => (0.0, 0.0, 0.0, 0.0, 100.0),
            };
        self.prev_total_ticks = total_ticks;

        let mut cores = Vec::with_capacity(core_ticks.len());
        for (idx, cur) in core_ticks.iter().enumerate() {
            let pct = if let Some(prev) = self.prev_core_ticks.get(idx) {
                let dt = cur.total().saturating_sub(prev.total());
                let da = cur.active().saturating_sub(prev.active());
                if dt > 0 {
                    clamp_pct((da as f64 / dt as f64) * 100.0)
                } else {
                    0.0
                }
            } else {
                0.0
            };
            cores.push(CoreUsage {
                index: idx,
                usage_pct: pct,
                kind: CoreKind::Standard,
            });
        }
        self.prev_core_ticks = core_ticks;

        (total_pct, user_pct, system_pct, iowait_pct, idle_pct, cores)
    }

    fn collect_processes(
        &mut self,
        dt_secs: f64,
    ) -> (
        Vec<ProcessCpu>,
        Vec<ProcessMemory>,
        Vec<ProcessDiskIo>,
        HashMap<u64, (u32, String, String)>,
    ) {
        let mut next_prev = HashMap::new();
        let mut uid_cache: HashMap<u32, String> = HashMap::new();
        let mut cpu_list = Vec::new();
        let mut mem_list = Vec::new();
        let mut disk_list = Vec::new();
        let mut inode_to_proc: HashMap<u64, (u32, String, String)> = HashMap::new();

        let entries = match fs::read_dir("/proc") {
            Ok(e) => e,
            Err(_) => return (cpu_list, mem_list, disk_list, inode_to_proc),
        };

        for entry in entries.flatten() {
            let fname = entry.file_name();
            let pid: u32 = match fname.to_str().and_then(|s| s.parse().ok()) {
                Some(p) => p,
                None => continue,
            };

            let proc_dir = entry.path();
            let stat_str = match fs::read_to_string(proc_dir.join("stat")) {
                Ok(s) => s,
                Err(_) => continue,
            };
            let (name, utime, stime, rss_pages) = match parse_proc_stat(&stat_str) {
                Some(v) => v,
                None => continue,
            };

            let uid = read_proc_uid(&proc_dir).unwrap_or(0);
            let user = uid_cache
                .entry(uid)
                .or_insert_with(|| username_for_uid(uid))
                .clone();

            let cpu_jiffies = utime.saturating_add(stime);
            let mem_bytes = rss_pages.saturating_mul(self.page_size);
            let oom_score = fs::read_to_string(proc_dir.join("oom_score"))
                .ok()
                .and_then(|s| s.trim().parse::<i32>().ok());

            let (disk_read, disk_write) = read_proc_io(&proc_dir).unwrap_or((0, 0));

            if let Some(prev) = self.prev_procs.get(&pid) {
                if dt_secs > 0.05 {
                    let d_jiffies = cpu_jiffies.saturating_sub(prev.cpu_jiffies);
                    let cpu_secs = d_jiffies as f64 / self.clk_tck;
                    let cpu_pct = (cpu_secs / dt_secs) * 100.0;
                    if cpu_pct >= 0.05 {
                        cpu_list.push(ProcessCpu {
                            pid,
                            name: name.clone(),
                            user: user.clone(),
                            cpu_pct,
                            memory_bytes: mem_bytes,
                        });
                    }

                    let r_bps = (disk_read.saturating_sub(prev.disk_read) as f64 / dt_secs) as u64;
                    let w_bps =
                        (disk_write.saturating_sub(prev.disk_write) as f64 / dt_secs) as u64;
                    let total_bps = r_bps.saturating_add(w_bps);
                    if total_bps > 0 {
                        disk_list.push(ProcessDiskIo {
                            pid,
                            name: name.clone(),
                            user: user.clone(),
                            read_bps: r_bps,
                            write_bps: w_bps,
                            total_bps,
                        });
                    }
                }
            }

            if mem_bytes > 0 {
                mem_list.push(ProcessMemory {
                    pid,
                    name: name.clone(),
                    user: user.clone(),
                    memory_bytes: mem_bytes,
                    oom_score,
                });
            }

            // Map open socket inodes to PID for per-process TCP network accounting
            if let Ok(fd_dir) = fs::read_dir(proc_dir.join("fd")) {
                for fd in fd_dir.flatten() {
                    if let Ok(target) = fs::read_link(fd.path()) {
                        if let Some(s) = target.to_str() {
                            if let Some(rest) = s.strip_prefix("socket:[") {
                                if let Some(inode_s) = rest.strip_suffix(']') {
                                    if let Ok(inode) = inode_s.parse::<u64>() {
                                        inode_to_proc
                                            .insert(inode, (pid, name.clone(), user.clone()));
                                    }
                                }
                            }
                        }
                    }
                }
            }

            next_prev.insert(
                pid,
                PrevProc {
                    cpu_jiffies,
                    disk_read,
                    disk_write,
                },
            );
        }

        self.prev_procs = next_prev;

        cpu_list.sort_by(|a, b| b.cpu_pct.total_cmp(&a.cpu_pct));
        cpu_list.truncate(12);

        mem_list.sort_by(|a, b| b.memory_bytes.cmp(&a.memory_bytes));
        mem_list.truncate(12);

        disk_list.sort_by(|a, b| b.total_bps.cmp(&a.total_bps));
        disk_list.truncate(12);

        (cpu_list, mem_list, disk_list, inode_to_proc)
    }

    fn collect_memory(&self, top_processes: Vec<ProcessMemory>) -> MemoryMetrics {
        let info = parse_meminfo();
        let total = info.get("MemTotal").copied().unwrap_or(0);
        let mem_avail = info
            .get("MemAvailable")
            .copied()
            .unwrap_or_else(|| info.get("MemFree").copied().unwrap_or(0));
        let mem_free = info.get("MemFree").copied().unwrap_or(0);
        let buffers = info.get("Buffers").copied().unwrap_or(0);
        let cached = info.get("Cached").copied().unwrap_or(0);
        let sreclaim = info.get("SReclaimable").copied().unwrap_or(0);
        let shmem = info.get("Shmem").copied().unwrap_or(0);
        let slab_unreclaim = info.get("SUnreclaim").copied().unwrap_or(0);
        let kstack = info.get("KernelStack").copied().unwrap_or(0);
        let pagetables = info.get("PageTables").copied().unwrap_or(0);
        let zswap = info.get("Zswap").copied().unwrap_or(0);
        let swap_total = info.get("SwapTotal").copied().unwrap_or(0);
        let swap_free = info.get("SwapFree").copied().unwrap_or(0);
        let swap_used = swap_total.saturating_sub(swap_free);

        let used_bytes = total.saturating_sub(mem_avail);
        let used_pct = if total > 0 {
            clamp_pct((used_bytes as f64 / total as f64) * 100.0)
        } else {
            0.0
        };

        let wired_bytes = slab_unreclaim
            .saturating_add(kstack)
            .saturating_add(pagetables);
        let compressed_bytes = zswap;
        let cached_bytes = buffers
            .saturating_add(cached)
            .saturating_add(sreclaim)
            .saturating_sub(shmem);
        let app_bytes = info
            .get("AnonPages")
            .copied()
            .unwrap_or_else(|| used_bytes.saturating_sub(wired_bytes + compressed_bytes))
            .saturating_add(shmem);

        let (psi_some, psi_full) = read_linux_memory_psi();

        let pressure_pct = {
            let psi_score = psi_full.unwrap_or(0.0) * 3.0 + psi_some.unwrap_or(0.0) * 1.2;
            let avail_pressure = used_pct;
            clamp_pct(avail_pressure.max(psi_score))
        };

        let pressure_level = if psi_full.unwrap_or(0.0) >= 15.0 || used_pct >= 92.0 {
            PressureLevel::Critical
        } else if psi_some.unwrap_or(0.0) >= 20.0 || used_pct >= 82.0 {
            PressureLevel::Warn
        } else {
            PressureLevel::Normal
        };

        MemoryMetrics {
            total_bytes: total,
            used_bytes,
            used_pct,
            app_bytes,
            wired_bytes,
            compressed_bytes,
            cached_bytes,
            free_bytes: mem_free,
            swap_used_bytes: swap_used,
            swap_total_bytes: swap_total,
            pressure_level,
            pressure_pct,
            psi_some_avg10: psi_some,
            psi_full_avg10: psi_full,
            top_processes,
        }
    }

    fn collect_disks(&mut self, dt_secs: f64, top_processes: Vec<ProcessDiskIo>) -> DiskMetrics {
        let diskstats = read_linux_diskstats();
        let mut dev_rates: HashMap<String, (u64, u64)> = HashMap::new();
        let mut total_read_bps = 0_u64;
        let mut total_write_bps = 0_u64;

        for (dev, (r_bytes, w_bytes, is_whole_disk)) in &diskstats {
            if let Some((pr, pw)) = self.prev_disk_io.get(dev) {
                if dt_secs > 0.05 {
                    let r_bps = (r_bytes.saturating_sub(*pr) as f64 / dt_secs) as u64;
                    let w_bps = (w_bytes.saturating_sub(*pw) as f64 / dt_secs) as u64;
                    dev_rates.insert(dev.clone(), (r_bps, w_bps));
                    if *is_whole_disk {
                        total_read_bps = total_read_bps.saturating_add(r_bps);
                        total_write_bps = total_write_bps.saturating_add(w_bps);
                    }
                }
            }
        }
        self.prev_disk_io = diskstats
            .into_iter()
            .map(|(k, (r, w, _))| (k, (r, w)))
            .collect();

        let mut volumes = Vec::new();
        let mut seen_devs: HashSet<String> = HashSet::new();
        let mounts = fs::read_to_string("/proc/mounts").unwrap_or_default();

        for line in mounts.lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() < 3 {
                continue;
            }
            let dev = parts[0];
            let mount = unescape_mount_path(parts[1]);
            let fstype = parts[2];

            if !dev.starts_with("/dev/") {
                continue;
            }
            if matches!(
                fstype,
                "squashfs" | "tmpfs" | "devtmpfs" | "overlay" | "proc" | "sysfs" | "iso9660"
            ) {
                continue;
            }
            if mount.starts_with("/snap/") || mount.starts_with("/boot/efi") {
                continue;
            }
            // Deduplicate bind mounts pointing to the same block device
            if !seen_devs.insert(dev.to_string()) {
                continue;
            }

            let Some((total, used, free)) = statvfs_bytes(&mount) else {
                continue;
            };
            if total == 0 {
                continue;
            }

            let is_primary = mount == "/";
            let block_name = dev.trim_start_matches("/dev/");
            let base_disk = linux_base_block_device(block_name);
            let is_removable = is_linux_removable_disk(&base_disk);
            let is_external = !is_primary
                && (is_removable
                    || mount.starts_with("/media/")
                    || mount.starts_with("/run/media/")
                    || mount.starts_with("/mnt/"));

            let (read_bps, write_bps) = dev_rates
                .get(block_name)
                .or_else(|| dev_rates.get(&base_disk))
                .copied()
                .unwrap_or((0, 0));

            let name = if is_primary {
                "Root (/)".to_string()
            } else {
                Path::new(&mount)
                    .file_name()
                    .and_then(|n| n.to_str())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| mount.clone())
            };

            volumes.push(DiskVolume {
                id: dev.to_string(),
                name,
                mount_point: mount,
                filesystem: fstype.to_string(),
                is_external,
                is_primary,
                total_bytes: total,
                used_bytes: used,
                free_bytes: free,
                used_pct: clamp_pct((used as f64 / total as f64) * 100.0),
                read_bps,
                write_bps,
            });
        }

        volumes.sort_by(|a, b| {
            b.is_primary
                .cmp(&a.is_primary)
                .then_with(|| a.is_external.cmp(&b.is_external))
                .then_with(|| a.mount_point.cmp(&b.mount_point))
        });

        let primary_used_pct = volumes
            .iter()
            .find(|v| v.is_primary)
            .or_else(|| volumes.first())
            .map(|v| v.used_pct)
            .unwrap_or(0.0);

        DiskMetrics {
            primary_used_pct,
            total_read_bps,
            total_write_bps,
            volumes,
            top_processes,
        }
    }

    fn collect_network(
        &mut self,
        dt_secs: f64,
        inode_to_proc: &HashMap<u64, (u32, String, String)>,
    ) -> NetworkMetrics {
        let dev_bytes = read_linux_net_dev();
        let if_addrs = read_linux_ifaddrs();

        let mut total_up = 0_u64;
        let mut total_down = 0_u64;
        let mut interfaces = Vec::new();
        let mut next_prev_if = HashMap::new();

        for (name, (rx, tx)) in dev_bytes {
            if name == "lo"
                || name.starts_with("veth")
                || name.starts_with("docker")
                || name.starts_with("br-")
                || name.starts_with("virbr")
            {
                continue;
            }
            let (is_up, ipv4, ipv6) = if_addrs
                .get(&name)
                .cloned()
                .unwrap_or((false, Vec::new(), Vec::new()));

            let (down_bps, up_bps) = if let Some((prx, ptx)) = self.prev_if_bytes.get(&name) {
                if dt_secs > 0.05 {
                    (
                        (rx.saturating_sub(*prx) as f64 / dt_secs) as u64,
                        (tx.saturating_sub(*ptx) as f64 / dt_secs) as u64,
                    )
                } else {
                    (0, 0)
                }
            } else {
                (0, 0)
            };
            next_prev_if.insert(name.clone(), (rx, tx));

            let is_physical = Path::new(&format!("/sys/class/net/{name}/device")).exists();
            if is_physical && is_up {
                total_down = total_down.saturating_add(down_bps);
                total_up = total_up.saturating_add(up_bps);
            }

            let display_name = if name == "tailscale0" {
                "Tailscale".to_string()
            } else if name.starts_with("wl") {
                format!("Wi-Fi ({name})")
            } else if name.starts_with("en") || name.starts_with("eth") {
                format!("Ethernet ({name})")
            } else {
                name.clone()
            };

            interfaces.push(NetworkInterface {
                name,
                display_name,
                is_up,
                is_physical,
                ipv4,
                ipv6,
                upload_bps: up_bps,
                download_bps: down_bps,
            });
        }
        self.prev_if_bytes = next_prev_if;

        interfaces.sort_by(|a, b| {
            b.is_up
                .cmp(&a.is_up)
                .then_with(|| b.is_physical.cmp(&a.is_physical))
                .then_with(|| a.name.cmp(&b.name))
        });

        let top_processes = self.collect_linux_net_top_processes(dt_secs, inode_to_proc);

        NetworkMetrics {
            upload_bps: total_up,
            download_bps: total_down,
            interfaces,
            top_processes,
        }
    }

    /// Queries Linux kernel `SOCK_DIAG` netlink for per-TCP-socket `tcpi_bytes_sent` &
    /// `tcpi_bytes_received`, maps socket inodes to PIDs, and computes per-process up/down B/s.
    fn collect_linux_net_top_processes(
        &mut self,
        dt_secs: f64,
        inode_to_proc: &HashMap<u64, (u32, String, String)>,
    ) -> Vec<ProcessNetIo> {
        let sock_totals = query_inet_diag_tcp_bytes();
        let mut proc_totals: HashMap<u32, (String, String, u64, u64)> = HashMap::new();

        for (inode, (rx, tx)) in sock_totals {
            if let Some((pid, name, user)) = inode_to_proc.get(&inode) {
                let entry = proc_totals
                    .entry(*pid)
                    .or_insert_with(|| (name.clone(), user.clone(), 0, 0));
                entry.2 = entry.2.saturating_add(rx);
                entry.3 = entry.3.saturating_add(tx);
            }
        }

        let mut next_prev = HashMap::with_capacity(proc_totals.len());
        let mut out = Vec::new();

        for (pid, (name, user, rx, tx)) in proc_totals {
            if let Some((prx, ptx)) = self.prev_proc_net.get(&pid) {
                if dt_secs > 0.05 {
                    let down_bps = (rx.saturating_sub(*prx) as f64 / dt_secs) as u64;
                    let up_bps = (tx.saturating_sub(*ptx) as f64 / dt_secs) as u64;
                    let total_bps = down_bps.saturating_add(up_bps);
                    if total_bps > 0 {
                        out.push(ProcessNetIo {
                            pid,
                            name,
                            user,
                            upload_bps: up_bps,
                            download_bps: down_bps,
                            total_bps,
                        });
                    }
                }
            }
            next_prev.insert(pid, (rx, tx));
        }

        self.prev_proc_net = next_prev;
        out.sort_by(|a, b| b.total_bps.cmp(&a.total_bps));
        out.truncate(12);
        out
    }

    fn detect_oom_events(&mut self) -> Vec<OomEvent> {
        let mut events = Vec::new();
        let Some(cur_count) = read_vmstat_oom_kills() else {
            return events;
        };

        if let Some(prev) = self.last_oom_kill_count {
            if cur_count > prev {
                let delta = cur_count - prev;
                let parsed = fetch_recent_oom_killer_line();
                if let Some((proc_name, pid, raw_line)) = parsed {
                    events.push(OomEvent {
                        process_name: Some(proc_name),
                        pid,
                        detail: raw_line,
                    });
                } else {
                    events.push(OomEvent {
                        process_name: None,
                        pid: None,
                        detail: format!(
                            "Kernel OOM killer triggered ({delta} kill(s); total oom_kill={cur_count})"
                        ),
                    });
                }
            }
        }
        self.last_oom_kill_count = Some(cur_count);
        events
    }
}

impl PlatformCollector for LinuxCollector {
    fn boot_id(&self) -> String {
        self.boot_id.clone()
    }

    fn collect(&mut self) -> CollectionResult {
        let now = Instant::now();
        let dt_secs = self
            .prev_sample_at
            .map(|p| now.duration_since(p).as_secs_f64())
            .unwrap_or(0.0);
        self.prev_sample_at = Some(now);

        let (total_pct, user_pct, system_pct, iowait_pct, idle_pct, cores) = self.collect_cpu();
        let load_avg = read_linux_loadavg();
        let (top_cpu, top_mem, top_disk, inode_to_proc) = self.collect_processes(dt_secs);
        let memory = self.collect_memory(top_mem);
        let disks = self.collect_disks(dt_secs, top_disk);
        let network = self.collect_network(dt_secs, &inode_to_proc);
        let oom_events = self.detect_oom_events();

        let uptime_secs = fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|s| s.split_whitespace().next()?.parse::<f64>().ok())
            .map(|v| v.max(0.0) as u64)
            .unwrap_or(0);

        let snapshot = HostSnapshot {
            timestamp: Utc::now().timestamp_millis(),
            host: HostInfo {
                hostname: self.hostname.clone(),
                os: OsKind::Linux,
                os_version: self.os_version.clone(),
                arch: self.arch.clone(),
                uptime_secs,
                boot_id: self.boot_id.clone(),
                cpu_model: self.cpu_model.clone(),
            },
            cpu: CpuMetrics {
                total_pct,
                user_pct,
                system_pct,
                iowait_pct,
                idle_pct,
                load_avg,
                cores,
                top_processes: top_cpu,
            },
            memory,
            disks,
            network,
            active_alerts: Vec::new(),
        };

        CollectionResult {
            snapshot,
            oom_events,
        }
    }
}

fn parse_cpu_line(line: &str) -> Option<CpuTicks> {
    let mut parts = line.split_whitespace();
    let _label = parts.next()?;
    let nums: Vec<u64> = parts.filter_map(|s| s.parse().ok()).collect();
    if nums.len() < 4 {
        return None;
    }
    Some(CpuTicks {
        user: nums[0],
        nice: nums[1],
        system: nums[2],
        idle: nums[3],
        iowait: *nums.get(4).unwrap_or(&0),
        irq: *nums.get(5).unwrap_or(&0),
        softirq: *nums.get(6).unwrap_or(&0),
        steal: *nums.get(7).unwrap_or(&0),
    })
}

fn read_linux_loadavg() -> [f64; 3] {
    let content = fs::read_to_string("/proc/loadavg").unwrap_or_default();
    let mut parts = content.split_whitespace();
    [
        parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0),
        parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0),
        parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0),
    ]
}

fn parse_proc_stat(stat: &str) -> Option<(String, u64, u64, u64)> {
    let l = stat.find('(')?;
    let r = stat.rfind(')')?;
    if r <= l {
        return None;
    }
    let name = stat[l + 1..r].to_string();
    let rest: Vec<&str> = stat[r + 2..].split_whitespace().collect();
    // Fields after ')': index 0 is state (field 3), utime is field 14 (idx 11),
    // stime is field 15 (idx 12), rss is field 24 (idx 21)
    if rest.len() < 22 {
        return None;
    }
    let utime = rest[11].parse::<u64>().ok()?;
    let stime = rest[12].parse::<u64>().ok()?;
    let rss = rest[21].parse::<i64>().ok()?.max(0) as u64;
    Some((name, utime, stime, rss))
}

fn read_proc_uid(proc_dir: &Path) -> Option<u32> {
    let status = fs::read_to_string(proc_dir.join("status")).ok()?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("Uid:") {
            return rest.split_whitespace().next()?.parse().ok();
        }
    }
    None
}

fn read_proc_io(proc_dir: &Path) -> Option<(u64, u64)> {
    let io = fs::read_to_string(proc_dir.join("io")).ok()?;
    let mut read_bytes = 0_u64;
    let mut write_bytes = 0_u64;
    for line in io.lines() {
        if let Some(v) = line.strip_prefix("read_bytes:") {
            read_bytes = v.trim().parse().unwrap_or(0);
        } else if let Some(v) = line.strip_prefix("write_bytes:") {
            write_bytes = v.trim().parse().unwrap_or(0);
        }
    }
    Some((read_bytes, write_bytes))
}

fn parse_meminfo() -> HashMap<String, u64> {
    let mut map = HashMap::new();
    let content = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    for line in content.lines() {
        if let Some((k, rest)) = line.split_once(':') {
            let mut parts = rest.split_whitespace();
            if let Some(val_s) = parts.next() {
                if let Ok(val) = val_s.parse::<u64>() {
                    let bytes = match parts.next() {
                        Some("kB") => val.saturating_mul(1024),
                        _ => val,
                    };
                    map.insert(k.to_string(), bytes);
                }
            }
        }
    }
    map
}

fn read_linux_memory_psi() -> (Option<f64>, Option<f64>) {
    let Ok(content) = fs::read_to_string("/proc/pressure/memory") else {
        return (None, None);
    };
    let mut some10 = None;
    let mut full10 = None;
    for line in content.lines() {
        for tok in line.split_whitespace() {
            if let Some(v) = tok.strip_prefix("avg10=") {
                if let Ok(f) = v.parse::<f64>() {
                    if line.starts_with("some") {
                        some10 = Some(f);
                    } else if line.starts_with("full") {
                        full10 = Some(f);
                    }
                }
            }
        }
    }
    (some10, full10)
}

fn read_linux_diskstats() -> HashMap<String, (u64, u64, bool)> {
    let mut map = HashMap::new();
    let content = fs::read_to_string("/proc/diskstats").unwrap_or_default();
    for line in content.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 10 {
            continue;
        }
        let name = parts[2];
        if name.starts_with("loop") || name.starts_with("ram") || name.starts_with("zram") {
            continue;
        }
        let sectors_read: u64 = parts[5].parse().unwrap_or(0);
        let sectors_written: u64 = parts[9].parse().unwrap_or(0);
        let is_whole = Path::new(&format!("/sys/block/{name}")).exists();
        map.insert(
            name.to_string(),
            (
                sectors_read.saturating_mul(512),
                sectors_written.saturating_mul(512),
                is_whole,
            ),
        );
    }
    map
}

fn statvfs_bytes(mount: &str) -> Option<(u64, u64, u64)> {
    let cmount = CString::new(mount).ok()?;
    let mut st: libc::statvfs = unsafe { zeroed() };
    let ok = unsafe { libc::statvfs(cmount.as_ptr(), &mut st) == 0 };
    if !ok {
        return None;
    }
    let frsize = if st.f_frsize > 0 {
        st.f_frsize as u64
    } else {
        st.f_bsize as u64
    };
    let total = (st.f_blocks as u64).saturating_mul(frsize);
    let free = (st.f_bavail as u64).saturating_mul(frsize);
    let used = total.saturating_sub((st.f_bfree as u64).saturating_mul(frsize));
    Some((total, used, free))
}

fn linux_base_block_device(dev: &str) -> String {
    // nvme0n1p2 -> nvme0n1, sda1 -> sda, mmcblk0p1 -> mmcblk0
    if dev.starts_with("nvme") || dev.starts_with("mmcblk") {
        if let Some(pos) = dev.rfind('p') {
            if dev[pos + 1..].chars().all(|c| c.is_ascii_digit()) {
                return dev[..pos].to_string();
            }
        }
        dev.to_string()
    } else {
        dev.trim_end_matches(|c: char| c.is_ascii_digit()).to_string()
    }
}

fn is_linux_removable_disk(base_disk: &str) -> bool {
    read_trimmed(&format!("/sys/block/{base_disk}/removable")).as_deref() == Some("1")
}

fn read_linux_net_dev() -> HashMap<String, (u64, u64)> {
    let mut map = HashMap::new();
    let content = fs::read_to_string("/proc/net/dev").unwrap_or_default();
    for line in content.lines().skip(2) {
        if let Some((iface, rest)) = line.split_once(':') {
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if parts.len() >= 9 {
                let rx: u64 = parts[0].parse().unwrap_or(0);
                let tx: u64 = parts[8].parse().unwrap_or(0);
                map.insert(iface.trim().to_string(), (rx, tx));
            }
        }
    }
    map
}

fn read_linux_ifaddrs() -> HashMap<String, (bool, Vec<String>, Vec<String>)> {
    let mut map: HashMap<String, (bool, Vec<String>, Vec<String>)> = HashMap::new();
    unsafe {
        let mut ifap: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut ifap) == 0 && !ifap.is_null() {
            let mut cur = ifap;
            while !cur.is_null() {
                let ifa = &*cur;
                if !ifa.ifa_name.is_null() {
                    let name = CStr::from_ptr(ifa.ifa_name).to_string_lossy().into_owned();
                    let flags = ifa.ifa_flags as i32;
                    let is_up = (flags & libc::IFF_UP) != 0 && (flags & libc::IFF_RUNNING) != 0;
                    let entry = map
                        .entry(name)
                        .or_insert_with(|| (is_up, Vec::new(), Vec::new()));
                    entry.0 = entry.0 || is_up;

                    if !ifa.ifa_addr.is_null() {
                        let family = (*ifa.ifa_addr).sa_family as i32;
                        if family == libc::AF_INET {
                            let sin = &*(ifa.ifa_addr as *const libc::sockaddr_in);
                            let ip = Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr)).to_string();
                            if !entry.1.contains(&ip) {
                                entry.1.push(ip);
                            }
                        } else if family == libc::AF_INET6 {
                            let sin6 = &*(ifa.ifa_addr as *const libc::sockaddr_in6);
                            let ip = Ipv6Addr::from(sin6.sin6_addr.s6_addr);
                            if !ip.is_unicast_link_local() {
                                let s = ip.to_string();
                                if !entry.2.contains(&s) {
                                    entry.2.push(s);
                                }
                            }
                        }
                    }
                }
                cur = ifa.ifa_next;
            }
            libc::freeifaddrs(ifap);
        }
    }
    map
}

/// Minimal Linux `SOCK_DIAG` netlink query returning `(socket_inode -> (bytes_received, bytes_sent))`
/// from kernel `tcp_info` (available on Linux 4.2+ with zero external crates or eBPF headers).
fn query_inet_diag_tcp_bytes() -> HashMap<u64, (u64, u64)> {
    let mut out = HashMap::new();
    const NETLINK_SOCK_DIAG: i32 = 4;
    const SOCK_DIAG_BY_FAMILY: u16 = 20;
    const INET_DIAG_INFO: u16 = 2;
    const NLM_F_REQUEST: u16 = 1;
    const NLM_F_DUMP: u16 = 0x300;
    const NLMSG_DONE: u16 = 3;
    const NLMSG_ERROR: u16 = 2;

    #[repr(C)]
    struct NlMsgHdr {
        nlmsg_len: u32,
        nlmsg_type: u16,
        nlmsg_flags: u16,
        nlmsg_seq: u32,
        nlmsg_pid: u32,
    }

    #[repr(C)]
    struct InetDiagSockId {
        idiag_sport: u16,
        idiag_dport: u16,
        idiag_src: [u32; 4],
        idiag_dst: [u32; 4],
        idiag_if: u32,
        idiag_cookie: [u32; 2],
    }

    #[repr(C)]
    struct InetDiagReqV2 {
        sdiag_family: u8,
        sdiag_protocol: u8,
        idiag_ext: u8,
        pad: u8,
        idiag_states: u32,
        id: InetDiagSockId,
    }

    #[repr(C)]
    struct InetDiagMsg {
        idiag_family: u8,
        idiag_state: u8,
        idiag_timer: u8,
        idiag_retrans: u8,
        id: InetDiagSockId,
        idiag_expires: u32,
        idiag_rqueue: u32,
        idiag_wqueue: u32,
        idiag_uid: u32,
        idiag_inode: u32,
    }

    #[repr(C)]
    struct RtAttr {
        rta_len: u16,
        rta_type: u16,
    }

    #[repr(C)]
    struct DiagRequest {
        nlh: NlMsgHdr,
        req: InetDiagReqV2,
    }

    let fd = unsafe {
        libc::socket(
            libc::AF_NETLINK,
            libc::SOCK_DGRAM | libc::SOCK_CLOEXEC,
            NETLINK_SOCK_DIAG,
        )
    };
    if fd < 0 {
        return out;
    }

    let tv = libc::timeval {
        tv_sec: 0,
        tv_usec: 250_000,
    };
    unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVTIMEO,
            &tv as *const _ as *const libc::c_void,
            size_of::<libc::timeval>() as libc::socklen_t,
        );
    }

    let mut buf = vec![0_u8; 65536];

    for family in [libc::AF_INET as u8, libc::AF_INET6 as u8] {
        let mut msg: DiagRequest = unsafe { zeroed() };
        msg.nlh.nlmsg_len = size_of::<DiagRequest>() as u32;
        msg.nlh.nlmsg_type = SOCK_DIAG_BY_FAMILY;
        msg.nlh.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
        msg.nlh.nlmsg_seq = family as u32;
        msg.req.sdiag_family = family;
        msg.req.sdiag_protocol = libc::IPPROTO_TCP as u8;
        msg.req.idiag_ext = 1 << (INET_DIAG_INFO - 1);
        msg.req.idiag_states = 0xFFFF_FFFF;

        let sent = unsafe {
            libc::send(
                fd,
                &msg as *const _ as *const libc::c_void,
                size_of::<DiagRequest>(),
                0,
            )
        };
        if sent < 0 {
            continue;
        }

        loop {
            let n = unsafe {
                libc::recv(
                    fd,
                    buf.as_mut_ptr() as *mut libc::c_void,
                    buf.len(),
                    0,
                )
            };
            if n <= 0 {
                break;
            }
            let n = n as usize;
            let mut offset = 0_usize;
            let mut done = false;

            while offset + size_of::<NlMsgHdr>() <= n {
                let nlh = unsafe { &*(buf.as_ptr().add(offset) as *const NlMsgHdr) };
                let msg_len = nlh.nlmsg_len as usize;
                if msg_len < size_of::<NlMsgHdr>() || offset + msg_len > n {
                    done = true;
                    break;
                }
                if nlh.nlmsg_type == NLMSG_DONE || nlh.nlmsg_type == NLMSG_ERROR {
                    done = true;
                    break;
                }

                let payload_start = offset + size_of::<NlMsgHdr>();
                if payload_start + size_of::<InetDiagMsg>() <= offset + msg_len {
                    let diag =
                        unsafe { &*(buf.as_ptr().add(payload_start) as *const InetDiagMsg) };
                    let inode = diag.idiag_inode as u64;
                    let mut attr_off = payload_start + ((size_of::<InetDiagMsg>() + 3) & !3);

                    while attr_off + size_of::<RtAttr>() <= offset + msg_len {
                        let rta = unsafe { &*(buf.as_ptr().add(attr_off) as *const RtAttr) };
                        let rta_len = rta.rta_len as usize;
                        if rta_len < size_of::<RtAttr>() || attr_off + rta_len > offset + msg_len {
                            break;
                        }
                        if rta.rta_type == INET_DIAG_INFO {
                            let info_off = attr_off + size_of::<RtAttr>();
                            let info_len = rta_len - size_of::<RtAttr>();
                            // In Linux `struct tcp_info`:
                            // tcpi_bytes_acked (u64) at byte offset 120 (Linux 4.2+)
                            // tcpi_bytes_received (u64) at byte offset 128 (Linux 4.2+)
                            // tcpi_bytes_sent (u64) at byte offset 184 (Linux 5.4+)
                            if info_len >= 136 {
                                let info_ptr = unsafe { buf.as_ptr().add(info_off) };
                                let bytes_acked = unsafe {
                                    u64::from_ne_bytes(*(info_ptr.add(120) as *const [u8; 8]))
                                };
                                let bytes_received = unsafe {
                                    u64::from_ne_bytes(*(info_ptr.add(128) as *const [u8; 8]))
                                };
                                let bytes_sent = if info_len >= 192 {
                                    let s = unsafe {
                                        u64::from_ne_bytes(*(info_ptr.add(184) as *const [u8; 8]))
                                    };
                                    if s > 0 { s } else { bytes_acked }
                                } else {
                                    bytes_acked
                                };
                                if inode > 0 && (bytes_received > 0 || bytes_sent > 0) {
                                    out.insert(inode, (bytes_received, bytes_sent));
                                }
                            }
                        }
                        attr_off += (rta_len + 3) & !3;
                    }
                }
                offset += (msg_len + 3) & !3;
            }
            if done {
                break;
            }
        }
    }

    unsafe {
        libc::close(fd);
    }
    out
}

fn read_vmstat_oom_kills() -> Option<u64> {
    let content = fs::read_to_string("/proc/vmstat").ok()?;
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("oom_kill ") {
            return rest.trim().parse().ok();
        }
    }
    None
}

fn fetch_recent_oom_killer_line() -> Option<(String, Option<u32>, String)> {
    // Try journalctl first (works on systemd Debian/Ubuntu/Arch), fall back to dmesg
    let output = Command::new("journalctl")
        .args(["-k", "-n", "40", "--no-pager", "-o", "cat"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .or_else(|| Command::new("dmesg").args(["--kernel"]).output().ok())?;

    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines().rev() {
        if line.contains("Killed process") || line.contains("Out of memory: Killed") {
            // Typical kernel message:
            // "Out of memory: Killed process 4821 (node) total-vm:14821924kB, anon-rss:12918200kB..."
            let mut pid = None;
            let mut name = "unknown".to_string();
            if let Some(pos) = line.find("Killed process ") {
                let after = &line[pos + "Killed process ".len()..];
                let mut parts = after.split_whitespace();
                if let Some(pid_s) = parts.next() {
                    pid = pid_s.parse::<u32>().ok();
                }
                if let Some(paren_start) = after.find('(') {
                    if let Some(paren_end) = after[paren_start + 1..].find(')') {
                        name = after[paren_start + 1..paren_start + 1 + paren_end].to_string();
                    }
                }
            }
            return Some((name, pid, line.trim().to_string()));
        }
    }
    None
}

fn read_linux_os_pretty_name() -> String {
    if let Ok(content) = fs::read_to_string("/etc/os-release") {
        for line in content.lines() {
            if let Some(rest) = line.strip_prefix("PRETTY_NAME=") {
                return rest.trim_matches('"').to_string();
            }
        }
    }
    "Linux".to_string()
}

fn read_linux_cpu_model() -> Option<String> {
    let content = fs::read_to_string("/proc/cpuinfo").ok()?;
    for line in content.lines() {
        if let Some((k, v)) = line.split_once(':') {
            let key = k.trim();
            if key == "model name" || key == "Model" {
                let val = v.trim();
                if !val.is_empty() {
                    return Some(val.to_string());
                }
            }
        }
    }
    None
}

fn read_trimmed(path: &str) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn unescape_mount_path(s: &str) -> String {
    s.replace("\\040", " ").replace("\\011", "\t")
}

fn clamp_pct(v: f64) -> f64 {
    if v.is_nan() || v.is_infinite() {
        0.0
    } else {
        v.clamp(0.0, 100.0)
    }
}
