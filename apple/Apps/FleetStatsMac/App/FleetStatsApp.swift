import AppKit
import FleetKit
import SwiftUI

@main
struct FleetStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(
                store: delegate.store,
                supervisor: delegate.supervisor,
                updater: delegate.updater
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = FleetStore()
    let supervisor = LocalAgentSupervisor()
    let notifications = NotificationManager()
    let updater = AppUpdater()
    private var statusBar: StatusBarController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--render-screenshots"), idx + 1 < args.count {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            NSApp.setActivationPolicy(.prohibited)
            ScreenshotRenderer.renderAll(to: outURL)
            exit(0)
        }
        #endif

        NSApp.setActivationPolicy(.accessory)

        notifications.setup()
        notifications.onOpenHost = { [weak self] hostID, tab in
            self?.statusBar?.openPopover(hostID: hostID, tab: tab)
        }
        notifications.onOpenUpdates = { [weak self] in
            self?.showSettingsWindow(pane: .general)
        }

        updater.onUpdateAvailable = { [weak self] release in
            self?.notifications.postUpdateAvailable(version: release.tagName)
        }
        updater.onPrepareToRelaunch = { [weak self] in
            self?.store.stopAllStreams()
            self?.supervisor.stop()
        }
        updater.startBackgroundChecks()

        store.onNotification = { [weak self] payload in
            Task { @MainActor in
                self?.notifications.post(payload)
            }
        }

        // Start bundled local fleetd agent on an available port & connect local host
        let hostName = Host.current().localizedName ?? "This Mac"
        let existingLocalID = store.localHost?.id ?? UUID()
        let started = supervisor.start(hostID: existingLocalID)

        supervisor.onConfigurationChanged = { [weak self] newPort, newToken in
            guard let self else { return }
            let currentName = self.store.localHost?.name ?? hostName
            _ = self.store.ensureLocalHost(name: currentName, port: newPort, token: newToken)
        }

        if store.localHost == nil {
            let local = FleetHostConfig(
                id: existingLocalID,
                name: hostName,
                address: "127.0.0.1",
                port: started.port,
                isLocal: true,
                enabled: true
            )
            store.hosts.insert(local, at: 0)
            store.states[local.id] = HostRuntimeState()
            store.selectedHostID = local.id
        }
        _ = store.ensureLocalHost(name: store.localHost?.name ?? hostName, port: started.port, token: started.token)
        store.startAllStreams()

        statusBar = StatusBarController(
            store: store,
            updater: updater,
            onOpenSettings: { [weak self] in
                self?.showSettingsWindow(pane: .fleet)
            },
            onCheckForUpdates: { [weak self] in
                self?.showSettingsWindow(pane: .general)
                Task { await self?.updater.checkForUpdates(userInitiated: true) }
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopAllStreams()
        supervisor.stop()
    }

    private func showSettingsWindow(pane: SettingsPane = .fleet) {
        NSApp.activate(ignoringOtherApps: true)
        if let win = settingsWindow {
            let savedFrame = win.frame
            let hosting = NSHostingController(
                rootView: SettingsView(store: store, supervisor: supervisor, updater: updater, selectedPane: pane)
            )
            hosting.safeAreaRegions = []
            hosting.sizingOptions = []
            win.contentViewController = hosting
            win.setFrame(savedFrame, display: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: SettingsView(store: store, supervisor: supervisor, updater: updater, selectedPane: pane)
        )
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hosting
        win.title = "FleetStats Settings"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 700, height: 500)
        win.maxSize = NSSize(width: 1100, height: 820)
        win.setContentSize(NSSize(width: 760, height: 560))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        settingsWindow = win
    }
}
