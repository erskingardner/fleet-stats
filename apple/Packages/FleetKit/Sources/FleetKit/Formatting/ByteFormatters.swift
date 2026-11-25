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

    /// Formats an upload/download pair using one synchronized unit (`KB/s`, `MB/s`, or `GB/s`)
    /// so both rows always share the same unit and never jitter horizontally in the menu bar.
    public static func pairedMenuRates(
        up: UInt64,
        down: UInt64
    ) -> (upValue: String, downValue: String, unit: String) {
        let peak = max(up, down)
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0

        if Double(peak) >= 1000.0 * mb {
            return (
                formatPairedNumber(Double(up) / gb, allowDecimal: true),
                formatPairedNumber(Double(down) / gb, allowDecimal: true),
                "GB/s"
            )
        } else if Double(peak) >= 1000.0 * kb {
            return (
                formatPairedNumber(Double(up) / mb, allowDecimal: true),
                formatPairedNumber(Double(down) / mb, allowDecimal: true),
                "MB/s"
            )
        } else {
            return (
                formatPairedNumber(Double(up) / kb, allowDecimal: false),
                formatPairedNumber(Double(down) / kb, allowDecimal: false),
                "KB/s"
            )
        }
    }

    private static func formatPairedNumber(_ value: Double, allowDecimal: Bool) -> String {
        if allowDecimal {
            if value < 10.0 {
                return String(format: "%.1f", value)
            } else if value < 100.0 {
                return String(format: "%.1f", value)
            } else {
                return String(format: "%.0f", min(value, 999.0))
            }
        } else {
            let rounded = value.rounded()
            if rounded < 1 && value > 0 {
                return "1"
            }
            return String(format: "%.0f", min(rounded, 999.0))
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
