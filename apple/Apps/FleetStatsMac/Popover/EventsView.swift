import FleetKit
import SwiftUI

struct EventsView: View {
    let store: FleetStore
    let onInspectIncident: (UUID, MetricTab) -> Void

    @State private var filterToSelectedHost = false
    @State private var showCleared = false

    private var filteredIncidents: [FleetIncidentItem] {
        let all = store.incidents(includeCleared: showCleared)
        if filterToSelectedHost, let id = store.selectedHost?.id {
            return all.filter { $0.hostId == id }
        }
        return all
    }

    private var hasUnclearableItems: Bool {
        !store.incidents(includeCleared: false).isEmpty || store.totalActiveAlertCount > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Alerts & Forensics")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("", selection: $filterToSelectedHost) {
                    Text("All").tag(false)
                    Text(store.selectedHost?.name ?? "Host").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)

                if hasUnclearableItems {
                    Button {
                        store.clearAlerts(for: filterToSelectedHost ? store.selectedHost?.id : nil)
                    } label: {
                        Label("Clear", systemImage: "checkmark.circle")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Mark all alerts as read and clear them")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if filteredIncidents.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                    Text("All Clear Across the Fleet")
                        .font(.headline)
                    Text("OOM kills, sustained pressure alerts, and unexpected reboots will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    if !showCleared && !store.incidents(includeCleared: true).isEmpty {
                        Button("Show Cleared History") {
                            showCleared = true
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                        .padding(.top, 4)
                    }
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredIncidents) { item in
                            incidentRow(item)
                        }
                    }
                    .padding(12)
                }
                if showCleared {
                    Divider()
                    HStack {
                        Text("Showing cleared alert history")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Hide Cleared") {
                            showCleared = false
                        }
                        .font(.caption2)
                        .buttonStyle(.link)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private func incidentRow(_ item: FleetIncidentItem) -> some View {
        let ev = item.event
        let color: Color = switch ev.severity {
        case .critical: .red
        case .warning: .orange
        case .info: .green
        }
        let icon: String = switch ev.kind {
        case .oomKill: "flame.fill"
        case .unexpectedReboot: "bolt.trianglebadge.exclamationmark.fill"
        case .alertTriggered: "exclamationmark.triangle.fill"
        case .alertResolved: "checkmark.circle.fill"
        }

        return Button {
            let tab: MetricTab = switch ev.metric {
            case "cpu": .cpu
            case "disk": .ssd
            case "network": .network
            default: .ram
            }
            onInspectIncident(item.hostId, tab)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(color)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.hostName)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                        Text(ev.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(ev.date, style: .relative)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    Text(ev.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(color.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
