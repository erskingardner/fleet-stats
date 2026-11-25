import Foundation

public enum OsKind: String, Codable, Sendable {
    case macos
    case linux
}

public enum CoreKind: String, Codable, Sendable {
    case performance
    case efficiency
    case standard
}

public enum PressureLevel: String, Codable, Sendable {
    case normal
    case warn
    case critical
}

public enum AlertSeverity: String, Codable, Sendable, Comparable {
    case info
    case warning
    case critical

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .critical: 2
        }
    }

    public static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum EventKind: String, Codable, Sendable {
    case oomKill = "oom_kill"
    case unexpectedReboot = "unexpected_reboot"
    case alertTriggered = "alert_triggered"
    case alertResolved = "alert_resolved"
}

public struct HealthResponse: Codable, Sendable {
    public let status: String
    public let version: String
    public let hostname: String
    public let os: OsKind
    public let osVersion: String
    public let arch: String
    public let uptimeSecs: UInt64
    public let bootId: String
    public let cpuModel: String
    public let cpuCores: Int
    public let memoryTotalBytes: UInt64
}

public struct HostInfo: Codable, Sendable, Equatable {
    public let hostname: String
    public let os: OsKind
    public let osVersion: String
    public let arch: String
    public let uptimeSecs: UInt64
    public let bootId: String
    public let cpuModel: String
}

public struct HostSnapshot: Codable, Sendable {
    public let timestamp: Int64
    public let host: HostInfo
    public let cpu: CpuMetrics
    public let memory: MemoryMetrics
    public let disks: DiskMetrics
    public let network: NetworkMetrics
    public let activeAlerts: [ActiveAlert]
}

public struct CpuMetrics: Codable, Sendable {
    public let totalPct: Double
    public let userPct: Double
    public let systemPct: Double
    public let iowaitPct: Double
    public let idlePct: Double
    public let loadAvg: [Double]
    public let cores: [CoreUsage]
    public let topProcesses: [ProcessCpu]
}

public struct CoreUsage: Codable, Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let usagePct: Double
    public let kind: CoreKind
}

public struct ProcessCpu: Codable, Sendable, Identifiable {
    public var id: UInt32 { pid }
    public let pid: UInt32
    public let name: String
    public let user: String
    public let cpuPct: Double
    public let memoryBytes: UInt64
}

public struct MemoryMetrics: Codable, Sendable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let usedPct: Double
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedBytes: UInt64
    public let freeBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let pressureLevel: PressureLevel
    public let pressurePct: Double
    public let psiSomeAvg10: Double?
    public let psiFullAvg10: Double?
    public let topProcesses: [ProcessMemory]
}

public struct ProcessMemory: Codable, Sendable, Identifiable {
    public var id: UInt32 { pid }
    public let pid: UInt32
    public let name: String
    public let user: String
    public let memoryBytes: UInt64
    public let oomScore: Int32?
}

public struct DiskMetrics: Codable, Sendable {
    public let primaryUsedPct: Double
    public let totalReadBps: UInt64
    public let totalWriteBps: UInt64
    public let volumes: [DiskVolume]
    public let topProcesses: [ProcessDiskIo]
}

public struct DiskVolume: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let mountPoint: String
    public let filesystem: String
    public let isExternal: Bool
    public let isPrimary: Bool
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let freeBytes: UInt64
    public let usedPct: Double
    public let readBps: UInt64
    public let writeBps: UInt64
}

public struct ProcessDiskIo: Codable, Sendable, Identifiable {
    public var id: UInt32 { pid }
    public let pid: UInt32
    public let name: String
    public let user: String
    public let readBps: UInt64
    public let writeBps: UInt64
    public let totalBps: UInt64
}

public struct NetworkMetrics: Codable, Sendable {
    public let uploadBps: UInt64
    public let downloadBps: UInt64
    public let interfaces: [NetworkInterface]
    public let topProcesses: [ProcessNetIo]
}

public struct NetworkInterface: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let isUp: Bool
    public let isPhysical: Bool
    public let ipv4: [String]
    public let ipv6: [String]
    public let uploadBps: UInt64
    public let downloadBps: UInt64
}

public struct ProcessNetIo: Codable, Sendable, Identifiable {
    public var id: UInt32 { pid }
    public let pid: UInt32
    public let name: String
    public let user: String
    public let uploadBps: UInt64
    public let downloadBps: UInt64
    public let totalBps: UInt64
}

public struct ActiveAlert: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let metric: String
    public let severity: AlertSeverity
    public let title: String
    public let detail: String
    public let value: Double
    public let threshold: Double
    public let triggeredAt: Int64
    public let topProcess: String?
}

public struct HistoryResponse: Codable, Sendable {
    public let window: String
    public let resolutionSecs: UInt64
    public let points: [HistoryPoint]
}

public struct HistoryPoint: Codable, Sendable, Identifiable {
    public var id: Int64 { timestamp }
    public let timestamp: Int64
    public let cpuPct: Double
    public let cpuMaxPct: Double
    public let memUsedPct: Double
    public let memMaxPct: Double
    public let memPressurePct: Double
    public let swapUsedPct: Double
    public let diskPrimaryPct: Double
    public let diskReadBps: UInt64
    public let diskWriteBps: UInt64
    public let netUpBps: UInt64
    public let netDownBps: UInt64
    public let topCpuProc: String?
    public let topMemProc: String?

    public var date: Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
    }

    public init(from snapshot: HostSnapshot) {
        let swapPct: Double = snapshot.memory.swapTotalBytes > 0
            ? (Double(snapshot.memory.swapUsedBytes) / Double(snapshot.memory.swapTotalBytes)) * 100.0
            : 0.0
        self.timestamp = snapshot.timestamp
        self.cpuPct = snapshot.cpu.totalPct
        self.cpuMaxPct = snapshot.cpu.totalPct
        self.memUsedPct = snapshot.memory.usedPct
        self.memMaxPct = snapshot.memory.usedPct
        self.memPressurePct = snapshot.memory.pressurePct
        self.swapUsedPct = swapPct
        self.diskPrimaryPct = snapshot.disks.primaryUsedPct
        self.diskReadBps = snapshot.disks.totalReadBps
        self.diskWriteBps = snapshot.disks.totalWriteBps
        self.netUpBps = snapshot.network.uploadBps
        self.netDownBps = snapshot.network.downloadBps
        self.topCpuProc = snapshot.cpu.topProcesses.first?.name
        self.topMemProc = snapshot.memory.topProcesses.first?.name
    }
}

public struct FleetEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let timestamp: Int64
    public let kind: EventKind
    public let severity: AlertSeverity
    public let metric: String?
    public let title: String
    public let detail: String
    public let processName: String?
    public let processPid: UInt32?
    public let value: Double?

    public var date: Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
    }
}

public struct EventsResponse: Codable, Sendable {
    public let events: [FleetEvent]
}

public enum WebhookKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case ntfy
    case pushover
    case discord
    case generic

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .ntfy: "ntfy"
        case .pushover: "Pushover"
        case .discord: "Discord"
        case .generic: "Generic Webhook"
        }
    }
}

public struct WebhookTarget: Codable, Sendable, Identifiable, Equatable {
    public var id: String { "\(kind.rawValue)-\(name)-\(url)" }
    public var name: String
    public var kind: WebhookKind
    public var url: String
    public var tokenOrKey: String?
    public var userKey: String?
    public var minSeverity: AlertSeverity
    public var enabled: Bool

    public init(
        name: String,
        kind: WebhookKind,
        url: String,
        tokenOrKey: String? = nil,
        userKey: String? = nil,
        minSeverity: AlertSeverity = .critical,
        enabled: Bool = true
    ) {
        self.name = name
        self.kind = kind
        self.url = url
        self.tokenOrKey = tokenOrKey
        self.userKey = userKey
        self.minSeverity = minSeverity
        self.enabled = enabled
    }
}

public struct AlertConfig: Codable, Sendable, Equatable {
    public var cpuWarnPct: Double
    public var cpuCritPct: Double
    public var cpuDurationSecs: UInt64
    public var memWarnPct: Double
    public var memCritPct: Double
    public var memDurationSecs: UInt64
    public var swapWarnPct: Double
    public var swapCritPct: Double
    public var swapDurationSecs: UInt64
    public var diskWarnPct: Double
    public var diskCritPct: Double
    public var oomAlertsEnabled: Bool
    public var cooldownSecs: UInt64
    public var webhooks: [WebhookTarget]

    public static let defaults = AlertConfig(
        cpuWarnPct: 90,
        cpuCritPct: 97,
        cpuDurationSecs: 180,
        memWarnPct: 85,
        memCritPct: 92,
        memDurationSecs: 60,
        swapWarnPct: 70,
        swapCritPct: 90,
        swapDurationSecs: 120,
        diskWarnPct: 85,
        diskCritPct: 93,
        oomAlertsEnabled: true,
        cooldownSecs: 300,
        webhooks: []
    )
}

public enum StreamMessage: Sendable {
    case snapshot(HostSnapshot)
    case event(FleetEvent)
}

extension StreamMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "snapshot":
            self = .snapshot(try container.decode(HostSnapshot.self, forKey: .data))
        case "event":
            self = .event(try container.decode(FleetEvent.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown stream message type: \(type)"
            )
        }
    }
}

public struct FleetHostConfig: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var address: String
    public var port: Int
    public var isLocal: Bool
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        address: String,
        port: Int = 9470,
        isLocal: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.isLocal = isLocal
        self.enabled = enabled
    }

    public var baseURL: URL? {
        let trimmed = address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.contains(":") && !trimmed.hasPrefix("[") {
            return URL(string: "http://\(trimmed)")
        }
        return URL(string: "http://\(trimmed):\(port)")
    }
}

public enum HostConnectionStatus: Sendable, Equatable {
    case connecting
    case online
    case unauthorized
    case offline(String)

    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}

public enum MetricTab: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case ram
    case ssd
    case network

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .ram: "RAM"
        case .ssd: "SSD"
        case .network: "Network"
        }
    }

    public var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .ram: "memorychip"
        case .ssd: "internaldrive"
        case .network: "network"
        }
    }
}

public enum HistoryWindow: String, CaseIterable, Identifiable, Sendable {
    case live = "live"
    case oneHour = "1h"
    case sixHours = "6h"
    case oneDay = "24h"
    case sevenDays = "7d"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .live: "Live"
        case .oneHour: "1h"
        case .sixHours: "6h"
        case .oneDay: "24h"
        case .sevenDays: "7d"
        }
    }
}

public struct FleetIncidentItem: Identifiable, Sendable {
    public let id: String
    public let hostId: UUID
    public let hostName: String
    public let event: FleetEvent
}

public enum FleetJSON {
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}
