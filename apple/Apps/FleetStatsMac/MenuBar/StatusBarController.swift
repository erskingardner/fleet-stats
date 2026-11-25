import AppKit
import FleetKit
import SwiftUI

struct MenuBarStripConfig {
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

/// Crisp native menu bar view modeled directly after the compact iStat Menus strip:
/// stacked label + bold tabular percentage for CPU/RAM/SSD, plus red/blue dots for up/down speeds.
struct MenuBarStripView: View {
    let store: FleetStore
    let config: MenuBarStripConfig
    let onSelectZone: (MetricTab) -> Void

    private var snap: HostSnapshot? { store.localSnapshot }

    var body: some View {
        HStack(spacing: 11) {
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
        .padding(.horizontal, 6)
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
        }
        .frame(width: 30, alignment: .leading)
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
                .frame(width: 23, alignment: .trailing)
                .lineLimit(1)
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
    private var hostingView: NSHostingView<AnyView>?
    private var eventMonitor: Any?
    private let onOpenSettings: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onQuit: () -> Void
    private var stripConfig = MenuBarStripConfig.load()

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
        button.target = self
        button.action = #selector(handleButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        rebuildStripView()
    }

    func rebuildStripView() {
        guard let button = statusItem.button else { return }
        stripConfig = MenuBarStripConfig.load()

        hostingView?.removeFromSuperview()
        let root = AnyView(
            MenuBarStripView(store: store, config: stripConfig) { [weak self] tab in
                self?.openPopover(tab: tab)
            }
        )
        let host = StatusBarHostingView(rootView: root)
        host.onLeftClick = { [weak self] localX in
            guard let self else { return }
            let tab = self.metricTab(atX: localX)
            self.openPopover(tab: tab)
        }
        host.onRightClick = { [weak self] event in
            self?.showContextMenu(event: event)
        }
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        hostingView = host
        updateStatusItemWidth()
    }

    private func updateStatusItemWidth() {
        guard let host = hostingView else { return }
        let fit = host.fittingSize
        if fit.width > 20 {
            statusItem.length = ceil(fit.width) + 2
        }
    }

    private func observeStripPreferences() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                let latest = MenuBarStripConfig.load()
                if let self,
                   latest.showCPU != self.stripConfig.showCPU
                    || latest.showRAM != self.stripConfig.showRAM
                    || latest.showSSD != self.stripConfig.showSSD
                    || latest.showNetwork != self.stripConfig.showNetwork {
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
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(event: event)
        } else if let button = statusItem.button {
            let localX = button.convert(event.locationInWindow, from: nil).x
            openPopover(tab: metricTab(atX: localX))
        } else {
            togglePopover()
        }
    }

    /// Maps an X coordinate inside the menu bar strip to the exact clicked metric zone.
    private func metricTab(atX x: CGFloat) -> MetricTab {
        var zones: [(MetricTab, CGFloat)] = []
        if stripConfig.showCPU { zones.append((.cpu, 30)) }
        if stripConfig.showRAM { zones.append((.ram, 30)) }
        if stripConfig.showSSD { zones.append((.ssd, 30)) }
        if stripConfig.showNetwork { zones.append((.network, 57)) }
        guard !zones.isEmpty else { return .cpu }

        let spacing: CGFloat = 11
        var cursor: CGFloat = 6
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

private final class StatusBarHostingView<Content: View>: NSHostingView<Content> {
    var onLeftClick: ((CGFloat) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?(event)
        } else {
            let pt = convert(event.locationInWindow, from: nil)
            onLeftClick?(pt.x)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}
