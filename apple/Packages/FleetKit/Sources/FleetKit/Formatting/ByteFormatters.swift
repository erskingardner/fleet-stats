import Foundation

public enum ByteFormatters {
    public static func rate(_ bytesPerSec: UInt64) -> String {
        let val = Double(bytesPerSec)
        if val < 1024 {
            return String(format: "%.0f B/s", val)
        } else if val < 1024 * 1024 {
            return String(format: "%.0f KB/s", val / 1024.0)
        } else if val < 1024 * 1024 * 1024 {
            let mb = val / (1024.0 * 1024.0)
            return mb < 10 ? String(format: "%.1f MB/s", mb) : String(format: "%.0f MB/s", mb)
        } else {
            return String(format: "%.2f GB/s", val / (1024.0 * 1024.0 * 1024.0))
        }
    }

    public static func compactMenuRate(_ bytesPerSec: UInt64) -> String {
        let val = Double(bytesPerSec)
        if val < 1024 {
            return String(format: "%.0f B/s", val)
        } else if val < 1024 * 1024 {
            return String(format: "%.0f KB/s", val / 1024.0)
        } else if val < 1024 * 1024 * 1024 {
            let mb = val / (1024.0 * 1024.0)
            return mb < 10 ? String(format: "%.1f MB/s", mb) : String(format: "%.0f MB/s", mb)
        } else {
            return String(format: "%.1f GB/s", val / (1024.0 * 1024.0 * 1024.0))
        }
    }

    public static func bytes(_ count: UInt64) -> String {
        let val = Double(count)
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0
        let tb = gb * 1024.0

        if val < kb {
            return "\(count) B"
        } else if val < mb {
            return String(format: "%.0f KB", val / kb)
        } else if val < gb {
            return String(format: "%.0f MB", val / mb)
        } else if val < tb {
            let g = val / gb
            return g < 100 ? String(format: "%.1f GB", g) : String(format: "%.0f GB", g)
        } else {
            return String(format: "%.2f TB", val / tb)
        }
    }

    public static func diskBytes(_ count: UInt64) -> String {
        // Decimal units (GB/TB) match macOS Finder & SSD marketing labels
        let val = Double(count)
        let gb = 1_000_000_000.0
        let tb = 1_000_000_000_000.0
        if val >= tb {
            return String(format: "%.2f TB", val / tb)
        } else if val >= gb {
            let g = val / gb
            return g < 100 ? String(format: "%.1f GB", g) : String(format: "%.0f GB", g)
        } else {
            return String(format: "%.0f MB", val / 1_000_000.0)
        }
    }

    public static func percent(_ value: Double, decimals: Int = 0) -> String {
        if decimals == 0 {
            return String(format: "%.0f%%", value.rounded())
        }
        return String(format: "%.\(decimals)f%%", value)
    }

    public static func uptime(_ seconds: UInt64) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(mins)m"
        } else {
            return "\(mins)m"
        }
    }
}
