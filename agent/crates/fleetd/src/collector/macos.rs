use crate::collector::{CollectionResult, PlatformCollector, username_for_uid};
use crate::model::{
    CoreKind, CoreUsage, CpuMetrics, DiskMetrics, DiskVolume, HostInfo, HostSnapshot,
    MemoryMetrics, NetworkInterface, NetworkMetrics, OsKind, PressureLevel, ProcessCpu,
    ProcessDiskIo, ProcessMemory, ProcessNetIo,
};
use chrono::Utc;
use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString, c_void};
use std::io::{BufRead, BufReader};
use std::mem::{size_of, zeroed};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Instant;

// Mach / Libproc / IOKit FFI
const PROCESSOR_CPU_LOAD_INFO: i32 = 2;
const CPU_STATE_USER: usize = 0;
const CPU_STATE_SYSTEM: usize = 1;
const CPU_STATE_IDLE: usize = 2;
const CPU_STATE_NICE: usize = 3;
const CPU_STATE_MAX: usize = 4;

const HOST_VM_INFO64: i32 = 4;
const PROC_PIDTBSDINFO: i32 = 3;
const PROC_PIDTASKINFO: i32 = 4;
const RUSAGE_INFO_V4: i32 = 4;
const MNT_NOWAIT: i32 = 2;
const MNT_LOCAL: u32 = 0x00001000;

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct MachTimebaseInfo {
    numer: u32,
    denom: u32,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct VmStatistics64 {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct XswUsage {
    xsu_total: u64,
    xsu_avail: u64,
    xsu_used: u64,
    xsu_pagesize: u32,
    xsu_encrypted: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct ProcBsdInfo {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: u32,
    pbi_gid: u32,
    pbi_ruid: u32,
    pbi_rgid: u32,
    pbi_svuid: u32,
    pbi_svgid: u32,
    rfu_1: u32,
    pbi_comm: [libc::c_char; 16],
    pbi_name: [libc::c_char; 32],
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct ProcTaskInfo {
    pti_virtual_size: u64,
    pti_resident_size: u64,
    pti_total_user: u64,
    pti_total_system: u64,
    pti_threads_user: u64,
    pti_threads_system: u64,
    pti_policy: i32,
    pti_faults: i32,
    pti_pageins: i32,
    pti_cow_faults: i32,
    pti_messages_sent: i32,
    pti_messages_received: i32,
    pti_syscalls_mach: i32,
    pti_syscalls_unix: i32,
    pti_csw: i32,
    pti_threadnum: i32,
    pti_numrunning: i32,
    pti_priority: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct RusageInfoV4 {
    ri_uuid: [u8; 16],
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_interrupt_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
    ri_cpu_time_qos_default: u64,
    ri_cpu_time_qos_maintenance: u64,
    ri_cpu_time_qos_background: u64,
    ri_cpu_time_qos_utility: u64,
    ri_cpu_time_qos_legacy: u64,
    ri_cpu_time_qos_user_initiated: u64,
    ri_cpu_time_qos_user_interactive: u64,
    ri_billed_system_time: u64,
    ri_serviced_system_time: u64,
    ri_logical_writes: u64,
    ri_lifetime_max_phys_footprint: u64,
    ri_instructions: u64,
    ri_cycles: u64,
    ri_billed_energy: u64,
    ri_serviced_energy: u64,
    ri_interval_max_phys_footprint: u64,
    ri_runnable_time: u64,
}

#[repr(C, packed(4))]
#[derive(Clone, Copy)]
struct IfData64 {
    ifi_type: u8,
    ifi_typelen: u8,
    ifi_physical: u8,
    ifi_addrlen: u8,
    ifi_hdrlen: u8,
    ifi_recvquota: u8,
    ifi_xmitquota: u8,
    ifi_unused1: u8,
    ifi_mtu: u32,
    ifi_metric: u32,
    ifi_baudrate: u64,
    ifi_ipackets: u64,
    ifi_ierrors: u64,
    ifi_opackets: u64,
    ifi_oerrors: u64,
    ifi_collisions: u64,
    ifi_ibytes: u64,
    ifi_obytes: u64,
    ifi_imcasts: u64,
    ifi_omcasts: u64,
    ifi_iqdrops: u64,
    ifi_noproto: u64,
    ifi_recvtiming: u32,
    ifi_xmittiming: u32,
    ifi_lastchange: libc::timeval32,
}

#[repr(C, packed(4))]
#[derive(Clone, Copy)]
struct IfMibData {
    ifmd_name: [libc::c_char; 16],
    ifmd_pcount: u32,
    ifmd_flags: u32,
    ifmd_snd_len: u32,
    ifmd_snd_maxlen: u32,
    ifmd_snd_drops: u32,
    ifmd_filler: [u32; 4],
    ifmd_data: IfData64,
}

unsafe extern "C" {
    fn mach_host_self() -> u32;
    fn mach_task_self() -> u32;
    fn mach_timebase_info(info: *mut MachTimebaseInfo) -> i32;
    fn host_processor_info(
        host: u32,
        flavor: i32,
        out_processor_count: *mut u32,
        out_processor_info: *mut *mut i32,
        out_processor_info_cnt: *mut u32,
    ) -> i32;
    fn host_statistics64(
        host: u32,
        flavor: i32,
        host_info_out: *mut i32,
        host_info_out_cnt: *mut u32,
    ) -> i32;
    fn vm_deallocate(target_task: u32, address: usize, size: usize) -> i32;
    fn proc_listallpids(buffer: *mut c_void, buffersize: i32) -> i32;
    fn proc_pidinfo(
        pid: i32,
        flavor: i32,
        arg: u64,
        buffer: *mut c_void,
        buffersize: i32,
    ) -> i32;
    fn proc_pid_rusage(pid: i32, flavor: i32, buffer: *mut c_void) -> i32;
}

// IOKit & CoreFoundation minimal FFI for block storage byte counters
#[link(name = "IOKit", kind = "framework")]
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kIOMainPortDefault: u32;
    fn IOServiceMatching(name: *const libc::c_char) -> *mut c_void;
    fn IOServiceGetMatchingServices(
        main_port: u32,
        matching: *mut c_void,
        existing: *mut u32,
    ) -> i32;
    fn IOIteratorNext(iterator: u32) -> u32;
    fn IOObjectRelease(object: u32) -> i32;
    fn IORegistryEntryCreateCFProperties(
        entry: u32,
        properties: *mut *mut c_void,
        allocator: *const c_void,
        options: u32,
    ) -> i32;
    fn IORegistryEntryGetChildIterator(
        entry: u32,
        plane: *const libc::c_char,
        iterator: *mut u32,
    ) -> i32;

    fn CFRelease(cf: *const c_void);
    fn CFStringCreateWithCString(
        alloc: *const c_void,
        c_str: *const libc::c_char,
        encoding: u32,
    ) -> *const c_void;
    fn CFDictionaryGetValue(the_dict: *const c_void, key: *const c_void) -> *const c_void;
    fn CFNumberGetValue(number: *const c_void, the_type: isize, value_ptr: *mut c_void) -> bool;
    fn CFStringGetCString(
        the_string: *const c_void,
        buffer: *mut libc::c_char,
        buffer_size: isize,
        encoding: u32,
    ) -> bool;
    fn CFGetTypeID(cf: *const c_void) -> usize;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
    fn CFStringGetTypeID() -> usize;
}

const K_CF_STRING_ENCODING_UTF8: u32 = 0x08000100;
const K_CF_NUMBER_SINT64_TYPE: isize = 4;

#[derive(Default, Clone)]
struct NettopSample {
    name: String,
    bytes_in: u64,
    bytes_out: u64,
    updated_at: Option<Instant>,
}

struct PrevProc {
    cpu_ns: u64,
    disk_read: u64,
    disk_write: u64,
}

pub struct MacosCollector {
    hostname: String,
    os_version: String,
    arch: String,
    cpu_model: String,
    boot_id: String,
    page_size: u64,
    total_memory: u64,
    perf_cores: Option<usize>,
    eff_cores: Option<usize>,
    timebase: MachTimebaseInfo,

    prev_sample_at: Option<Instant>,
    prev_core_ticks: Vec<[u32; CPU_STATE_MAX]>,
    prev_procs: HashMap<u32, PrevProc>,
    prev_disk_io: HashMap<String, (u64, u64)>,
    prev_if_bytes: HashMap<String, (u64, u64)>,
    nettop_rates: Arc<Mutex<HashMap<u32, NettopSample>>>,
}

impl MacosCollector {
    pub fn new() -> Self {
        let hostname = get_hostname();
        let os_version = get_macos_version();
        let arch = std::env::consts::ARCH.to_string();
        let cpu_model = sysctl_string("machdep.cpu.brand_string")
            .unwrap_or_else(|| format!("Apple Mac ({arch})"));
        let boot_time = sysctl_boottime().unwrap_or(0);
        let boot_id = format!("macos-boot-{boot_time}");
        let page_size = sysctl_u64("hw.pagesize").unwrap_or(16384);
        let total_memory = sysctl_u64("hw.memsize").unwrap_or(0);
        let perf_cores = sysctl_u64("hw.perflevel0.logicalcpu").map(|v| v as usize);
        let eff_cores = sysctl_u64("hw.perflevel1.logicalcpu").map(|v| v as usize);

        let mut timebase = MachTimebaseInfo { numer: 1, denom: 1 };
        unsafe {
            mach_timebase_info(&mut timebase);
        }
        if timebase.denom == 0 {
            timebase.denom = 1;
        }

        let nettop_rates = Arc::new(Mutex::new(HashMap::new()));
        spawn_nettop_reader(nettop_rates.clone());

        Self {
            hostname,
            os_version,
            arch,
            cpu_model,
            boot_id,
            page_size,
            total_memory,
            perf_cores,
            eff_cores,
            timebase,
            prev_sample_at: None,
            prev_core_ticks: Vec::new(),
            prev_procs: HashMap::new(),
            prev_disk_io: HashMap::new(),
            prev_if_bytes: HashMap::new(),
            nettop_rates,
        }
    }

    fn collect_cpu_cores(&mut self) -> (f64, f64, f64, f64, Vec<CoreUsage>) {
        let current = read_cpu_ticks();
        if current.is_empty() {
            return (0.0, 0.0, 0.0, 100.0, Vec::new());
        }

        let mut cores = Vec::with_capacity(current.len());
        let mut sum_user = 0_u64;
        let mut sum_sys = 0_u64;
        let mut sum_idle = 0_u64;
        let mut sum_total = 0_u64;

        let p_count = self.perf_cores;
        let e_count = self.eff_cores;

        for (idx, ticks) in current.iter().enumerate() {
            let kind = match (p_count, e_count) {
                (Some(p), Some(e)) if p > 0 && e > 0 => {
                    // On Apple Silicon, E-cores are typically indexed first or last depending on chip;
                    // label cleanly when both perf levels exist.
                    if idx < p {
                        CoreKind::Performance
                    } else {
                        CoreKind::Efficiency
                    }
                }
                _ => CoreKind::Standard,
            };

            let usage = if let Some(prev) = self.prev_core_ticks.get(idx) {
                let du = ticks[CPU_STATE_USER].wrapping_sub(prev[CPU_STATE_USER]) as u64
                    + ticks[CPU_STATE_NICE].wrapping_sub(prev[CPU_STATE_NICE]) as u64;
                let ds = ticks[CPU_STATE_SYSTEM].wrapping_sub(prev[CPU_STATE_SYSTEM]) as u64;
                let di = ticks[CPU_STATE_IDLE].wrapping_sub(prev[CPU_STATE_IDLE]) as u64;
                let dt = du + ds + di;
                sum_user += du;
                sum_sys += ds;
                sum_idle += di;
                sum_total += dt;
                if dt > 0 {
                    ((du + ds) as f64 / dt as f64) * 100.0
                } else {
                    0.0
                }
            } else {
                0.0
            };

            cores.push(CoreUsage {
                index: idx,
                usage_pct: clamp_pct(usage),
                kind,
            });
        }

        self.prev_core_ticks = current;

        if sum_total == 0 {
            return (0.0, 0.0, 0.0, 100.0, cores);
        }

        let user_pct = clamp_pct((sum_user as f64 / sum_total as f64) * 100.0);
        let sys_pct = clamp_pct((sum_sys as f64 / sum_total as f64) * 100.0);
        let idle_pct = clamp_pct((sum_idle as f64 / sum_total as f64) * 100.0);
        let total_pct = clamp_pct(user_pct + sys_pct);

        (total_pct, user_pct, sys_pct, idle_pct, cores)
    }

    fn collect_processes(
        &mut self,
        dt_secs: f64,
    ) -> (Vec<ProcessCpu>, Vec<ProcessMemory>, Vec<ProcessDiskIo>) {
        let pids = list_all_pids();
        let mut next_prev: HashMap<u32, PrevProc> = HashMap::with_capacity(pids.len());
        let mut uid_cache: HashMap<u32, String> = HashMap::new();

        let mut cpu_list = Vec::new();
        let mut mem_list = Vec::new();
        let mut disk_list = Vec::new();

        for pid in pids {
            if pid <= 0 {
                continue;
            }
            let mut bsd: ProcBsdInfo = unsafe { zeroed() };
            let got_bsd = unsafe {
                proc_pidinfo(
                    pid,
                    PROC_PIDTBSDINFO,
                    0,
                    &mut bsd as *mut _ as *mut c_void,
                    size_of::<ProcBsdInfo>() as i32,
                )
            };
            if got_bsd <= 0 {
                continue;
            }
            let name = extract_proc_name(&bsd);
            if name.is_empty() || name == "nettop" {
                continue;
            }
            let user = uid_cache
                .entry(bsd.pbi_uid)
                .or_insert_with(|| username_for_uid(bsd.pbi_uid))
                .clone();

            let mut task: ProcTaskInfo = unsafe { zeroed() };
            let got_task = unsafe {
                proc_pidinfo(
                    pid,
                    PROC_PIDTASKINFO,
                    0,
                    &mut task as *mut _ as *mut c_void,
                    size_of::<ProcTaskInfo>() as i32,
                )
            };

            let mut rusage: RusageInfoV4 = unsafe { zeroed() };
            let got_rusage = unsafe {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, &mut rusage as *mut _ as *mut c_void) == 0
            };

            let cpu_ticks = if got_task > 0 {
                task.pti_total_user.saturating_add(task.pti_total_system)
            } else if got_rusage {
                rusage.ri_user_time.saturating_add(rusage.ri_system_time)
            } else {
                0
            };
            let cpu_ns = (cpu_ticks as u128 * self.timebase.numer as u128
                / self.timebase.denom as u128) as u64;

            let mem_bytes = if got_rusage && rusage.ri_phys_footprint > 0 {
                rusage.ri_phys_footprint
            } else if got_task > 0 {
                task.pti_resident_size
            } else {
                0
            };

            let disk_read = if got_rusage {
                rusage.ri_diskio_bytesread
            } else {
                0
            };
            let disk_write = if got_rusage {
                rusage.ri_diskio_byteswritten
            } else {
                0
            };

            let pid_u32 = pid as u32;
            if let Some(prev) = self.prev_procs.get(&pid_u32) {
                if dt_secs > 0.05 {
                    let d_cpu_ns = cpu_ns.saturating_sub(prev.cpu_ns);
                    let cpu_pct = (d_cpu_ns as f64 / (dt_secs * 1_000_000_000.0)) * 100.0;
                    if cpu_pct >= 0.05 {
                        cpu_list.push(ProcessCpu {
                            pid: pid_u32,
                            name: name.clone(),
                            user: user.clone(),
                            cpu_pct,
                            memory_bytes: mem_bytes,
                        });
                    }

                    let d_read = disk_read.saturating_sub(prev.disk_read);
                    let d_write = disk_write.saturating_sub(prev.disk_write);
                    let read_bps = (d_read as f64 / dt_secs) as u64;
                    let write_bps = (d_write as f64 / dt_secs) as u64;
                    let total_bps = read_bps.saturating_add(write_bps);
                    if total_bps > 0 {
                        disk_list.push(ProcessDiskIo {
                            pid: pid_u32,
                            name: name.clone(),
                            user: user.clone(),
                            read_bps,
                            write_bps,
                            total_bps,
                        });
                    }
                }
            }

            if mem_bytes > 0 {
                mem_list.push(ProcessMemory {
                    pid: pid_u32,
                    name,
                    user,
                    memory_bytes: mem_bytes,
                    oom_score: None,
                });
            }

            next_prev.insert(
                pid_u32,
                PrevProc {
                    cpu_ns,
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

        (cpu_list, mem_list, disk_list)
    }

    fn collect_memory(&self, top_processes: Vec<ProcessMemory>) -> MemoryMetrics {
        let mut vm: VmStatistics64 = unsafe { zeroed() };
        let mut count = (size_of::<VmStatistics64>() / size_of::<u32>()) as u32;
        let kr = unsafe {
            host_statistics64(
                mach_host_self(),
                HOST_VM_INFO64,
                &mut vm as *mut _ as *mut i32,
                &mut count,
            )
        };

        let page = self.page_size;
        let total = self.total_memory;

        let (app_bytes, wired_bytes, compressed_bytes, cached_bytes, used_bytes, free_bytes) =
            if kr == 0 && total > 0 {
                let app_pages = vm.internal_page_count.saturating_sub(vm.purgeable_count) as u64;
                let app = app_pages.saturating_mul(page);
                let wired = (vm.wire_count as u64).saturating_mul(page);
                let compressed = (vm.compressor_page_count as u64).saturating_mul(page);
                let cached = (vm.external_page_count as u64 + vm.purgeable_count as u64)
                    .saturating_mul(page);
                let used = app.saturating_add(wired).saturating_add(compressed).min(total);
                let free = total.saturating_sub(used.saturating_add(cached));
                (app, wired, compressed, cached, used, free)
            } else {
                (0, 0, 0, 0, 0, total)
            };

        let swap = sysctl_swapusage().unwrap_or_default();
        let used_pct = if total > 0 {
            clamp_pct((used_bytes as f64 / total as f64) * 100.0)
        } else {
            0.0
        };

        let pressure_code = sysctl_i32("kern.memorystatus_vm_pressure_level").unwrap_or(1);
        let pressure_level = match pressure_code {
            4 => PressureLevel::Critical,
            2 => PressureLevel::Warn,
            _ => PressureLevel::Normal,
        };

        // Smooth pressure percentage matching macOS Activity Monitor intuition
        let raw_pressure = if total > 0 {
            let weighted = wired_bytes as f64 * 1.15
                + compressed_bytes as f64 * 1.25
                + app_bytes as f64 * 0.72
                + swap.xsu_used as f64 * 0.50;
            clamp_pct((weighted / total as f64) * 100.0)
        } else {
            0.0
        };
        let pressure_pct = match pressure_level {
            PressureLevel::Critical => raw_pressure.max(85.0),
            PressureLevel::Warn => raw_pressure.max(60.0),
            PressureLevel::Normal => raw_pressure.min(65.0),
        };

        MemoryMetrics {
            total_bytes: total,
            used_bytes,
            used_pct,
            app_bytes,
            wired_bytes,
            compressed_bytes,
            cached_bytes,
            free_bytes,
            swap_used_bytes: swap.xsu_used,
            swap_total_bytes: swap.xsu_total,
            pressure_level,
            pressure_pct,
            psi_some_avg10: None,
            psi_full_avg10: None,
            top_processes,
        }
    }

    fn collect_disks(&mut self, dt_secs: f64, top_processes: Vec<ProcessDiskIo>) -> DiskMetrics {
        // Read per-block-device IOKit byte totals
        let io_totals = read_iokit_disk_bytes();
        let mut dev_rates: HashMap<String, (u64, u64)> = HashMap::new();
        let mut total_read_bps = 0_u64;
        let mut total_write_bps = 0_u64;

        for (bsd_name, (r_bytes, w_bytes)) in &io_totals {
            if let Some((pr, pw)) = self.prev_disk_io.get(bsd_name) {
                if dt_secs > 0.05 {
                    let r_bps = (r_bytes.saturating_sub(*pr) as f64 / dt_secs) as u64;
                    let w_bps = (w_bytes.saturating_sub(*pw) as f64 / dt_secs) as u64;
                    dev_rates.insert(bsd_name.clone(), (r_bps, w_bps));
                    total_read_bps = total_read_bps.saturating_add(r_bps);
                    total_write_bps = total_write_bps.saturating_add(w_bps);
                }
            }
        }
        self.prev_disk_io = io_totals;

        let mut volumes = Vec::new();
        let mut seen_devices: HashSet<String> = HashSet::new();
        let mut mntbuf: *mut libc::statfs = std::ptr::null_mut();
        let count = unsafe { libc::getmntinfo(&mut mntbuf, MNT_NOWAIT) };

        if count > 0 && !mntbuf.is_null() {
            let slice = unsafe { std::slice::from_raw_parts(mntbuf, count as usize) };
            for fs in slice {
                let mount = cstr_to_string(&fs.f_mntonname);
                let from = cstr_to_string(&fs.f_mntfromname);
                let fstype = cstr_to_string(&fs.f_fstypename);

                if matches!(
                    fstype.as_str(),
                    "devfs" | "autofs" | "mtmfs" | "nullfs" | "vmhgfs" | "lifs"
                ) {
                    continue;
                }
                if !from.starts_with("/dev/") {
                    continue;
                }
                // Filter macOS internal APFS helper mounts so we don't duplicate Macintosh HD
                if mount.starts_with("/System/Volumes/")
                    || mount.starts_with("/private/var/vm")
                    || mount.starts_with("/Library/Developer/CoreSimulator")
                    || matches!(
                        mount.as_str(),
                        "/Volumes/Recovery" | "/Volumes/Preboot" | "/Volumes/VM" | "/Volumes/Update"
                    )
                {
                    continue;
                }
                // Keep root "/" and any mounted user volumes under "/Volumes/"
                let is_primary = mount == "/";
                if !is_primary && !mount.starts_with("/Volumes/") {
                    continue;
                }
                if !seen_devices.insert(mount.clone()) {
                    continue;
                }

                let block_size = fs.f_bsize as u64;
                let total = fs.f_blocks.saturating_mul(block_size);
                let free = fs.f_bavail.saturating_mul(block_size);
                let used = total.saturating_sub(free);
                let used_pct = if total > 0 {
                    clamp_pct((used as f64 / total as f64) * 100.0)
                } else {
                    0.0
                };

                let is_local = (fs.f_flags & MNT_LOCAL) != 0;
                let is_external = !is_primary && (mount.starts_with("/Volumes/") || !is_local);

                let name = if is_primary {
                    "Macintosh HD".to_string()
                } else {
                    mount
                        .trim_start_matches("/Volumes/")
                        .to_string()
                };

                // Map `/dev/disk3s1s1` -> parent whole disk `disk3` or match total for primary
                let parent_disk = extract_bsd_disk_prefix(&from);
                let (read_bps, write_bps) = parent_disk
                    .as_deref()
                    .and_then(|d| dev_rates.get(d).copied())
                    .unwrap_or_else(|| {
                        if is_primary && dev_rates.len() == 1 {
                            (total_read_bps, total_write_bps)
                        } else {
                            (0, 0)
                        }
                    });

                volumes.push(DiskVolume {
                    id: from,
                    name,
                    mount_point: mount,
                    filesystem: fstype,
                    is_external,
                    is_primary,
                    total_bytes: total,
                    used_bytes: used,
                    free_bytes: free,
                    used_pct,
                    read_bps,
                    write_bps,
                });
            }
        }

        // Primary first, then external alphabetically
        volumes.sort_by(|a, b| {
            b.is_primary
                .cmp(&a.is_primary)
                .then_with(|| a.is_external.cmp(&b.is_external))
                .then_with(|| a.name.cmp(&b.name))
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

    fn collect_network(&mut self, dt_secs: f64) -> NetworkMetrics {
        let mut if_map: HashMap<String, (bool, Vec<String>, Vec<String>, u64, u64)> = HashMap::new();

        // First collect 64-bit interface byte counters via IFMIB sysctl (no 4GB wrap)
        let mib_counters = read_macos_ifmib_counters();

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
                        let is_loopback = (flags & libc::IFF_LOOPBACK) != 0;

                        if !is_loopback && should_keep_macos_iface(&name) {
                            let entry = if_map
                                .entry(name.clone())
                                .or_insert_with(|| (is_up, Vec::new(), Vec::new(), 0, 0));
                            entry.0 = entry.0 || is_up;

                            if !ifa.ifa_addr.is_null() {
                                let family = (*ifa.ifa_addr).sa_family as i32;
                                if family == libc::AF_INET {
                                    let sin = &*(ifa.ifa_addr as *const libc::sockaddr_in);
                                    let ip = Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr));
                                    let s = ip.to_string();
                                    if !entry.1.contains(&s) {
                                        entry.1.push(s);
                                    }
                                } else if family == libc::AF_INET6 {
                                    let sin6 = &*(ifa.ifa_addr as *const libc::sockaddr_in6);
                                    let ip = Ipv6Addr::from(sin6.sin6_addr.s6_addr);
                                    // Skip link-local fe80:: unless no global v6
                                    if !ip.is_unicast_link_local() {
                                        let s = ip.to_string();
                                        if !entry.2.contains(&s) {
                                            entry.2.push(s);
                                        }
                                    }
                                } else if family == libc::AF_LINK && !ifa.ifa_data.is_null() {
                                    if let Some((rx, tx)) = mib_counters.get(&name) {
                                        entry.3 = *rx;
                                        entry.4 = *tx;
                                    } else {
                                        let data = &*(ifa.ifa_data as *const libc::if_data);
                                        entry.3 = data.ifi_ibytes as u64;
                                        entry.4 = data.ifi_obytes as u64;
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

        let mut total_up = 0_u64;
        let mut total_down = 0_u64;
        let mut interfaces = Vec::new();
        let mut next_prev_if = HashMap::new();

        for (name, (is_up, ipv4, ipv6, rx, tx)) in if_map {
            let has_addr = !ipv4.is_empty() || !ipv6.is_empty();
            let is_tailscale = name.starts_with("utun")
                && ipv4.iter().any(|ip| is_tailscale_ipv4(ip));

            // Skip inactive interfaces with no assigned IP addresses
            if !has_addr {
                continue;
            }

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

            let is_physical = name.starts_with("en");
            if is_physical && is_up {
                total_down = total_down.saturating_add(down_bps);
                total_up = total_up.saturating_add(up_bps);
            }

            let display_name = if is_tailscale {
                "Tailscale".to_string()
            } else if name == "en0" {
                "Wi-Fi / Primary".to_string()
            } else if name.starts_with("en") {
                format!("Ethernet ({name})")
            } else if name.starts_with("utun") {
                format!("VPN Tunnel ({name})")
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

        // Read recent nettop per-process rates
        let top_processes = self.read_nettop_top_processes();

        NetworkMetrics {
            upload_bps: total_up,
            download_bps: total_down,
            interfaces,
            top_processes,
        }
    }

    fn read_nettop_top_processes(&self) -> Vec<ProcessNetIo> {
        let now = Instant::now();
        let mut out = Vec::new();
        if let Ok(mut guard) = self.nettop_rates.lock() {
            // Retain only fresh samples from the last 10 seconds
            guard.retain(|_, v| {
                v.updated_at
                    .map(|t| now.duration_since(t).as_secs() <= 10)
                    .unwrap_or(false)
            });
            for (pid, sample) in guard.iter() {
                let total = sample.bytes_in.saturating_add(sample.bytes_out);
                if total == 0 {
                    continue;
                }
                out.push(ProcessNetIo {
                    pid: *pid,
                    name: sample.name.clone(),
                    user: String::new(),
                    upload_bps: sample.bytes_out,
                    download_bps: sample.bytes_in,
                    total_bps: total,
                });
            }
        }
        out.sort_by(|a, b| b.total_bps.cmp(&a.total_bps));
        out.truncate(12);
        out
    }
}

impl PlatformCollector for MacosCollector {
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

        let (total_pct, user_pct, system_pct, idle_pct, cores) = self.collect_cpu_cores();
        let load_avg = read_loadavg();
        let (top_cpu, top_mem, top_disk) = self.collect_processes(dt_secs);
        let memory = self.collect_memory(top_mem);
        let disks = self.collect_disks(dt_secs, top_disk);
        let network = self.collect_network(dt_secs);

        let uptime_secs = sysctl_boottime()
            .map(|bt| (Utc::now().timestamp() - bt).max(0) as u64)
            .unwrap_or(0);

        let snapshot = HostSnapshot {
            timestamp: Utc::now().timestamp_millis(),
            host: HostInfo {
                hostname: self.hostname.clone(),
                os: OsKind::Macos,
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
                iowait_pct: 0.0,
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
            oom_events: Vec::new(),
        }
    }
}

fn read_cpu_ticks() -> Vec<[u32; CPU_STATE_MAX]> {
    let mut num_cpus: u32 = 0;
    let mut cpu_info: *mut i32 = std::ptr::null_mut();
    let mut num_cpu_info: u32 = 0;

    let kr = unsafe {
        host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &mut num_cpus,
            &mut cpu_info,
            &mut num_cpu_info,
        )
    };
    if kr != 0 || cpu_info.is_null() || num_cpus == 0 {
        return Vec::new();
    }

    let mut out = Vec::with_capacity(num_cpus as usize);
    unsafe {
        let slice = std::slice::from_raw_parts(cpu_info as *const u32, num_cpu_info as usize);
        for i in 0..(num_cpus as usize) {
            let base = i * CPU_STATE_MAX;
            if base + CPU_STATE_MAX <= slice.len() {
                out.push([
                    slice[base + CPU_STATE_USER],
                    slice[base + CPU_STATE_SYSTEM],
                    slice[base + CPU_STATE_IDLE],
                    slice[base + CPU_STATE_NICE],
                ]);
            }
        }
        vm_deallocate(
            mach_task_self(),
            cpu_info as usize,
            (num_cpu_info as usize) * size_of::<i32>(),
        );
    }
    out
}

fn read_loadavg() -> [f64; 3] {
    let mut load = [0.0_f64; 3];
    unsafe {
        libc::getloadavg(load.as_mut_ptr(), 3);
    }
    load
}

fn list_all_pids() -> Vec<i32> {
    let estimated = unsafe { proc_listallpids(std::ptr::null_mut(), 0) };
    if estimated <= 0 {
        return Vec::new();
    }
    let capacity = (estimated as usize) + 64;
    let mut pids = vec![0_i32; capacity];
    let bytes = unsafe {
        proc_listallpids(
            pids.as_mut_ptr() as *mut c_void,
            (pids.len() * size_of::<i32>()) as i32,
        )
    };
    if bytes <= 0 {
        return Vec::new();
    }
    let count = (bytes as usize) / size_of::<i32>();
    pids.truncate(count.min(pids.len()));
    pids
}

fn extract_proc_name(bsd: &ProcBsdInfo) -> String {
    let long_name = cstr_to_string(&bsd.pbi_name);
    if !long_name.is_empty() {
        long_name
    } else {
        cstr_to_string(&bsd.pbi_comm)
    }
}

fn cstr_to_string(buf: &[libc::c_char]) -> String {
    let bytes: Vec<u8> = buf
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

fn sysctl_string(name: &str) -> Option<String> {
    let cname = CString::new(name).ok()?;
    let mut len: usize = 0;
    unsafe {
        if libc::sysctlbyname(
            cname.as_ptr(),
            std::ptr::null_mut(),
            &mut len,
            std::ptr::null_mut(),
            0,
        ) != 0
            || len == 0
        {
            return None;
        }
        let mut buf = vec![0_u8; len];
        if libc::sysctlbyname(
            cname.as_ptr(),
            buf.as_mut_ptr() as *mut c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        ) != 0
        {
            return None;
        }
        while buf.last() == Some(&0) {
            buf.pop();
        }
        String::from_utf8(buf).ok()
    }
}

fn sysctl_u64(name: &str) -> Option<u64> {
    let cname = CString::new(name).ok()?;
    let mut val: u64 = 0;
    let mut len = size_of::<u64>();
    let ok = unsafe {
        libc::sysctlbyname(
            cname.as_ptr(),
            &mut val as *mut _ as *mut c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        ) == 0
    };
    if ok { Some(val) } else { None }
}

fn sysctl_i32(name: &str) -> Option<i32> {
    let cname = CString::new(name).ok()?;
    let mut val: i32 = 0;
    let mut len = size_of::<i32>();
    let ok = unsafe {
        libc::sysctlbyname(
            cname.as_ptr(),
            &mut val as *mut _ as *mut c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        ) == 0
    };
    if ok { Some(val) } else { None }
}

fn sysctl_boottime() -> Option<i64> {
    let cname = CString::new("kern.boottime").ok()?;
    let mut tv: libc::timeval = unsafe { zeroed() };
    let mut len = size_of::<libc::timeval>();
    let ok = unsafe {
        libc::sysctlbyname(
            cname.as_ptr(),
            &mut tv as *mut _ as *mut c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        ) == 0
    };
    if ok { Some(tv.tv_sec) } else { None }
}

fn sysctl_swapusage() -> Option<XswUsage> {
    let cname = CString::new("vm.swapusage").ok()?;
    let mut val: XswUsage = Default::default();
    let mut len = size_of::<XswUsage>();
    let ok = unsafe {
        libc::sysctlbyname(
            cname.as_ptr(),
            &mut val as *mut _ as *mut c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        ) == 0
    };
    if ok { Some(val) } else { None }
}

fn read_macos_ifmib_counters() -> HashMap<String, (u64, u64)> {
    let mut map = HashMap::new();
    const NETLINK_GENERIC: i32 = 0;
    const IFMIB_SYSTEM: i32 = 1;
    const IFMIB_IFDATA: i32 = 2;
    const IFMIB_IFCOUNT: i32 = 1;
    const IFDATA_GENERAL: i32 = 1;

    let mut count_mib = [
        libc::CTL_NET,
        libc::PF_LINK,
        NETLINK_GENERIC,
        IFMIB_SYSTEM,
        IFMIB_IFCOUNT,
    ];
    let mut if_count: i32 = 0;
    let mut len = size_of::<i32>();
    let ok = unsafe {
        libc::sysctl(
            count_mib.as_mut_ptr(),
            count_mib.len() as u32,
            &mut if_count as *mut _ as *mut c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        ) == 0
    };
    if !ok || if_count <= 0 {
        return map;
    }

    for row in 1..=if_count {
        let mut mib = [
            libc::CTL_NET,
            libc::PF_LINK,
            NETLINK_GENERIC,
            IFMIB_IFDATA,
            row,
            IFDATA_GENERAL,
        ];
        let mut data: IfMibData = unsafe { zeroed() };
        let mut dlen = size_of::<IfMibData>();
        let ok = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                mib.len() as u32,
                &mut data as *mut _ as *mut c_void,
                &mut dlen,
                std::ptr::null_mut(),
                0,
            ) == 0
        };
        if ok {
            let name = cstr_to_string(&data.ifmd_name);
            if !name.is_empty() {
                let ibytes = { data.ifmd_data.ifi_ibytes };
                let obytes = { data.ifmd_data.ifi_obytes };
                map.insert(name, (ibytes, obytes));
            }
        }
    }
    map
}

fn read_iokit_disk_bytes() -> HashMap<String, (u64, u64)> {
    let mut map = HashMap::new();
    unsafe {
        let class_name = CString::new("IOBlockStorageDriver").unwrap();
        let matching = IOServiceMatching(class_name.as_ptr());
        if matching.is_null() {
            return map;
        }
        let mut iter: u32 = 0;
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &mut iter) != 0 {
            return map;
        }

        let stats_key = cf_string("Statistics");
        let read_key = cf_string("Bytes (Read)");
        let write_key = cf_string("Bytes (Write)");
        let bsd_key = cf_string("BSD Name");
        let io_plane = CString::new("IOService").unwrap();

        let mut idx = 0_usize;
        loop {
            let entry = IOIteratorNext(iter);
            if entry == 0 {
                break;
            }
            let mut props: *mut c_void = std::ptr::null_mut();
            if IORegistryEntryCreateCFProperties(entry, &mut props, std::ptr::null(), 0) == 0
                && !props.is_null()
            {
                let stats_dict = CFDictionaryGetValue(props, stats_key);
                if !stats_dict.is_null() && CFGetTypeID(stats_dict) == CFDictionaryGetTypeID() {
                    let read_bytes = cf_dict_i64(stats_dict, read_key).unwrap_or(0).max(0) as u64;
                    let write_bytes = cf_dict_i64(stats_dict, write_key).unwrap_or(0).max(0) as u64;

                    let bsd_name = find_child_bsd_name(entry, io_plane.as_ptr(), bsd_key)
                        .unwrap_or_else(|| format!("disk{idx}"));
                    map.insert(bsd_name, (read_bytes, write_bytes));
                }
                CFRelease(props);
            }
            IOObjectRelease(entry);
            idx += 1;
        }

        CFRelease(stats_key);
        CFRelease(read_key);
        CFRelease(write_key);
        CFRelease(bsd_key);
        IOObjectRelease(iter);
    }
    map
}

unsafe fn find_child_bsd_name(
    parent: u32,
    plane: *const libc::c_char,
    bsd_key: *const c_void,
) -> Option<String> {
    unsafe {
        let mut child_iter: u32 = 0;
        if IORegistryEntryGetChildIterator(parent, plane, &mut child_iter) != 0 {
            return None;
        }
        let mut found = None;
        loop {
            let child = IOIteratorNext(child_iter);
            if child == 0 {
                break;
            }
            let mut props: *mut c_void = std::ptr::null_mut();
            if IORegistryEntryCreateCFProperties(child, &mut props, std::ptr::null(), 0) == 0
                && !props.is_null()
            {
                let val = CFDictionaryGetValue(props, bsd_key);
                if !val.is_null() && CFGetTypeID(val) == CFStringGetTypeID() {
                    let mut buf = [0 as libc::c_char; 64];
                    if CFStringGetCString(
                        val,
                        buf.as_mut_ptr(),
                        buf.len() as isize,
                        K_CF_STRING_ENCODING_UTF8,
                    ) {
                        found = Some(cstr_to_string(&buf));
                    }
                }
                CFRelease(props);
            }
            IOObjectRelease(child);
            if found.is_some() {
                break;
            }
        }
        IOObjectRelease(child_iter);
        found
    }
}

unsafe fn cf_string(s: &str) -> *const c_void {
    let cs = CString::new(s).unwrap();
    unsafe { CFStringCreateWithCString(std::ptr::null(), cs.as_ptr(), K_CF_STRING_ENCODING_UTF8) }
}

unsafe fn cf_dict_i64(dict: *const c_void, key: *const c_void) -> Option<i64> {
    unsafe {
        let num = CFDictionaryGetValue(dict, key);
        if num.is_null() || CFGetTypeID(num) != CFNumberGetTypeID() {
            return None;
        }
        let mut val: i64 = 0;
        if CFNumberGetValue(num, K_CF_NUMBER_SINT64_TYPE, &mut val as *mut _ as *mut c_void) {
            Some(val)
        } else {
            None
        }
    }
}

fn spawn_nettop_reader(store: Arc<Mutex<HashMap<u32, NettopSample>>>) {
    std::thread::Builder::new()
        .name("fleetd-nettop".to_string())
        .spawn(move || {
            loop {
                let child = Command::new("/usr/bin/nettop")
                    .args(["-P", "-x", "-d", "-s", "4", "-L", "0", "-J", "bytes_in,bytes_out"])
                    .stdout(Stdio::piped())
                    .stderr(Stdio::null())
                    .spawn();

                let mut child = match child {
                    Ok(c) => c,
                    Err(_) => {
                        std::thread::sleep(std::time::Duration::from_secs(10));
                        continue;
                    }
                };

                if let Some(stdout) = child.stdout.take() {
                    let reader = BufReader::new(stdout);
                    let mut batch_started = false;
                    let mut seen_header_count = 0_u64;
                    for line in reader.lines().map_while(Result::ok) {
                        let trimmed = line.trim();
                        if trimmed.is_empty() {
                            continue;
                        }
                        if trimmed.starts_with(",bytes_in") {
                            seen_header_count += 1;
                            batch_started = true;
                            continue;
                        }
                        // Skip the very first cumulative snapshot (header #1); delta frames start at #2
                        if !batch_started || seen_header_count < 2 {
                            continue;
                        }
                        let mut parts = trimmed.split(',');
                        let proc_col = match parts.next() {
                            Some(p) if !p.is_empty() => p,
                            _ => continue,
                        };
                        let bytes_in: u64 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
                        let bytes_out: u64 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);

                        if let Some((name, pid_str)) = proc_col.rsplit_once('.') {
                            if let Ok(pid) = pid_str.parse::<u32>() {
                                // `-s 4` reports 4-second delta -> divide by 4 for B/s
                                let in_bps = bytes_in / 4;
                                let out_bps = bytes_out / 4;
                                if let Ok(mut map) = store.lock() {
                                    map.insert(
                                        pid,
                                        NettopSample {
                                            name: name.to_string(),
                                            bytes_in: in_bps,
                                            bytes_out: out_bps,
                                            updated_at: Some(Instant::now()),
                                        },
                                    );
                                }
                            }
                        }
                    }
                }
                let _ = child.wait();
                std::thread::sleep(std::time::Duration::from_secs(5));
            }
        })
        .ok();
}

fn should_keep_macos_iface(name: &str) -> bool {
    name.starts_with("en") || name.starts_with("utun") || name.starts_with("bridge")
}

fn is_tailscale_ipv4(ip: &str) -> bool {
    if let Ok(addr) = ip.parse::<Ipv4Addr>() {
        let octets = addr.octets();
        octets[0] == 100 && (64..=127).contains(&octets[1])
    } else {
        false
    }
}

fn extract_bsd_disk_prefix(dev: &str) -> Option<String> {
    let trimmed = dev.strip_prefix("/dev/")?;
    if !trimmed.starts_with("disk") {
        return None;
    }
    let digits: String = trimmed["disk".len()..]
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    if digits.is_empty() {
        None
    } else {
        Some(format!("disk{digits}"))
    }
}

fn get_hostname() -> String {
    let mut buf = [0 as libc::c_char; 256];
    unsafe {
        if libc::gethostname(buf.as_mut_ptr(), buf.len()) == 0 {
            let s = cstr_to_string(&buf);
            if !s.is_empty() {
                return s.trim_end_matches(".local").to_string();
            }
        }
    }
    "Mac".to_string()
}

fn get_macos_version() -> String {
    let ver = sysctl_string("kern.osproductversion").unwrap_or_else(|| "macOS".to_string());
    format!("macOS {ver}")
}

fn clamp_pct(v: f64) -> f64 {
    if v.is_nan() || v.is_infinite() {
        0.0
    } else {
        v.clamp(0.0, 100.0)
    }
}
