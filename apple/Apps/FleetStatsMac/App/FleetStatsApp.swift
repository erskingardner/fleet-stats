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
        NSApp.setActivationPolicy(.accessory)

        notifications.setup()
        notifications.onOpenHost = { [weak self] hostID, tab in
            self?.statusBar?.openPopover(hostID: hostID, tab: tab)
        }
        notifications.onOpenUpdates = { [weak self] in
            self?.showSettingsWindow()
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
        let token = supervisor.localToken(for: existingLocalID)
        let localPort = supervisor.start(token: token)

        supervisor.onPortChanged = { [weak self] newPort in
            guard let self else { return }
            _ = self.store.ensureLocalHost(name: hostName, port: newPort, token: token)
        }

        if store.localHost == nil {
            let local = FleetHostConfig(
                id: existingLocalID,
                name: hostName,
                address: "127.0.0.1",
                port: localPort,
                isLocal: true,
                enabled: true
            )
            store.hosts.insert(local, at: 0)
            store.states[local.id] = HostRuntimeState()
            store.selectedHostID = local.id
        }
        _ = store.ensureLocalHost(name: hostName, port: localPort, token: token)
        store.startAllStreams()

        statusBar = StatusBarController(
            store: store,
            updater: updater,
            onOpenSettings: { [weak self] in
                self?.showSettingsWindow()
            },
            onCheckForUpdates: { [weak self] in
                self?.showSettingsWindow()
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

    private func showSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: SettingsView(store: store, supervisor: supervisor, updater: updater)
        )
        let win = NSWindow(contentViewController: hosting)
        win.title = "FleetStats Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        settingsWindow = win
    }
}
