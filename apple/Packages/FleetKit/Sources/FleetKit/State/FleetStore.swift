import Foundation
import Observation

@Observable
@MainActor
public final class HostRuntimeState {
    public var status: HostConnectionStatus = .connecting
    public var snapshot: HostSnapshot?
    public var livePoints: [HistoryPoint] = []
    public var historyByWindow: [HistoryWindow: [HistoryPoint]] = [:]
    public var events: [FleetEvent] = []
    public var alertConfig: AlertConfig?
    public var lastSeenAt: Date?

    public init() {}

    public var highestAlertSeverity: AlertSeverity? {
        if case .offline = status {
            return .critical
        }
        return snapshot?.activeAlerts.map(\.severity).max()
    }

    public func points(for window: HistoryWindow) -> [HistoryPoint] {
        if window == .live {
            return livePoints
        }
        return historyByWindow[window] ?? livePoints
    }
}

public struct FleetNotificationPayload: Sendable {
    public let hostId: UUID
    public let hostName: String
    public let metricTab: MetricTab
    public let severity: AlertSeverity
    public let title: String
    public let body: String
}

@Observable
@MainActor
public final class FleetStore {
    public var hosts: [FleetHostConfig] = []
    public var states: [UUID: HostRuntimeState] = [:]
    public var selectedHostID: UUID?
    public var selectedTab: MetricTab = .cpu
    public var selectedWindow: HistoryWindow = .live
    public var showingEvents: Bool = false

    /// Per-host timestamp watermark (epoch ms); events at or before this are cleared/read.
    public var clearedBeforeMs: [UUID: Int64] = [:]
    /// Active alert keys (`hostId:alertId:triggeredAt`) dismissed by the user.
    public var dismissedActiveAlertKeys: Set<String> = []

    public var onNotification: (@Sendable (FleetNotificationPayload) -> Void)?

    private let client = FleetClient()
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    private var offlineNotified: Set<UUID> = []
    private var seenEventIDs: [UUID: Set<Int64>] = [:]
    private let hostsDefaultsKey = "com.fleetstats.hosts.v1"
    private let clearedDefaultsKey = "com.fleetstats.clearedBeforeMs.v1"

    public init() {
        loadSavedHosts()
        loadClearedWatermarks()
    }

    public var localHost: FleetHostConfig? {
        hosts.first(where: \.isLocal) ?? hosts.first
    }

    public var localSnapshot: HostSnapshot? {
        guard let id = localHost?.id else { return nil }
        return states[id]?.snapshot
    }

    public var selectedHost: FleetHostConfig? {
        if let id = selectedHostID, let found = hosts.first(where: { $0.id == id }) {
            return found
        }
        return localHost
    }

    public var selectedState: HostRuntimeState? {
        guard let id = selectedHost?.id else { return nil }
        return states[id]
    }

    public func activeAlertKey(hostID: UUID, alert: ActiveAlert) -> String {
        "\(hostID.uuidString):\(alert.id):\(alert.triggeredAt)"
    }

    public func visibleActiveAlerts(for hostID: UUID) -> [ActiveAlert] {
        guard let alerts = states[hostID]?.snapshot?.activeAlerts else { return [] }
        return alerts.filter { !dismissedActiveAlertKeys.contains(activeAlertKey(hostID: hostID, alert: $0)) }
    }

    public func dismissActiveAlert(_ alert: ActiveAlert, for hostID: UUID) {
        dismissedActiveAlertKeys.insert(activeAlertKey(hostID: hostID, alert: alert))
    }

    public var totalActiveAlertCount: Int {
        hosts.reduce(0) { acc, host in
            guard let st = states[host.id] else { return acc }
            let activeCount = visibleActiveAlerts(for: host.id).count
            let unreadEvents = st.events.filter { ev in
                ev.kind != .alertResolved && ev.timestamp > (clearedBeforeMs[host.id] ?? 0)
            }.count
            let offlineCount = (!host.isLocal && !st.status.isOnline && st.lastSeenAt != nil) ? 1 : 0
            return acc + activeCount + unreadEvents + offlineCount
        }
    }

    public func incidents(includeCleared: Bool = false) -> [FleetIncidentItem] {
        var all: [FleetIncidentItem] = []
        for host in hosts {
            let watermark = clearedBeforeMs[host.id] ?? 0
            let hostEvents = states[host.id]?.events ?? []
            for ev in hostEvents {
                if !includeCleared && ev.timestamp <= watermark {
                    continue
                }
                all.append(FleetIncidentItem(
                    id: "\(host.id.uuidString)-\(ev.id)",
                    hostId: host.id,
                    hostName: host.name,
                    event: ev
                ))
            }
        }
        return all.sorted { $0.event.timestamp > $1.event.timestamp }
    }

    public var aggregatedIncidents: [FleetIncidentItem] {
        incidents(includeCleared: false)
    }

    /// Marks all current incidents & active alerts across the fleet (or a single host) as read/cleared.
    public func clearAlerts(for hostID: UUID? = nil) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)
        let targetHosts = hostID.map { id in hosts.filter { $0.id == id } } ?? hosts
        for host in targetHosts {
            let maxEventTs = states[host.id]?.events.map(\.timestamp).max() ?? 0
            clearedBeforeMs[host.id] = max(nowMs, maxEventTs)
            if let alerts = states[host.id]?.snapshot?.activeAlerts {
                for alert in alerts {
                    dismissedActiveAlertKeys.insert(activeAlertKey(hostID: host.id, alert: alert))
                }
            }
        }
        persistClearedWatermarks()
    }

    public func ensureLocalHost(name: String, port: Int = 9470, token: String) -> FleetHostConfig {
        if let idx = hosts.firstIndex(where: \.isLocal) {
            hosts[idx].port = port
            let existing = hosts[idx]
            KeychainStore.saveToken(token, for: existing.id)
            if states[existing.id] == nil {
                states[existing.id] = HostRuntimeState()
            }
            if selectedHostID == nil {
                selectedHostID = existing.id
            }
            persistHosts()
            startStreaming(host: existing)
            return existing
        }

        let local = FleetHostConfig(
            name: name,
            address: "127.0.0.1",
            port: port,
            isLocal: true,
            enabled: true
        )
        hosts.insert(local, at: 0)
        states[local.id] = HostRuntimeState()
        KeychainStore.saveToken(token, for: local.id)
        selectedHostID = local.id
        persistHosts()
        startStreaming(host: local)
        return local
    }

    public func startAllStreams() {
        for host in hosts where host.enabled {
            if states[host.id] == nil {
                states[host.id] = HostRuntimeState()
            }
            startStreaming(host: host)
        }
    }

    public func stopAllStreams() {
        for (_, task) in streamTasks {
            task.cancel()
        }
        streamTasks.removeAll()
    }

    public func addHost(name: String, address: String, port: Int, token: String) -> FleetHostConfig {
        let host = FleetHostConfig(
            name: name,
            address: address,
            port: port,
            isLocal: false,
            enabled: true
        )
        hosts.append(host)
        states[host.id] = HostRuntimeState()
        KeychainStore.saveToken(token, for: host.id)
        persistHosts()
        startStreaming(host: host)
        return host
    }

    public func updateHost(_ host: FleetHostConfig, newToken: String?) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[idx] = host
        if let newToken, !newToken.isEmpty {
            KeychainStore.saveToken(newToken, for: host.id)
        }
        persistHosts()
        stopStreaming(hostID: host.id)
        if host.enabled {
            startStreaming(host: host)
        }
    }

    public func removeHost(_ hostID: UUID) {
        guard let idx = hosts.firstIndex(where: { $0.id == hostID && !$0.isLocal }) else { return }
        stopStreaming(hostID: hostID)
        hosts.remove(at: idx)
        states.removeValue(forKey: hostID)
        KeychainStore.deleteToken(for: hostID)
        if selectedHostID == hostID {
            selectedHostID = localHost?.id
        }
        persistHosts()
    }

    public func testConnection(address: String, port: Int, token: String) async throws -> HealthResponse {
        let probe = FleetHostConfig(name: "Probe", address: address, port: port)
        return try await client.fetchHealth(host: probe, token: token)
    }

    public func refreshHistory(for hostID: UUID, window: HistoryWindow) async {
        guard let host = hosts.first(where: { $0.id == hostID }),
              let token = KeychainStore.loadToken(for: hostID),
              let state = states[hostID] else { return }
        do {
            let resp = try await client.fetchHistory(host: host, token: token, window: window)
            if window == .live {
                if state.livePoints.isEmpty {
                    state.livePoints = resp.points
                }
            } else {
                state.historyByWindow[window] = resp.points
            }
        } catch {
            // Keep existing cached chart data
        }
    }

    public func refreshEvents(for hostID: UUID) async {
        guard let host = hosts.first(where: { $0.id == hostID }),
              let token = KeychainStore.loadToken(for: hostID),
              let state = states[hostID] else { return }
        do {
            let fetched = try await client.fetchEvents(host: host, token: token, limit: 80)
            state.events = fetched
            seenEventIDs[hostID] = Set(fetched.map(\.id))
        } catch {
            // Keep existing cached events
        }
    }

    public func loadAlertConfig(for hostID: UUID) async -> AlertConfig? {
        guard let host = hosts.first(where: { $0.id == hostID }),
              let token = KeychainStore.loadToken(for: hostID) else { return nil }
        if let cfg = try? await client.fetchAlertConfig(host: host, token: token) {
            states[hostID]?.alertConfig = cfg
            return cfg
        }
        return states[hostID]?.alertConfig
    }

    public func saveAlertConfig(_ config: AlertConfig, for hostID: UUID) async throws {
        guard let host = hosts.first(where: { $0.id == hostID }),
              let token = KeychainStore.loadToken(for: hostID) else { return }
        let saved = try await client.updateAlertConfig(host: host, token: token, config: config)
        states[hostID]?.alertConfig = saved
    }

    public func selectNextHost(delta: Int) {
        guard !hosts.isEmpty else { return }
        let currentIdx = hosts.firstIndex(where: { $0.id == selectedHost?.id }) ?? 0
        let nextIdx = (currentIdx + delta + hosts.count) % hosts.count
        selectedHostID = hosts[nextIdx].id
    }

    private func startStreaming(host: FleetHostConfig) {
        stopStreaming(hostID: host.id)
        let hostID = host.id
        streamTasks[hostID] = Task { [weak self] in
            var backoffSecs: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { return }
                guard let currentHost = self.hosts.first(where: { $0.id == hostID && $0.enabled }) else {
                    return
                }
                guard let token = KeychainStore.loadToken(for: hostID), !token.isEmpty else {
                    self.states[hostID]?.status = .unauthorized
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }

                // Seed recent history & events once connected
                Task { [weak self] in
                    await self?.refreshHistory(for: hostID, window: .live)
                    await self?.refreshEvents(for: hostID)
                }

                do {
                    for try await msg in self.client.stream(host: currentHost, token: token) {
                        if Task.isCancelled { return }
                        backoffSecs = 1
                        self.handleStreamMessage(msg, for: currentHost)
                    }
                    // Stream ended cleanly; reconnect shortly
                    self.markDisconnected(host: currentHost, reason: "Connection closed")
                } catch FleetClientError.unauthorized {
                    self.states[hostID]?.status = .unauthorized
                    backoffSecs = 10
                } catch {
                    if Task.isCancelled { return }
                    self.markDisconnected(host: currentHost, reason: error.localizedDescription)
                }

                try? await Task.sleep(for: .seconds(backoffSecs))
                backoffSecs = min(backoffSecs * 2, 15)
            }
        }
    }

    private func stopStreaming(hostID: UUID) {
        streamTasks[hostID]?.cancel()
        streamTasks.removeValue(forKey: hostID)
    }

    private func handleStreamMessage(_ msg: StreamMessage, for host: FleetHostConfig) {
        let state = states[host.id] ?? {
            let s = HostRuntimeState()
            states[host.id] = s
            return s
        }()

        state.status = .online
        state.lastSeenAt = Date()
        offlineNotified.remove(host.id)

        switch msg {
        case .snapshot(let snap):
            state.snapshot = snap
            state.livePoints.append(HistoryPoint(from: snap))
            if state.livePoints.count > 240 {
                state.livePoints.removeFirst(state.livePoints.count - 240)
            }
        case .event(let ev):
            var seen = seenEventIDs[host.id] ?? []
            if seen.insert(ev.id).inserted {
                seenEventIDs[host.id] = seen
                state.events.insert(ev, at: 0)
                if state.events.count > 100 {
                    state.events.removeLast(state.events.count - 100)
                }
                if ev.kind == .oomKill || ev.kind == .unexpectedReboot || ev.kind == .alertTriggered {
                    let tab = metricTab(for: ev.metric)
                    onNotification?(FleetNotificationPayload(
                        hostId: host.id,
                        hostName: host.name,
                        metricTab: tab,
                        severity: ev.severity,
                        title: "\(host.name): \(ev.title)",
                        body: ev.detail
                    ))
                }
            }
        }
    }

    private func markDisconnected(host: FleetHostConfig, reason: String) {
        guard let state = states[host.id] else { return }
        let wasOnlineBefore = state.lastSeenAt != nil
        state.status = .offline(reason)

        if !host.isLocal,
           wasOnlineBefore,
           let lastSeen = state.lastSeenAt,
           Date().timeIntervalSince(lastSeen) >= 25,
           !offlineNotified.contains(host.id) {
            offlineNotified.insert(host.id)
            onNotification?(FleetNotificationPayload(
                hostId: host.id,
                hostName: host.name,
                metricTab: .ram,
                severity: .critical,
                title: "\(host.name) Unreachable",
                body: "Lost connection to \(host.address):\(host.port). Check for crash or OOM reboot."
            ))
        }
    }

    private func metricTab(for metric: String?) -> MetricTab {
        switch metric {
        case "cpu": .cpu
        case "memory", "swap", "oom": .ram
        case "disk": .ssd
        case "network": .network
        default: .ram
        }
    }

    private func loadSavedHosts() {
        guard let data = UserDefaults.standard.data(forKey: hostsDefaultsKey),
              let decoded = try? JSONDecoder().decode([FleetHostConfig].self, from: data) else {
            return
        }
        hosts = decoded
        for host in hosts {
            states[host.id] = HostRuntimeState()
        }
        selectedHostID = localHost?.id
    }

    private func persistHosts() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: hostsDefaultsKey)
        }
    }

    private func loadClearedWatermarks() {
        guard let raw = UserDefaults.standard.dictionary(forKey: clearedDefaultsKey) as? [String: Int64] else {
            return
        }
        var out: [UUID: Int64] = [:]
        for (k, v) in raw {
            if let id = UUID(uuidString: k) {
                out[id] = v
            }
        }
        clearedBeforeMs = out
    }

    private func persistClearedWatermarks() {
        var raw: [String: Int64] = [:]
        for (k, v) in clearedBeforeMs {
            raw[k.uuidString] = v
        }
        UserDefaults.standard.set(raw, forKey: clearedDefaultsKey)
    }
}
