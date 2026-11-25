import AppKit
import FleetKit
import ServiceManagement
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case fleet
    case alerts
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fleet: "Fleet"
        case .alerts: "Alerts"
        case .general: "General"
        }
    }

    var subtitle: String {
        switch self {
        case .fleet: "Manage your local Mac and remote Tailscale machines"
        case .alerts: "Configure sustained thresholds, OOM alerts, and webhooks"
        case .general: "Updates, menu bar display, startup, and sharing"
        }
    }

    var icon: String {
        switch self {
        case .fleet: "server.rack"
        case .alerts: "bell.badge.fill"
        case .general: "gearshape.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .fleet: .blue
        case .alerts: .orange
        case .general: .gray
        }
    }
}

struct SettingsView: View {
    @Bindable var store: FleetStore
    let supervisor: LocalAgentSupervisor
    let updater: AppUpdater
    @State var selectedPane: SettingsPane = .fleet

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPane
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 500, idealHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Leave comfortable space for transparent titlebar traffic lights
            Spacer().frame(height: 28)

            HStack(spacing: 8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("FleetStats")
                        .font(.system(size: 13, weight: .semibold))
                    Text("v\(updater.currentVersionString)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            ForEach(SettingsPane.allCases) { pane in
                sidebarRow(pane)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 196)
        .background(.ultraThinMaterial)
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        let isSelected = selectedPane == pane
        return Button {
            selectedPane = pane
        } label: {
            HStack(spacing: 9) {
                Image(systemName: pane.icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(pane.badgeColor.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(pane.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))

                Spacer()

                if pane == .fleet {
                    Text("\(store.hosts.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                } else if pane == .general && updater.availableRelease != nil {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedPane.title)
                    .font(.system(size: 20, weight: .semibold))
                Text(selectedPane.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 14)

            Divider()

            Group {
                switch selectedPane {
                case .fleet:
                    FleetMachinesSettingsTab(store: store)
                case .alerts:
                    AlertRulesSettingsTab(store: store)
                case .general:
                    GeneralSettingsTab(store: store, supervisor: supervisor, updater: updater)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Fleet Machines Tab

private struct FleetMachinesSettingsTab: View {
    @Bindable var store: FleetStore
    @State private var showingAddSheet = false
    @State private var showingInstallSheet = false
    @State private var editingHostID: UUID?

    var body: some View {
        Group {
            if let hostID = editingHostID,
               store.hosts.contains(where: { $0.id == hostID }) {
                MachineDetailSettingsView(
                    store: store,
                    hostID: hostID,
                    onBack: { editingHostID = nil }
                )
            } else {
                machinesListView
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddMachineSheet(store: store)
        }
        .sheet(isPresented: $showingInstallSheet) {
            InstallCommandSheet()
        }
    }

    private var machinesListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Monitored Machines")
                        .font(.headline)
                    Text("Click any machine to rename it, edit connection settings, or tune alert thresholds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Agent Install Script") {
                    showingInstallSheet = true
                }
                Button("+ Add Machine") {
                    showingAddSheet = true
                }
                .buttonStyle(.borderedProminent)
            }

            List {
                ForEach(store.hosts) { host in
                    let st = store.states[host.id]
                    Button {
                        editingHostID = host.id
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(statusColor(for: host, state: st))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(host.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    if host.isLocal {
                                        Text("Local")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                                    }
                                    if !host.enabled {
                                        Text("Paused")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15), in: Capsule())
                                    }
                                }
                                Text(machineSubtitle(host: host, state: st))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let snap = st?.snapshot, st?.status.isOnline == true {
                                HStack(spacing: 8) {
                                    Text(String(format: "CPU %.0f%%", snap.cpu.totalPct))
                                    Text(String(format: "RAM %.0f%%", snap.memory.usedPct))
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
    }

    private func statusColor(for host: FleetHostConfig, state: HostRuntimeState?) -> Color {
        if !host.enabled { return .gray }
        switch state?.status {
        case .online: return .green
        case .connecting: return .orange
        case .unauthorized: return .orange
        case .offline, .none: return .red
        }
    }

    private func machineSubtitle(host: FleetHostConfig, state: HostRuntimeState?) -> String {
        let base = "\(host.address):\(host.port)"
        if let snap = state?.snapshot {
            return "\(base) · \(snap.host.osVersion) (\(snap.host.arch))"
        }
        switch state?.status {
        case .unauthorized:
            return "\(base) · Token required (click to configure)"
        case .offline(let reason):
            return "\(base) · \(reason)"
        case .connecting:
            return "\(base) · Connecting…"
        default:
            return base
        }
    }
}

private struct MachineDetailSettingsView: View {
    @Bindable var store: FleetStore
    let hostID: UUID
    let onBack: () -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var port = "9470"
    @State private var enabled = true
    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var clearStoredToken = false

    @State private var alertConfig = AlertConfig.defaults
    @State private var alertConfigLoaded = false
    @State private var newWebhookKind: WebhookKind = .ntfy
    @State private var newWebhookURL = ""
    @State private var newWebhookToken = ""

    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSucceeded = false

    private var host: FleetHostConfig? {
        store.hosts.first(where: { $0.id == hostID })
    }

    private var hostState: HostRuntimeState? {
        store.states[hostID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Navigation header bar
            HStack(spacing: 10) {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Fleet")
                    }
                }
                .buttonStyle(.borderless)

                Divider()
                    .frame(height: 14)

                Circle()
                    .fill(hostState?.status.isOnline == true ? Color.green : Color.orange)
                    .frame(width: 7.5, height: 7.5)

                Text(name.isEmpty ? (host?.name ?? "Machine") : name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                        .lineLimit(1)
                }

                Button(isSaving ? "Saving…" : "Save") {
                    saveAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Form {
                Section("Machine") {
                    TextField("Display Name", text: $name)

                    if let host, !host.isLocal {
                        TextField("Tailscale Host / IP", text: $address)
                        TextField("Port", text: $port)
                        Toggle("Monitor this machine", isOn: $enabled)

                        HStack(spacing: 8) {
                            SecureField(
                                "Bearer Token",
                                text: $token,
                                prompt: Text(
                                    hasStoredToken && !clearStoredToken
                                        ? "Saved in Keychain (leave blank to keep)"
                                        : "Optional — blank uses Tailscale trust"
                                )
                            )
                            if hasStoredToken && !clearStoredToken {
                                Button("Clear") {
                                    clearStoredToken = true
                                    token = ""
                                }
                                .font(.caption)
                            }
                        }

                        HStack {
                            Button(isTesting ? "Testing…" : "Test Connection") {
                                runConnectionTest()
                            }
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)

                            if let testResult {
                                HStack(spacing: 4) {
                                    Image(systemName: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(testSucceeded ? .green : .red)
                                    Text(testResult)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } else if let host {
                        LabeledContent("Local Agent") {
                            Text("127.0.0.1:\(host.port)")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text("Tailscale sharing and optional bearer token settings for this Mac are in General.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                AlertConfigFormSections(
                    config: $alertConfig,
                    newWebhookKind: $newWebhookKind,
                    newWebhookURL: $newWebhookURL,
                    newWebhookToken: $newWebhookToken,
                    agentReachable: alertConfigLoaded
                )

                if let host, !host.isLocal {
                    Section {
                        HStack {
                            Spacer()
                            Button("Remove Machine", role: .destructive) {
                                store.removeHost(host.id)
                                onBack()
                            }
                            Spacer()
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            loadMachine()
        }
    }

    private func loadMachine() {
        guard let host else { return }
        name = host.name
        address = host.address
        port = "\(host.port)"
        enabled = host.enabled
        token = ""
        let existingToken = KeychainStore.loadToken(for: host.id) ?? ""
        hasStoredToken = !existingToken.isEmpty
        clearStoredToken = false

        statusMessage = "Loading thresholds…"
        statusIsError = false
        Task {
            if let loaded = await store.loadAlertConfig(for: host.id) {
                alertConfig = loaded
                alertConfigLoaded = true
                statusMessage = nil
            } else {
                alertConfigLoaded = false
                statusMessage = "Agent offline (machine settings still editable)"
            }
        }
    }

    private func runConnectionTest() {
        isTesting = true
        testResult = nil
        let p = Int(port) ?? 9470
        let effectiveToken: String
        if clearStoredToken {
            effectiveToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectiveToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            effectiveToken = KeychainStore.loadToken(for: hostID) ?? ""
        }
        Task {
            do {
                let health = try await store.testConnection(
                    address: address.trimmingCharacters(in: .whitespaces),
                    port: p,
                    token: effectiveToken
                )
                testSucceeded = true
                testResult = "Connected to \(health.hostname) (\(health.cpuCores) cores)"
            } catch {
                testSucceeded = false
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func saveAll() {
        guard var updated = host else { return }
        isSaving = true
        statusIsError = false
        statusMessage = "Saving…"

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        updated.name = trimmedName.isEmpty ? updated.name : trimmedName
        if !updated.isLocal {
            let trimmedAddr = address.trimmingCharacters(in: .whitespaces)
            if !trimmedAddr.isEmpty {
                updated.address = trimmedAddr
            }
            if let parsedPort = Int(port), parsedPort > 0 && parsedPort <= 65535 {
                updated.port = parsedPort
            }
            updated.enabled = enabled
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if clearStoredToken && trimmedToken.isEmpty {
            store.updateHost(updated, newToken: nil, clearToken: true)
            hasStoredToken = false
            clearStoredToken = false
        } else if !trimmedToken.isEmpty {
            store.updateHost(updated, newToken: trimmedToken, clearToken: false)
            hasStoredToken = true
            clearStoredToken = false
            token = ""
        } else {
            store.updateHost(updated, newToken: nil, clearToken: false)
        }

        Task {
            if alertConfigLoaded || hostState?.status.isOnline == true {
                do {
                    try await store.saveAlertConfig(alertConfig, for: updated.id)
                    alertConfigLoaded = true
                    statusIsError = false
                    statusMessage = "Saved"
                } catch {
                    statusIsError = true
                    statusMessage = "Machine saved; thresholds failed: \(error.localizedDescription)"
                }
            } else {
                statusIsError = false
                statusMessage = "Machine saved"
            }
            isSaving = false
        }
    }
}

private struct AddMachineSheet: View {
    @Bindable var store: FleetStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var port = "9470"
    @State private var token = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var testSucceeded = false

    @State private var discoveredPeers: [DiscoveredTailscalePeer] = []
    @State private var isScanning = false
    @State private var selectedPeer: DiscoveredTailscalePeer?
    @State private var copiedSSH = false

    private var alreadyAddedAddresses: Set<String> {
        Set(store.hosts.map { $0.address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
    }

    private var showTokenHelp: Bool {
        if selectedPeer?.fleetdStatus == .requiresToken { return true }
        if let res = testResult, res.contains("401") || res.lowercased().contains("token") { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add Fleet Machine")
                    .font(.headline)
                Spacer()
                Button {
                    scanTailnet()
                } label: {
                    if isScanning {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Scanning Tailnet…")
                        }
                    } else {
                        Label("Rescan Tailscale", systemImage: "arrow.clockwise")
                    }
                }
                .font(.caption)
                .disabled(isScanning)
            }

            // Discovered Tailscale peers section
            if !discoveredPeers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DISCOVERED ON YOUR TAILNET")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(discoveredPeers) { peer in
                                let isAdded = alreadyAddedAddresses.contains(peer.preferredAddress.lowercased())
                                    || alreadyAddedAddresses.contains(peer.ipv4.lowercased())
                                    || alreadyAddedAddresses.contains(peer.hostName.lowercased())
                                peerRow(peer, alreadyAdded: isAdded)
                            }
                        }
                    }
                    .frame(maxHeight: 145)
                }
            } else if !isScanning {
                Text("Enter a machine's Tailscale hostname or IP (e.g. linux-tower or 100.x.y.z). No bearer token is needed for private Tailnet agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Display Name", text: $name, prompt: Text("Linux Tower"))
                TextField("Tailscale Host / IP", text: $address, prompt: Text("linux-tower.tailnet.ts.net"))
                TextField("Port", text: $port)
                SecureField("Bearer Token", text: $token, prompt: Text("Optional (not needed on private Tailnet)"))
            }
            .formStyle(.grouped)

            if let peer = selectedPeer, showTokenHelp {
                HStack(spacing: 6) {
                    Text("\(peer.hostName) requires a bearer token:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if copiedSSH {
                        Text("Copied!")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button("Copy SSH Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(peer.sshCopyTokenCommand, forType: .string)
                        copiedSSH = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copiedSSH = false
                        }
                    }
                    .font(.caption)
                }
            }

            if let testResult {
                HStack(spacing: 6) {
                    Image(systemName: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testSucceeded ? .green : .red)
                    Text(testResult)
                        .font(.caption)
                }
            }

            HStack {
                Button(isTesting ? "Testing…" : "Test Connection") {
                    runTest()
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)

                Spacer()

                Button("Done") { dismiss() }
                Button("Add Machine") {
                    let finalPort = Int(port) ?? 9470
                    let trimmedAddr = address.trimmingCharacters(in: .whitespaces)
                    let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedAddr : name.trimmingCharacters(in: .whitespaces)
                    _ = store.addHost(name: finalName, address: trimmedAddr, port: finalPort, token: token)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
        .onAppear {
            scanTailnet()
        }
    }

    private func peerRow(_ peer: DiscoveredTailscalePeer, alreadyAdded: Bool) -> some View {
        let isSelected = selectedPeer?.id == peer.id
        return HStack(spacing: 8) {
            Button {
                selectedPeer = peer
                name = peer.hostName
                address = peer.preferredAddress
                port = "\(peer.detectedPort)"
                testResult = nil
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(peer.isOnline ? Color.green : Color.gray.opacity(0.45))
                        .frame(width: 6.5, height: 6.5)
                    Image(systemName: peer.isLinux ? "server.rack" : "macmini")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(peer.hostName)
                            .font(.system(size: 11.5, weight: .medium))
                        let portSuffix = (peer.fleetdDetected && peer.detectedPort != 9470) ? ":\(peer.detectedPort)" : ""
                        Text("\(peer.ipv4)\(portSuffix) · \(peer.os)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(alreadyAdded)

            if alreadyAdded {
                Text("Added")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
            } else if peer.fleetdStatus == .ready {
                Button("+ Add") {
                    _ = store.addHost(
                        name: peer.hostName,
                        address: peer.preferredAddress,
                        port: peer.detectedPort,
                        token: ""
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            } else if peer.fleetdStatus == .requiresToken {
                Text("token required")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            } else if !peer.isOnline {
                Text("Offline")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
        )
        .opacity(alreadyAdded ? 0.55 : 1.0)
    }

    private func scanTailnet() {
        isScanning = true
        let targetPort = Int(port) ?? 9470
        Task {
            discoveredPeers = await TailscaleDiscovery.discoverPeers(port: targetPort)
            isScanning = false
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        let p = Int(port) ?? 9470
        Task {
            do {
                let health = try await store.testConnection(
                    address: address.trimmingCharacters(in: .whitespaces),
                    port: p,
                    token: token
                )
                testSucceeded = true
                testResult = "Connected to \(health.hostname) (\(health.osVersion), \(health.cpuCores) cores)"
                if name.isEmpty {
                    name = health.hostname
                }
            } catch {
                testSucceeded = false
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}

private struct InstallCommandSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var platform = 0 // 0 = Linux systemd, 1 = macOS launchd
    @State private var requireToken = false
    @State private var generatedToken = KeychainStore.generateRandomToken()
    @State private var copied = false

    private var command: String {
        let baseURL = "https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh"
        let shell = platform == 0 ? "sudo sh" : "sh"
        if requireToken {
            return "curl -fsSL \(baseURL) | \(shell) -s -- --token \"\(generatedToken)\""
        } else {
            return "curl -fsSL \(baseURL) | \(shell)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Install fleetd on a Remote Machine")
                    .font(.headline)
                Spacer()
                if requireToken {
                    Button("Regenerate Token") {
                        generatedToken = KeychainStore.generateRandomToken()
                    }
                    .font(.caption)
                }
            }

            Picker("Platform", selection: $platform) {
                Text("Linux (systemd)").tag(0)
                Text("macOS (Mac Mini / iMac)").tag(1)
            }
            .pickerStyle(.segmented)

            Toggle("Require bearer token (optional, for shared Tailnets)", isOn: $requireToken)
                .font(.caption)

            if requireToken {
                HStack {
                    Text("Bearer Token:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(generatedToken)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy Token") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(generatedToken, forType: .string)
                    }
                    .font(.caption)
                }
            } else {
                Text("Tailscale-only peer allowlist & anti-browser guards are enabled automatically. Once installed, the machine appears for 1-click Add in Tailscale discovery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: .constant(command))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 82)
                .border(Color.secondary.opacity(0.25))

            HStack {
                if copied {
                    Text("Copied to clipboard!")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

// MARK: - Shared Alert Thresholds & Webhooks Form Sections

private struct AlertConfigFormSections: View {
    @Binding var config: AlertConfig
    @Binding var newWebhookKind: WebhookKind
    @Binding var newWebhookURL: String
    @Binding var newWebhookToken: String
    var agentReachable: Bool = true

    var body: some View {
        Section {
            HStack {
                Text("CPU Warn / Crit (%)")
                Spacer()
                TextField("", value: $config.cpuWarnPct, format: .number).frame(width: 50)
                Text("/")
                TextField("", value: $config.cpuCritPct, format: .number).frame(width: 50)
                Text("for")
                TextField("", value: $config.cpuDurationSecs, format: .number).frame(width: 50)
                Text("s")
            }
            HStack {
                Text("RAM Warn / Crit (%)")
                Spacer()
                TextField("", value: $config.memWarnPct, format: .number).frame(width: 50)
                Text("/")
                TextField("", value: $config.memCritPct, format: .number).frame(width: 50)
                Text("for")
                TextField("", value: $config.memDurationSecs, format: .number).frame(width: 50)
                Text("s")
            }
            HStack {
                Text("Disk Warn / Crit (%)")
                Spacer()
                TextField("", value: $config.diskWarnPct, format: .number).frame(width: 50)
                Text("/")
                TextField("", value: $config.diskCritPct, format: .number).frame(width: 50)
            }
            HStack {
                Text("Alert Cooldown")
                Spacer()
                TextField("", value: $config.cooldownSecs, format: .number).frame(width: 60)
                Text("seconds")
                    .foregroundStyle(.secondary)
            }
            Toggle("Immediate alert on Linux OOM killer events", isOn: $config.oomAlertsEnabled)

            HStack {
                if !agentReachable {
                    Text("Agent offline — thresholds will sync when reachable.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Reset Defaults") {
                    let savedWebhooks = config.webhooks
                    config = AlertConfig.defaults
                    config.webhooks = savedWebhooks
                }
                .font(.caption)
            }
        } header: {
            Text("Warning & Critical Thresholds")
        }

        Section("Agent Webhooks (fires even when MacBook sleeps)") {
            ForEach(config.webhooks.indices, id: \.self) { idx in
                HStack {
                    Toggle("", isOn: $config.webhooks[idx].enabled).labelsHidden()
                    Text(config.webhooks[idx].kind.displayName)
                        .font(.caption.bold())
                    Text(config.webhooks[idx].url)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) {
                        config.webhooks.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 6) {
                Picker("", selection: $newWebhookKind) {
                    ForEach(WebhookKind.allCases) { k in
                        Text(k.displayName).tag(k)
                    }
                }
                .labelsHidden()
                .frame(width: 100)

                TextField("Webhook URL (e.g. https://ntfy.sh/my-fleet)", text: $newWebhookURL)
                Button("Add") {
                    guard !newWebhookURL.isEmpty else { return }
                    config.webhooks.append(WebhookTarget(
                        name: newWebhookKind.displayName,
                        kind: newWebhookKind,
                        url: newWebhookURL,
                        tokenOrKey: newWebhookToken.isEmpty ? nil : newWebhookToken
                    ))
                    newWebhookURL = ""
                    newWebhookToken = ""
                }
                .disabled(newWebhookURL.isEmpty)
            }
        }
    }
}

// MARK: - Alert Rules & Webhooks Tab

private struct AlertRulesSettingsTab: View {
    @Bindable var store: FleetStore
    @State private var targetHostID: UUID?
    @State private var config = AlertConfig.defaults
    @State private var agentReachable = true
    @State private var statusMessage: String?
    @State private var newWebhookKind: WebhookKind = .ntfy
    @State private var newWebhookURL = ""
    @State private var newWebhookToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Machine", selection: $targetHostID) {
                    ForEach(store.hosts) { host in
                        Text(host.name).tag(Optional(host.id))
                    }
                }
                .frame(width: 240)
                Spacer()
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Save to Agent") {
                    saveConfig()
                }
                .buttonStyle(.borderedProminent)
            }

            Form {
                AlertConfigFormSections(
                    config: $config,
                    newWebhookKind: $newWebhookKind,
                    newWebhookURL: $newWebhookURL,
                    newWebhookToken: $newWebhookToken,
                    agentReachable: agentReachable
                )
            }
            .formStyle(.grouped)
        }
        .padding(16)
        .onAppear {
            targetHostID = store.selectedHost?.id ?? store.localHost?.id
            loadConfig()
        }
        .onChange(of: targetHostID) { _, _ in
            loadConfig()
        }
    }

    private func loadConfig() {
        guard let id = targetHostID else { return }
        statusMessage = "Loading…"
        Task {
            if let loaded = await store.loadAlertConfig(for: id) {
                config = loaded
                agentReachable = true
                statusMessage = nil
            } else {
                agentReachable = false
                statusMessage = "Host offline"
            }
        }
    }

    private func saveConfig() {
        guard let id = targetHostID else { return }
        statusMessage = "Saving…"
        Task {
            do {
                try await store.saveAlertConfig(config, for: id)
                agentReachable = true
                statusMessage = "Saved"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - General Settings Tab

private struct GeneralSettingsTab: View {
    let store: FleetStore
    let supervisor: LocalAgentSupervisor
    @Bindable var updater: AppUpdater

    @AppStorage("menubar.showCPU") private var showCPU = true
    @AppStorage("menubar.showRAM") private var showRAM = true
    @AppStorage("menubar.showSSD") private var showSSD = true
    @AppStorage("menubar.showNetwork") private var showNetwork = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var exposeLocalAgent = false
    @State private var requireLocalToken = false

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updater.autoCheckEnabled)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current version: v\(updater.currentVersionString)")
                            .font(.system(size: 12, weight: .medium))
                        updateStatusSubtitle
                    }
                    Spacer()
                    updateActionButton
                }

                if case .downloading(let progress) = updater.phase {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }

            Section("Menu Bar Strip (Local Mac)") {
                Toggle("Show CPU %", isOn: $showCPU)
                Toggle("Show RAM %", isOn: $showRAM)
                Toggle("Show SSD %", isOn: $showSSD)
                Toggle("Show Network Up / Down", isOn: $showNetwork)
            }

            Section("Startup & Sharing") {
                Toggle("Launch FleetStats at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

                Toggle("Allow Tailscale peers & future iOS app to monitor this Mac", isOn: $exposeLocalAgent)
                    .onChange(of: exposeLocalAgent) { _, enabled in
                        supervisor.exposeOnNetwork = enabled
                    }

                if exposeLocalAgent {
                    HStack {
                        Text("Local Agent Port")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(supervisor.activePort)")
                            .font(.system(size: 11, design: .monospaced))
                    }

                    Toggle("Require bearer token for remote peers", isOn: $requireLocalToken)
                        .onChange(of: requireLocalToken) { _, enabled in
                            supervisor.requireToken = enabled
                        }

                    if requireLocalToken, let localID = store.localHost?.id {
                        let token = supervisor.localToken(for: localID)
                        HStack {
                            Text("Local Agent Token")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(token)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(token, forType: .string)
                            }
                            .font(.caption)
                        }
                    } else {
                        Text("Tailscale-only peer allowlist & anti-browser guards are active. No bearer token is needed on your private Tailnet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onAppear {
            exposeLocalAgent = supervisor.exposeOnNetwork
            requireLocalToken = supervisor.requireToken
        }
    }

    @ViewBuilder
    private var updateStatusSubtitle: some View {
        switch updater.phase {
        case .idle:
            if let last = updater.lastCheckedAt {
                Text("Last checked \(last, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Checks GitHub Releases (SHA-256 + Developer ID verified)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .checking:
            Text("Checking GitHub Releases…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .upToDate:
            Text("You're up to date.")
                .font(.caption)
                .foregroundStyle(.green)
        case .available(let rel):
            Text("FleetStats \(rel.tagName) is available to install.")
                .font(.caption)
                .foregroundStyle(.blue)
        case .downloading(let pct):
            Text("Downloading update (\(Int(pct * 100))%)…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .verifying:
            Text("Verifying SHA-256 checksum & Apple signature…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .installing:
            Text("Installing update and restarting…")
                .font(.caption)
                .foregroundStyle(.blue)
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var updateActionButton: some View {
        switch updater.phase {
        case .available:
            HStack(spacing: 6) {
                Button("Check Again") {
                    Task { await updater.checkForUpdates(userInitiated: true) }
                }
                Button("Update & Restart") {
                    Task { await updater.installAvailableUpdate() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .checking, .downloading, .verifying, .installing:
            ProgressView()
                .controlSize(.small)
        default:
            Button("Check for Updates") {
                Task { await updater.checkForUpdates(userInitiated: true) }
            }
        }
    }
}
