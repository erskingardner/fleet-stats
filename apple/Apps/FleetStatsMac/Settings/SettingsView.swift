import AppKit
import FleetKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var store: FleetStore
    let supervisor: LocalAgentSupervisor
    let updater: AppUpdater

    var body: some View {
        TabView {
            FleetMachinesSettingsTab(store: store)
                .tabItem { Label("Fleet", systemImage: "server.rack") }

            AlertRulesSettingsTab(store: store)
                .tabItem { Label("Alerts", systemImage: "bell.badge") }

            GeneralSettingsTab(store: store, supervisor: supervisor, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 470)
    }
}

// MARK: - Fleet Machines Tab

private struct FleetMachinesSettingsTab: View {
    @Bindable var store: FleetStore
    @State private var showingAddSheet = false
    @State private var showingInstallSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Monitored Machines")
                    .font(.headline)
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
                    HStack(spacing: 10) {
                        Circle()
                            .fill(st?.status.isOnline == true ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(host.name)
                                    .font(.system(size: 13, weight: .semibold))
                                if host.isLocal {
                                    Text("Local")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                                }
                            }
                            Text("\(host.address):\(host.port)" + (st?.snapshot.map { " · \($0.host.osVersion) (\($0.host.arch))" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !host.isLocal {
                            Button(role: .destructive) {
                                store.removeHost(host.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
        .sheet(isPresented: $showingAddSheet) {
            AddMachineSheet(store: store)
        }
        .sheet(isPresented: $showingInstallSheet) {
            InstallCommandSheet()
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
                    .frame(maxHeight: 130)
                }
            } else if !isScanning {
                Text("Enter a machine's Tailscale hostname or IP (e.g. linux-tower or 100.x.y.z) and its fleetd bearer token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Display Name", text: $name, prompt: Text("Linux Tower"))
                TextField("Tailscale Host / IP", text: $address, prompt: Text("linux-tower.tailnet.ts.net"))
                TextField("Port", text: $port)
                SecureField("Bearer Token", text: $token, prompt: Text("fls_..."))
            }
            .formStyle(.grouped)

            if let peer = selectedPeer {
                HStack(spacing: 6) {
                    Text("Need the token from \(peer.hostName)?")
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
                .disabled(address.isEmpty || token.isEmpty || isTesting)

                Spacer()

                Button("Cancel") { dismiss() }
                Button("Add Machine") {
                    let finalPort = Int(port) ?? 9470
                    let finalName = name.isEmpty ? address : name
                    _ = store.addHost(name: finalName, address: address, port: finalPort, token: token)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(address.isEmpty || token.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            scanTailnet()
        }
    }

    private func peerRow(_ peer: DiscoveredTailscalePeer, alreadyAdded: Bool) -> some View {
        let isSelected = selectedPeer?.id == peer.id
        return Button {
            selectedPeer = peer
            name = peer.hostName
            address = peer.preferredAddress
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
                    Text("\(peer.ipv4) · \(peer.os)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if alreadyAdded {
                    Text("Added")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                } else if peer.fleetdDetected {
                    Text("fleetd detected")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
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
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
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
                let health = try await store.testConnection(address: address, port: p, token: token)
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
    @State private var generatedToken = KeychainStore.generateRandomToken()
    @State private var copied = false

    private var command: String {
        let baseURL = "https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh"
        if platform == 0 {
            return "curl -fsSL \(baseURL) | sudo sh -s -- --token \"\(generatedToken)\""
        } else {
            return "curl -fsSL \(baseURL) | sh -s -- --token \"\(generatedToken)\""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Install fleetd on a Remote Machine")
                    .font(.headline)
                Spacer()
                Button("Regenerate Token") {
                    generatedToken = KeychainStore.generateRandomToken()
                }
                .font(.caption)
            }

            Picker("Platform", selection: $platform) {
                Text("Linux (systemd)").tag(0)
                Text("macOS (Mac Mini / iMac)").tag(1)
            }
            .pickerStyle(.segmented)

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

            TextEditor(text: .constant(command))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 110)
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

// MARK: - Alert Rules & Webhooks Tab

private struct AlertRulesSettingsTab: View {
    @Bindable var store: FleetStore
    @State private var targetHostID: UUID?
    @State private var config = AlertConfig.defaults
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
                Section("Thresholds (Sustained)") {
                    HStack {
                        Text("CPU Warn / Crit (%)")
                        Spacer()
                        TextField("", value: $config.cpuWarnPct, format: .number).frame(width: 52)
                        Text("/")
                        TextField("", value: $config.cpuCritPct, format: .number).frame(width: 52)
                        Text("for")
                        TextField("", value: $config.cpuDurationSecs, format: .number).frame(width: 52)
                        Text("s")
                    }
                    HStack {
                        Text("RAM Warn / Crit (%)")
                        Spacer()
                        TextField("", value: $config.memWarnPct, format: .number).frame(width: 52)
                        Text("/")
                        TextField("", value: $config.memCritPct, format: .number).frame(width: 52)
                        Text("for")
                        TextField("", value: $config.memDurationSecs, format: .number).frame(width: 52)
                        Text("s")
                    }
                    HStack {
                        Text("Disk Warn / Crit (%)")
                        Spacer()
                        TextField("", value: $config.diskWarnPct, format: .number).frame(width: 52)
                        Text("/")
                        TextField("", value: $config.diskCritPct, format: .number).frame(width: 52)
                    }
                    Toggle("Immediate alert on Linux OOM killer events", isOn: $config.oomAlertsEnabled)
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
                statusMessage = nil
            } else {
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

                if exposeLocalAgent, let localID = store.localHost?.id,
                   let token = KeychainStore.loadToken(for: localID) {
                    HStack {
                        Text("Local Agent Port")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(supervisor.activePort)")
                            .font(.system(size: 11, design: .monospaced))
                    }
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
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onAppear {
            exposeLocalAgent = supervisor.exposeOnNetwork
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
