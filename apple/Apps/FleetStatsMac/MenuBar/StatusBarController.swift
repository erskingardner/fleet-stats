import AppKit
import FleetKit
import Observation
import SwiftUI

struct MenuBarStripConfig: Equatable, Sendable {
    var showCPU: Bool = true
    var showRAM: Bool = true
    var showSSD: Bool = true
    var showNetwork: Bool = true

    static func load() -> MenuBarStripConfig {
        let d = UserDefaults.standard
        return MenuBarStripConfig(
            showCPU: d.object(forKey: "menubar.showCPU") as? Bool ?? true,
            showRAM: d.object(forKey: "menubar.showRAM") as? Bool ?? true,
            showSSD: d.object(forKey: "menubar.showSSD") as? Bool ?? true,
            showNetwork: d.object(forKey: "menubar.showNetwork") as? Bool ?? true
        )
    }
}

/// Immutable value snapshot rendered into `NSStatusBarButton.image`.
private struct MenuBarStripRenderState: Equatable, Sendable {
    let config: MenuBarStripConfig
    let cpuValue: String
    let cpuAlert: Bool
    let ramValue: String
    let ramAlert: Bool
    let ssdValue: String
    let ssdAlert: Bool
    let netUpValue: String
    let netDownValue: String
    let netUnit: String

    init(config: MenuBarStripConfig, snapshot: HostSnapshot?) {
        self.config = config
        self.cpuValue = snapshot.map { ByteFormatters.percent($0.cpu.totalPct) } ?? "--%"
        self.cpuAlert = (snapshot?.cpu.totalPct ?? 0) >= 92
        self.ramValue = snapshot.map { ByteFormatters.percent($0.memory.usedPct) } ?? "--%"
        self.ramAlert = snapshot?.memory.pressureLevel == .critical
        self.ssdValue = snapshot.map { ByteFormatters.percent($0.disks.primaryUsedPct) } ?? "--%"
        self.ssdAlert = (snapshot?.disks.primaryUsedPct ?? 0) >= 93
        let paired = ByteFormatters.pairedMenuRates(
            up: snapshot?.network.uploadBps ?? 0,
            down: snapshot?.network.downloadBps ?? 0
        )
        self.netUpValue = paired.upValue
        self.netDownValue = paired.downValue
        self.netUnit = paired.unit
    }
}

/// Renders the menu bar strip directly into a dynamic `NSImage` for `NSStatusBarButton.image`.
/// Using `button.image` instead of adding an `NSHostingView` subview lets AppKit's status bar
/// replicants properly dim inactive displays on multi-monitor setups and re-render per display
/// scale and light/dark menu bar appearance without additive vibrancy artifacts.
private enum MenuBarStripRenderer {
    static let barHeight: CGFloat = 22
    private static let fallbackWidth: CGFloat = 22

    private static var labelFont: NSFont { NSFont.systemFont(ofSize: 7.5, weight: .regular) }
    private static var valueFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
    private static var netValueFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular) }
    private static var netUnitFont: NSFont { NSFont.systemFont(ofSize: 9, weight: .regular) }
    private static var fallbackFont: NSFont { NSFont.systemFont(ofSize: 11, weight: .semibold) }

    static func contentWidth(for config: MenuBarStripConfig) -> CGFloat {
        var widths: [CGFloat] = []
        if config.showCPU { widths.append(MenuBarStripView.percentColumnWidth) }
        if config.showRAM { widths.append(MenuBarStripView.percentColumnWidth) }
        if config.showSSD { widths.append(MenuBarStripView.percentColumnWidth) }
        if config.showNetwork { widths.append(MenuBarStripView.networkColumnWidth) }
        guard !widths.isEmpty else { return fallbackWidth }
        return widths.reduce(0, +) + CGFloat(widths.count - 1) * MenuBarStripView.columnSpacing
    }

    static func makeImage(for state: MenuBarStripRenderState) -> NSImage {
        let width = contentWidth(for: state.config)
        let size = NSSize(width: width, height: barHeight)
        let image = NSImage(size: size, flipped: true) { rect in
            draw(state: state, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(state: MenuBarStripRenderState, in rect: NSRect) {
        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let primaryColor = isDark
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor.black.withAlphaComponent(0.88)
        let labelColor = isDark
            ? NSColor.white.withAlphaComponent(0.78)
            : NSColor.black.withAlphaComponent(0.68)
        let alertColor = isDark
            ? NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
            : NSColor(srgbRed: 0.85, green: 0.15, blue: 0.12, alpha: 1.0)
        let uploadDotColor = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
        let downloadDotColor = NSColor(srgbRed: 0.12, green: 0.58, blue: 1.0, alpha: 1.0)

        let config = state.config
        let hasAny = config.showCPU || config.showRAM || config.showSSD || config.showNetwork
        guard hasAny else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: fallbackFont,
                .foregroundColor: primaryColor
            ]
            let badge = "FS" as NSString
            let sz = badge.size(withAttributes: attrs)
            let origin = NSPoint(
                x: (rect.width - sz.width) / 2,
                y: (rect.height - sz.height) / 2
            )
            badge.draw(at: origin, withAttributes: attrs)
            return
        }

        var cursorX: CGFloat = 0

        if config.showCPU {
            drawPercentColumn(
                label: "CPU",
                value: state.cpuValue,
                x: cursorX,
                labelColor: labelColor,
                valueColor: state.cpuAlert ? alertColor : primaryColor
            )
            cursorX += MenuBarStripView.percentColumnWidth + MenuBarStripView.columnSpacing
        }

        if config.showRAM {
            drawPercentColumn(
                label: "RAM",
                value: state.ramValue,
                x: cursorX,
                labelColor: labelColor,
                valueColor: state.ramAlert ? alertColor : primaryColor
            )
            cursorX += MenuBarStripView.percentColumnWidth + MenuBarStripView.columnSpacing
        }

        if config.showSSD {
            drawPercentColumn(
                label: "SSD",
                value: state.ssdValue,
                x: cursorX,
                labelColor: labelColor,
                valueColor: state.ssdAlert ? alertColor : primaryColor
            )
            cursorX += MenuBarStripView.percentColumnWidth + MenuBarStripView.columnSpacing
        }

        if config.showNetwork {
            drawNetworkColumn(
                x: cursorX,
                upValue: state.netUpValue,
                downValue: state.netDownValue,
                unit: state.netUnit,
                uploadDotColor: uploadDotColor,
                downloadDotColor: downloadDotColor,
                textColor: primaryColor
            )
        }
    }

    private static func drawPercentColumn(
        label: String,
        value: String,
        x: CGFloat,
        labelColor: NSColor,
        valueColor: NSColor
    ) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: valueColor
        ]
        (label as NSString).draw(at: NSPoint(x: x, y: 1.0), withAttributes: labelAttrs)
        (value as NSString).draw(at: NSPoint(x: x, y: 8.5), withAttributes: valueAttrs)
    }

    private static func drawNetworkColumn(
        x: CGFloat,
        upValue: String,
        downValue: String,
        unit: String,
        uploadDotColor: NSColor,
        downloadDotColor: NSColor,
        textColor: NSColor
    ) {
        drawNetworkRow(
            x: x,
            textY: 0.25,
            dotY: 3.25,
            dotColor: uploadDotColor,
            value: upValue,
            unit: unit,
            textColor: textColor
        )
        drawNetworkRow(
            x: x,
            textY: 10.75,
            dotY: 13.75,
            dotColor: downloadDotColor,
            value: downValue,
            unit: unit,
            textColor: textColor
        )
    }

    private static func drawNetworkRow(
        x: CGFloat,
        textY: CGFloat,
        dotY: CGFloat,
        dotColor: NSColor,
        value: String,
        unit: String,
        textColor: NSColor
    ) {
        let dotRect = NSRect(x: x, y: dotY, width: 5, height: 5)
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let rightAlign = NSMutableParagraphStyle()
        rightAlign.alignment = .right
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: netValueFont,
            .foregroundColor: textColor,
            .paragraphStyle: rightAlign
        ]
        let valueRect = NSRect(x: x + 8, y: textY, width: 25, height: 11)
        (value as NSString).draw(in: valueRect, withAttributes: valueAttrs)

        let unitAttrs: [NSAttributedString.Key: Any] = [
            .font: netUnitFont,
            .foregroundColor: textColor
        ]
        let unitRect = NSRect(x: x + 35, y: textY, width: 24, height: 11)
        (unit as NSString).draw(in: unitRect, withAttributes: unitAttrs)
    }
}

/// Crisp native menu bar view modeled directly after the compact iStat Menus strip:
/// stacked label + bold tabular percentage for CPU/RAM/SSD, plus red/blue dots for up/down speeds.
struct MenuBarStripView: View {
    let store: FleetStore
    let config: MenuBarStripConfig
    let onSelectZone: (MetricTab) -> Void

    private var snap: HostSnapshot? { store.localSnapshot }

    static let percentColumnWidth: CGFloat = 35
    static let networkColumnWidth: CGFloat = 59
    static let columnSpacing: CGFloat = 9
    static let horizontalPadding: CGFloat = 6

    var body: some View {
        HStack(spacing: Self.columnSpacing) {
            if config.showCPU {
                percentColumn(
                    label: "CPU",
                    value: snap.map { ByteFormatters.percent($0.cpu.totalPct) } ?? "--%",
                    isAlert: (snap?.cpu.totalPct ?? 0) >= 92
                )
            }

            if config.showRAM {
                percentColumn(
                    label: "RAM",
                    value: snap.map { ByteFormatters.percent($0.memory.usedPct) } ?? "--%",
                    isAlert: snap?.memory.pressureLevel == .critical
                )
            }

            if config.showSSD {
                percentColumn(
                    label: "SSD",
                    value: snap.map { ByteFormatters.percent($0.disks.primaryUsedPct) } ?? "--%",
                    isAlert: (snap?.disks.primaryUsedPct ?? 0) >= 93
                )
            }

            if config.showNetwork {
                networkColumn
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxHeight: .infinity, alignment: .center)
        .offset(y: 1.5)
    }

    private func percentColumn(label: String, value: String, isAlert: Bool) -> some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(label)
                .font(.system(size: 7.5, weight: .regular))
                .foregroundStyle(.primary.opacity(0.75))
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(isAlert ? Color.red : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(width: Self.percentColumnWidth, alignment: .leading)
        .fixedSize()
    }

    private var networkColumn: some View {
        let paired = ByteFormatters.pairedMenuRates(
            up: snap?.network.uploadBps ?? 0,
            down: snap?.network.downloadBps ?? 0
        )
        return VStack(alignment: .leading, spacing: 0.5) {
            networkRow(
                dotColor: Color(red: 1.0, green: 0.27, blue: 0.23),
                value: paired.upValue,
                unit: paired.unit
            )
            networkRow(
                dotColor: Color(red: 0.12, green: 0.58, blue: 1.0),
                value: paired.downValue,
                unit: paired.unit
            )
        }
        .offset(y: -0.75)
        .fixedSize()
    }

    private func networkRow(dotColor: Color, value: String, unit: String) -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Spacer().frame(width: 3)
            Text(value)
                .font(.system(size: 9, weight: .regular))
                .monospacedDigit()
                .frame(width: 25, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer().frame(width: 2)
            Text(unit)
                .font(.system(size: 9, weight: .regular))
                .frame(width: 24, alignment: .leading)
                .lineLimit(1)
        }
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: FleetStore
    private let updater: AppUpdater
    private var eventMonitor: Any?
    private nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?
    private let onOpenSettings: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onQuit: () -> Void
    private var stripConfig = MenuBarStripConfig.load()
    private var lastRenderedState: MenuBarStripRenderState?

    init(
        store: FleetStore,
        updater: AppUpdater,
        onOpenSettings: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.updater = updater
        self.onOpenSettings = onOpenSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        setupPopover()
        setupStatusItem()
        observeStripPreferences()
        observeStoreChanges()
    }

    deinit {
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupPopover() {
        popover.contentSize = NSSize(width: 430, height: 540)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(
                store: store,
                updater: updater,
                onOpenSettings: { [weak self] in
                    self?.closePopover()
                    self?.onOpenSettings()
                },
                onQuit: { [weak self] in
                    self?.onQuit()
                }
            )
        )
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = self
        button.action = #selector(handleButtonClick(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusItem.length = NSStatusItem.variableLength

        rebuildStripView()
    }

    func rebuildStripView() {
        stripConfig = MenuBarStripConfig.load()
        renderStrip(snapshot: store.localSnapshot, force: true)
    }

    private func observeStoreChanges() {
        let snapshot = withObservationTracking {
            store.localSnapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStoreChanges()
            }
        }
        renderStrip(snapshot: snapshot)
    }

    private func renderStrip(snapshot: HostSnapshot?, force: Bool = false) {
        guard let button = statusItem.button else { return }
        let state = MenuBarStripRenderState(config: stripConfig, snapshot: snapshot)
        guard force || state != lastRenderedState else { return }
        lastRenderedState = state
        button.image = MenuBarStripRenderer.makeImage(for: state)
    }

    private func observeStripPreferences() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                let latest = MenuBarStripConfig.load()
                if let self, latest != self.stripConfig {
                    self.rebuildStripView()
                }
            }
        }
    }

    @objc private func handleButtonClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(event: event)
            return
        }
        guard let button = statusItem.button, let window = button.window else {
            togglePopover()
            return
        }
        // Always convert from global screen coordinates so multi-monitor & cross-window clicks are exact
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localX = button.convert(windowPoint, from: nil).x
        let imageOriginX = (button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds).minX ?? 0
        openPopover(tab: metricTab(atImageX: localX - imageOriginX))
    }

    /// Maps an X coordinate inside the rendered strip image to the exact clicked metric zone.
    private func metricTab(atImageX x: CGFloat) -> MetricTab {
        var zones: [(MetricTab, CGFloat)] = []
        if stripConfig.showCPU { zones.append((.cpu, MenuBarStripView.percentColumnWidth)) }
        if stripConfig.showRAM { zones.append((.ram, MenuBarStripView.percentColumnWidth)) }
        if stripConfig.showSSD { zones.append((.ssd, MenuBarStripView.percentColumnWidth)) }
        if stripConfig.showNetwork { zones.append((.network, MenuBarStripView.networkColumnWidth)) }
        guard !zones.isEmpty else { return .cpu }

        let spacing = MenuBarStripView.columnSpacing
        var cursor: CGFloat = 0
        for (idx, (tab, width)) in zones.enumerated() {
            let rightEdge = (idx == zones.count - 1)
                ? CGFloat.greatestFiniteMagnitude
                : (cursor + width + spacing / 2)
            if x <= rightEdge {
                return tab
            }
            cursor += width + spacing
        }
        return zones.last?.0 ?? .cpu
    }

    func openPopover(hostID: UUID? = nil, tab: MetricTab? = nil) {
        if let hostID {
            store.selectedHostID = hostID
        }
        if let tab {
            if popover.isShown && !store.showingEvents && store.selectedTab == tab && hostID == nil {
                closePopover()
                return
            }
            store.showingEvents = false
            store.selectedTab = tab
        }
        showPopover()
    }

    func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startEventMonitor()
        }
        if let hostID = store.selectedHost?.id {
            Task {
                await store.refreshHistory(for: hostID, window: store.selectedWindow)
                await store.refreshEvents(for: hostID)
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        stopEventMonitor()
    }

    private func showContextMenu(event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open FleetStats", action: #selector(menuOpenPopover), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(menuCheckForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit FleetStats", action: #selector(menuQuit), keyEquivalent: "q")
        for item in menu.items {
            item.target = self
        }
        if let button = statusItem.button {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        }
    }

    @objc private func menuOpenPopover() { showPopover() }
    @objc private func menuCheckForUpdates() { onCheckForUpdates() }
    @objc private func menuOpenSettings() { onOpenSettings() }
    @objc private func menuQuit() { onQuit() }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopEventMonitor()
    }
}
