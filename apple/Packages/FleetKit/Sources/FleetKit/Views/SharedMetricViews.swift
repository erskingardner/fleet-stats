import Charts
import SwiftUI

public struct MetricSparkline: View {
    public let points: [HistoryPoint]
    public let valueKeyPath: KeyPath<HistoryPoint, Double>
    public let tint: Color
    public var maxY: Double = 100

    public init(
        points: [HistoryPoint],
        value: KeyPath<HistoryPoint, Double>,
        tint: Color,
        maxY: Double = 100
    ) {
        self.points = points
        self.valueKeyPath = value
        self.tint = tint
        self.maxY = maxY
    }

    public var body: some View {
        Chart(points) { pt in
            let v = pt[keyPath: valueKeyPath]
            AreaMark(
                x: .value("Time", pt.date),
                yStart: .value("Base", 0),
                yEnd: .value("Value", v)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(
                LinearGradient(
                    colors: [tint.opacity(0.32), tint.opacity(0.03)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Time", pt.date),
                y: .value("Value", v)
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.75))
            .foregroundStyle(tint)
        }
        .chartYScale(domain: 0...maxY)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, maxY / 2, maxY]) { val in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(Color.secondary.opacity(0.22))
                AxisValueLabel {
                    if let d = val.as(Double.self) {
                        Text("\(Int(d))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 68)
    }
}

public struct DualThroughputChart: View {
    public let points: [HistoryPoint]
    public let primaryValue: KeyPath<HistoryPoint, UInt64>
    public let secondaryValue: KeyPath<HistoryPoint, UInt64>
    public let primaryColor: Color
    public let secondaryColor: Color

    public init(
        points: [HistoryPoint],
        primary: KeyPath<HistoryPoint, UInt64>,
        secondary: KeyPath<HistoryPoint, UInt64>,
        primaryColor: Color,
        secondaryColor: Color
    ) {
        self.points = points
        self.primaryValue = primary
        self.secondaryValue = secondary
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
    }

    private var maxRate: Double {
        let maxVal = points.reduce(UInt64(1024)) { acc, pt in
            max(acc, max(pt[keyPath: primaryValue], pt[keyPath: secondaryValue]))
        }
        return Double(maxVal) * 1.15
    }

    public var body: some View {
        Chart {
            ForEach(points) { pt in
                AreaMark(
                    x: .value("Time", pt.date),
                    y: .value("Down", Double(pt[keyPath: secondaryValue])),
                    series: .value("Series", "Down")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(secondaryColor.opacity(0.18))

                LineMark(
                    x: .value("Time", pt.date),
                    y: .value("Down", Double(pt[keyPath: secondaryValue])),
                    series: .value("Series", "Down")
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(secondaryColor)

                LineMark(
                    x: .value("Time", pt.date),
                    y: .value("Up", Double(pt[keyPath: primaryValue])),
                    series: .value("Series", "Up")
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(primaryColor)
            }
        }
        .chartYScale(domain: 0...maxRate)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { val in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(Color.secondary.opacity(0.22))
                AxisValueLabel {
                    if let d = val.as(Double.self) {
                        Text(ByteFormatters.compactMenuRate(UInt64(max(0, d))))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 68)
    }
}

public struct MemoryBreakdownBar: View {
    public let memory: MemoryMetrics

    public init(memory: MemoryMetrics) {
        self.memory = memory
    }

    public var body: some View {
        let total = max(Double(memory.totalBytes), 1)
        GeometryReader { geo in
            HStack(spacing: 1) {
                segment(Double(memory.appBytes) / total, color: .blue, width: geo.size.width)
                segment(Double(memory.wiredBytes) / total, color: .orange, width: geo.size.width)
                segment(Double(memory.compressedBytes) / total, color: .purple, width: geo.size.width)
                segment(Double(memory.cachedBytes) / total, color: .teal.opacity(0.6), width: geo.size.width)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 10)
    }

    @ViewBuilder
    private func segment(_ fraction: Double, color: Color, width: CGFloat) -> some View {
        let w = max(0, width * min(1, fraction))
        if w >= 1 {
            Rectangle()
                .fill(color)
                .frame(width: w)
        }
    }
}

public struct PressureBadge: View {
    public let level: PressureLevel
    public let pct: Double

    public init(level: PressureLevel, pct: Double) {
        self.level = level
        self.pct = pct
    }

    private var color: Color {
        switch level {
        case .normal: .green
        case .warn: .orange
        case .critical: .red
        }
    }

    private var label: String {
        switch level {
        case .normal: "Normal"
        case .warn: "Warning"
        case .critical: "Critical"
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("Pressure: \(label) (\(Int(pct.rounded()))%)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(level == .normal ? .secondary : color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

public struct CoreUsageGrid: View {
    public let cores: [CoreUsage]

    public init(cores: [CoreUsage]) {
        self.cores = cores
    }

    public var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: cores.count > 12 ? 8 : min(max(cores.count, 1), 8))
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(cores) { core in
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(coreColor(core))
                                .frame(height: max(2, geo.size.height * min(1, core.usagePct / 100.0)))
                        }
                    }
                    .frame(height: 26)

                    Text(coreLabel(core))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func coreLabel(_ core: CoreUsage) -> String {
        switch core.kind {
        case .performance: "P\(core.index + 1)"
        case .efficiency: "E\(core.index + 1)"
        case .standard: "C\(core.index + 1)"
        }
    }

    private func coreColor(_ core: CoreUsage) -> Color {
        if core.usagePct >= 90 { return .red }
        if core.usagePct >= 70 { return .orange }
        switch core.kind {
        case .performance: return .blue
        case .efficiency: return .cyan
        case .standard: return .blue
        }
    }
}
