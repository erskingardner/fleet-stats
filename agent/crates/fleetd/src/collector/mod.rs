use crate::model::HostSnapshot;

#[cfg(target_os = "linux")]
pub mod linux;

#[cfg(target_os = "macos")]
pub mod macos;

#[derive(Debug, Clone)]
pub struct OomEvent {
    pub process_name: Option<String>,
    pub pid: Option<u32>,
    pub detail: String,
}

pub struct CollectionResult {
    pub snapshot: HostSnapshot,
    pub oom_events: Vec<OomEvent>,
}

pub trait PlatformCollector: Send {
    fn boot_id(&self) -> String;
    fn collect(&mut self) -> CollectionResult;
}

pub fn create_collector() -> Box<dyn PlatformCollector> {
    #[cfg(target_os = "macos")]
    {
        Box::new(macos::MacosCollector::new())
    }
    #[cfg(target_os = "linux")]
    {
        Box::new(linux::LinuxCollector::new())
    }
}

pub fn username_for_uid(uid: u32) -> String {
    unsafe {
        let pw = libc::getpwuid(uid);
        if pw.is_null() || (*pw).pw_name.is_null() {
            return uid.to_string();
        }
        std::ffi::CStr::from_ptr((*pw).pw_name)
            .to_string_lossy()
            .into_owned()
    }
}
