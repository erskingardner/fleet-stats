import AppKit
import FleetKit
import SwiftUI

// MARK: - Window Picker

struct HistoryWindowPicker: View {
    @Binding var selection: HistoryWindow

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryWindow.allCases) { w in
                Button {
                    selection = w
                } label: {
                    Text(w.label)
                        .font(.system(size: 10, weight: selection == w ? .semibold : .regular))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selection == w ? Color.primary.opacity(0.12) : .clear)
                        )
                        .foregroundStyle(selection == w ? .primary : .secondary)
                        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - CPU Tab

struct CPUDetailView: View {
    let snapshot: HostSnapshot
    let points: [HistoryPoint]
    @Binding var window: HistoryWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(ByteFormatters.percent(snapshot.cpu.totalPct))
                    .font(.system(size: 28, weight: .regular))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.host.cpuModel)
                        .font(.system(size: 11, weight: .regular))
                        .lineLimit(1)
                    Text("User \(ByteFormatters.percent(snapshot.cpu.userPct)) · Sys \(ByteFormatters.percent(snapshot.cpu.systemPct))" + (snapshot.cpu.iowaitPct >= 0.5 ? " · IO \(ByteFormatters.percent(snapshot.cpu.iowaitPct))" : ""))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HistoryWindowPicker(selection: $window)
            }

            MetricSparkline(points: points, value: \.cpuPct, tint: .blue)

            // Load averages
            HStack {
                Text("Load Average")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if snapshot.cpu.loadAvg.count >= 3 {
                    HStack(spacing: 10) {
                        loadPill("1m", snapshot.cpu.loadAvg[0])
                        loadPill("5m", snapshot.cpu.loadAvg[1])
                        loadPill("15m", snapshot.cpu.loadAvg[2])
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            // Per-core bars
            if !snapshot.cpu.cores.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Per Core", trailing: "\(snapshot.cpu.cores.count) logical cores")
                    CoreUsageGrid(cores: snapshot.cpu.cores)
                }
            }

            // Top processes
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(title: "Top CPU Processes")
                if snapshot.cpu.topProcesses.isEmpty {
                    Text("Collecting process samples…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.cpu.topProcesses.prefix(8)) { proc in
                        HStack(spacing: 8) {
                            Text(proc.name)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteFormatters.bytes(proc.memoryBytes))
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .trailing)
                            Text(String(format: "%.1f%%", proc.cpuPct))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func loadPill(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(String(format: "%.2f", value))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
    }
}

// MARK: - RAM Tab

struct RAMDetailView: View {
    let snapshot: HostSnapshot
    let points: [HistoryPoint]
    @Binding var window: HistoryWindow

    private var mem: MemoryMetrics { snapshot.memory }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(ByteFormatters.percent(mem.usedPct))
                    .font(.system(size: 28, weight: .regular))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ByteFormatters.bytes(mem.usedBytes)) / \(ByteFormatters.bytes(mem.totalBytes))")
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                    PressureBadge(level: mem.pressureLevel, pct: mem.pressurePct)
                }
                Spacer()
                HistoryWindowPicker(selection: $window)
            }

            if let some10 = mem.psiSomeAvg10, let full10 = mem.psiFullAvg10 {
                HStack(spacing: 12) {
                    Text("Linux PSI (10s)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "some %.1f%%", some10))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(some10 >= 15 ? .orange : .secondary)
                    Text(String(format: "full %.1f%%", full10))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(full10 >= 10 ? .red : .secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                MemoryBreakdownBar(memory: mem)
                let cols = [GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, spacing: 5) {
                    breakdownRow("App", mem.appBytes, .blue)
                    breakdownRow(snapshot.host.os == .linux ? "Kernel / Slab" : "Wired", mem.wiredBytes, .orange)
                    breakdownRow("Compressed", mem.compressedBytes, .purple)
                    breakdownRow("Cached", mem.cachedBytes, .teal)
                    breakdownRow("Free", mem.freeBytes, .secondary.opacity(0.45))
                    breakdownRow(
                        "Swap",
                        mem.swapUsedBytes,
                        mem.swapUsedBytes > 0 ? .red.opacity(0.8) : .secondary.opacity(0.4),
                        subtitle: mem.swapTotalBytes > 0 ? "/ \(ByteFormatters.bytes(mem.swapTotalBytes))" : nil
                    )
                }
            }

            MetricSparkline(
                points: points,
                value: \.memUsedPct,
                tint: mem.pressureLevel == .critical ? .red : (mem.pressureLevel == .warn ? .orange : .purple)
            )

            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(title: "Top Memory Processes")
                ForEach(mem.topProcesses.prefix(8)) { proc in
                    HStack(spacing: 8) {
                        Text(proc.name)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let oom = proc.oomScore, oom >= 100 {
                            Text("OOM \(oom)")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(oom >= 500 ? .red : .orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background((oom >= 500 ? Color.red : Color.orange).opacity(0.14), in: Capsule())
                        }
                        Text(ByteFormatters.bytes(proc.memoryBytes))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .frame(width: 68, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func breakdownRow(_ label: String, _ bytes: UInt64, _ color: Color, subtitle: String? = nil) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 2) {
                Text(ByteFormatters.bytes(bytes))
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - SSD Tab

struct SSDDetailView: View {
    let snapshot: HostSnapshot
    let points: [HistoryPoint]
    @Binding var window: HistoryWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ByteFormatters.percent(snapshot.disks.primaryUsedPct))
                        .font(.system(size: 28, weight: .regular))
                        .monospacedDigit()
                    HStack(spacing: 10) {
                        Label(ByteFormatters.rate(snapshot.disks.totalReadBps), systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        Label(ByteFormatters.rate(snapshot.disks.totalWriteBps), systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.system(size: 10.5, weight: .regular))
                    .monospacedDigit()
                }
                Spacer()
                HistoryWindowPicker(selection: $window)
            }

            DualThroughputChart(
                points: points,
                primary: \.diskWriteBps,
                secondary: \.diskReadBps,
                primaryColor: .orange,
                secondaryColor: .blue
            )

            // Mounted Volumes (Internal + External)
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Disks & Drives", trailing: "\(snapshot.disks.volumes.count) mounted")
                ForEach(snapshot.disks.volumes) { vol in
                    volumeCard(vol)
                }
            }

            // Top Disk I/O Processes
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(title: "Top Disk I/O Processes")
                if snapshot.disks.topProcesses.isEmpty {
                    Text("No active disk I/O right now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.disks.topProcesses.prefix(8)) { proc in
                        HStack(spacing: 8) {
                            Text(proc.name)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("R \(ByteFormatters.compactMenuRate(proc.readBps))")
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.blue)
                                .frame(width: 68, alignment: .trailing)
                            Text("W \(ByteFormatters.compactMenuRate(proc.writeBps))")
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                                .frame(width: 68, alignment: .trailing)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func volumeCard(_ vol: DiskVolume) -> some View {
        let barColor: Color = vol.usedPct >= 93 ? .red : (vol.usedPct >= 85 ? .orange : .blue)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: vol.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(vol.isExternal ? .teal : .secondary)
                Text(vol.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if vol.isExternal {
                    Text("External")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.teal.opacity(0.14), in: Capsule())
                }
                Spacer()
                Text(ByteFormatters.percent(vol.usedPct))
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(vol.usedPct >= 85 ? barColor : .primary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.16))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: max(2, geo.size.width * min(1, vol.usedPct / 100.0)))
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(ByteFormatters.diskBytes(vol.usedBytes)) / \(ByteFormatters.diskBytes(vol.totalBytes)) (\(ByteFormatters.diskBytes(vol.freeBytes)) free)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if vol.readBps > 0 || vol.writeBps > 0 {
                    Text("R \(ByteFormatters.compactMenuRate(vol.readBps)) · W \(ByteFormatters.compactMenuRate(vol.writeBps))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Network Tab

struct NetworkDetailView: View {
    let snapshot: HostSnapshot
    let points: [HistoryPoint]
    @Binding var window: HistoryWindow
    @State private var copiedAddress: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(red: 1.0, green: 0.27, blue: 0.23))
                                .frame(width: 7, height: 7)
                            Text("UPLOAD")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(ByteFormatters.rate(snapshot.network.uploadBps))
                            .font(.system(size: 18, weight: .regular))
                            .monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(red: 0.12, green: 0.58, blue: 1.0))
                                .frame(width: 7, height: 7)
                            Text("DOWNLOAD")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(ByteFormatters.rate(snapshot.network.downloadBps))
                            .font(.system(size: 18, weight: .regular))
                            .monospacedDigit()
                    }
                }
                Spacer()
                HistoryWindowPicker(selection: $window)
            }

            DualThroughputChart(
                points: points,
                primary: \.netUpBps,
                secondary: \.netDownBps,
                primaryColor: Color(red: 1.0, green: 0.27, blue: 0.23),
                secondaryColor: Color(red: 0.12, green: 0.58, blue: 1.0)
            )

            // Interfaces & IP Addresses
            VStack(alignment: .leading, spacing: 7) {
                SectionHeader(title: "Interfaces & Addresses")
                ForEach(snapshot.network.interfaces) { iface in
                    interfaceCard(iface)
                }
            }

            // Top Network Processes
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(title: "Top Network Processes")
                if snapshot.network.topProcesses.isEmpty {
                    Text("No active network traffic detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.network.topProcesses.prefix(8)) { proc in
                        HStack(spacing: 8) {
                            Text(proc.name)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("↑ \(ByteFormatters.compactMenuRate(proc.uploadBps))")
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(Color(red: 1.0, green: 0.27, blue: 0.23))
                                .frame(width: 70, alignment: .trailing)
                            Text("↓ \(ByteFormatters.compactMenuRate(proc.downloadBps))")
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Color(red: 0.12, green: 0.58, blue: 1.0))
                                .frame(width: 70, alignment: .trailing)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func interfaceCard(_ iface: NetworkInterface) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(iface.isUp ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 6.5, height: 6.5)
                Text(iface.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                Text(iface.name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("↑ \(ByteFormatters.compactMenuRate(iface.uploadBps))  ↓ \(ByteFormatters.compactMenuRate(iface.downloadBps))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            let allIPs = iface.ipv4 + iface.ipv6
            if !allIPs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allIPs, id: \.self) { ip in
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ip, forType: .string)
                            copiedAddress = ip
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                if copiedAddress == ip { copiedAddress = nil }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(ip)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if copiedAddress == ip {
                                    Text("Copied")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 12)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
