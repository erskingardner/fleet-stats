import Foundation
import Testing
@testable import FleetKit

@Test func decodeFleetdSnapshotJSON() throws {
    let json = """
    {
      "timestamp": 1732520000000,
      "host": {
        "hostname": "linux-tower",
        "os": "linux",
        "os_version": "Debian GNU/Linux 12 (bookworm)",
        "arch": "x86_64",
        "uptime_secs": 86400,
        "boot_id": "abc-123",
        "cpu_model": "AMD Ryzen 9 7950X"
      },
      "cpu": {
        "total_pct": 42.5,
        "user_pct": 35.0,
        "system_pct": 7.0,
        "iowait_pct": 0.5,
        "idle_pct": 57.5,
        "load_avg": [1.2, 1.5, 1.1],
        "cores": [{ "index": 0, "usage_pct": 50.0, "kind": "standard" }],
        "top_processes": [{ "pid": 42, "name": "agent", "user": "jeff", "cpu_pct": 33.2, "memory_bytes": 1073741824 }]
      },
      "memory": {
        "total_bytes": 68719476736,
        "used_bytes": 34359738368,
        "used_pct": 50.0,
        "app_bytes": 25000000000,
        "wired_bytes": 5000000000,
        "compressed_bytes": 0,
        "cached_bytes": 4359738368,
        "free_bytes": 30000000000,
        "swap_used_bytes": 0,
        "swap_total_bytes": 8589934592,
        "pressure_level": "normal",
        "pressure_pct": 48.0,
        "psi_some_avg10": 0.2,
        "psi_full_avg10": 0.0,
        "top_processes": [{ "pid": 42, "name": "agent", "user": "jeff", "memory_bytes": 1073741824, "oom_score": 120 }]
      },
      "disks": {
        "primary_used_pct": 61.5,
        "total_read_bps": 1048576,
        "total_write_bps": 524288,
        "volumes": [{
          "id": "/dev/nvme0n1p2",
          "name": "Root (/)",
          "mount_point": "/",
          "filesystem": "ext4",
          "is_external": false,
          "is_primary": true,
          "total_bytes": 1000000000000,
          "used_bytes": 615000000000,
          "free_bytes": 385000000000,
          "used_pct": 61.5,
          "read_bps": 1048576,
          "write_bps": 524288
        }],
        "top_processes": []
      },
      "network": {
        "upload_bps": 30720,
        "download_bps": 584704,
        "interfaces": [{
          "name": "tailscale0",
          "display_name": "Tailscale",
          "is_up": true,
          "is_physical": false,
          "ipv4": ["100.64.1.2"],
          "ipv6": [],
          "upload_bps": 1024,
          "download_bps": 2048
        }],
        "top_processes": []
      },
      "active_alerts": []
    }
    """
    let snap = try FleetJSON.makeDecoder().decode(HostSnapshot.self, from: Data(json.utf8))
    #expect(snap.host.hostname == "linux-tower")
    #expect(snap.host.os == .linux)
    #expect(snap.memory.topProcesses.first?.oomScore == 120)
    #expect(ByteFormatters.compactMenuRate(snap.network.uploadBps) == "30 KB/s")
    #expect(ByteFormatters.compactMenuRate(snap.network.downloadBps) == "571 KB/s")
}
