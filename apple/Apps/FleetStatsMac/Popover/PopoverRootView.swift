import FleetKit
import SwiftUI

struct PopoverRootView: View {
    @Bindable var store: FleetStore
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    private var selectedHost: FleetHostConfig? { store.selectedHost }
    private var selectedState: HostRuntimeState? { store.selectedState }

    var body: some View {
        VStack(spacing: 0) {
            fleetHeaderBar
            Divider()

            if store.showingEvents {
                EventsView(store: store) { hostID, tab in
                    store.selectedHostID = hostID
                    store.selectedTab = tab
                    store.selectedWindow = .oneDay
                    store.showingEvents = false
                    Task {
                        await store.refreshHistory(for: hostID, window: .oneDay)
                    }
                }
            } else {
                tabSelectorBar
                Divider()
                contentBody
            }

            Divider()
            footerBar
        }
        .frame(width: 430, height: 540)
        .background(keyboardShortcuts)
        .onChange(of: store.selectedHostID) { _, newID in
            guard let id = newID else { return }
            Task {
                await store.refreshHistory(for: id, window: store.selectedWindow)
                await store.refreshEvents(for: id)
            }
        }
        .onChange(of: store.selectedWindow) { _, newWindow in
            guard let id = selectedHost?.id else { return }
            Task {
                await store.refreshHistory(for: id, window: newWindow)
            }
        }
    }

    private var fleetHeaderBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.hosts) { host in
                        hostPill(host)
                    }
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 4)

            Button {
                store.showingEvents.toggle()
                if store.showingEvents {
                    Task {
                        for host in store.hosts {
                            await store.refreshEvents(for: host.id)
                        }
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: store.showingEvents ? "bell.fill" : "bell")
                        .font(.system(size: 13))
                        .foregroundStyle(store.showingEvents ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                    if store.totalActiveAlertCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Alerts & OOM Events")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func hostPill(_ host: FleetHostConfig) -> some View {
        let isSelected = selectedHost?.id == host.id && !store.showingEvents
        let state = store.states[host.id]
        let dotColor = statusColor(for: state)
        let osIcon: String = {
            if host.isLocal { return "laptopcomputer" }
            switch state?.snapshot?.host.os {
            case .linux: return "server.rack"
            case .macos: return "macmini"
            case nil: return "desktopcomputer"
            }
        }()

        return Button {
            store.showingEvents = false
            store.selectedHostID = host.id
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6.5, height: 6.5)
                Image(systemName: osIcon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(host.name)
                    .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var tabSelectorBar: some View {
        HStack(spacing: 6) {
            ForEach(MetricTab.allCases) { tab in
                let isSelected = store.selectedTab == tab
                Button {
                    store.selectedTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 11))
                        Text(tab.title)
                            .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.primary.opacity(0.1) : .clear)
                    )
                    .foregroundStyle(isSelected ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var contentBody: some View {
        if let state = selectedState, let snap = state.snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if case .offline(let reason) = state.status {
                        alertBanner(
                            severity: .critical,
                            title: "Host Offline — showing last known stats",
                            detail: reason
                        )
                    } else if case .unauthorized = state.status {
                        alertBanner(
                            severity: .critical,
                            title: "Authentication Failed",
                            detail: "Check the bearer token for this host in Settings."
                        )
                    }

                    if let hostID = selectedHost?.id {
                        ForEach(store.visibleActiveAlerts(for: hostID)) { alert in
                            alertBanner(
                                severity: alert.severity,
                                title: alert.title,
                                detail: alert.detail,
                                onDismiss: {
                                    store.dismissActiveAlert(alert, for: hostID)
                                }
                            )
                        }
                    }

                    switch store.selectedTab {
                    case .cpu:
                        CPUDetailView(
                            snapshot: snap,
                            points: state.points(for: store.selectedWindow),
                            window: $store.selectedWindow
                        )
                    case .ram:
                        RAMDetailView(
                            snapshot: snap,
                            points: state.points(for: store.selectedWindow),
                            window: $store.selectedWindow
                        )
                    case .ssd:
                        SSDDetailView(
                            snapshot: snap,
                            points: state.points(for: store.selectedWindow),
                            window: $store.selectedWindow
                        )
                    case .network:
                        NetworkDetailView(
                            snapshot: snap,
                            points: state.points(for: store.selectedWindow),
                            window: $store.selectedWindow
                        )
                    }
                }
                .padding(12)
            }
        } else {
            emptyOrConnectingState
        }
    }

    private var emptyOrConnectingState: some View {
        VStack(spacing: 10) {
            Spacer()
            if case .offline(let msg) = selectedState?.status {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                Text("Unable to reach \(selectedHost?.name ?? "host")")
                    .font(.headline)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else if case .unauthorized = selectedState?.status {
                Image(systemName: "lock.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text("Invalid Bearer Token")
                    .font(.headline)
                Button("Open Settings", action: onOpenSettings)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting to \(selectedHost?.name ?? "agent")…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func alertBanner(
        severity: AlertSeverity,
        title: String,
        detail: String,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        let color: Color = severity == .critical ? .red : .orange
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
                .font(.system(size: 13))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(color)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Dismiss alert")
            }
        }
        .padding(8)
        .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 1)
        )
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            if let info = selectedState?.snapshot?.host {
                Text(info.osVersion)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Up \(ByteFormatters.uptime(info.uptimeSecs))")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if let host = selectedHost {
                Text("\(host.address):\(host.port)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.hosts.count == 1 {
                Button("+ Add Machine", action: onOpenSettings)
                    .font(.system(size: 10.5, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("") { store.selectedTab = .cpu }.keyboardShortcut("1", modifiers: .command)
            Button("") { store.selectedTab = .ram }.keyboardShortcut("2", modifiers: .command)
            Button("") { store.selectedTab = .ssd }.keyboardShortcut("3", modifiers: .command)
            Button("") { store.selectedTab = .network }.keyboardShortcut("4", modifiers: .command)
            Button("") { store.selectNextHost(delta: -1) }.keyboardShortcut("[", modifiers: .command)
            Button("") { store.selectNextHost(delta: 1) }.keyboardShortcut("]", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func statusColor(for state: HostRuntimeState?) -> Color {
        guard let state else { return .gray }
        switch state.status {
        case .connecting: return .gray
        case .offline, .unauthorized: return .red
        case .online:
            switch state.highestAlertSeverity {
            case .critical: return .red
            case .warning: return .orange
            default: return .green
            }
        }
    }
}
