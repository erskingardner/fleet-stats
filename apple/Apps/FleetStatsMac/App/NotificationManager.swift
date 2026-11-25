import FleetKit
import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var onOpenHost: ((UUID, MetricTab) -> Void)?
    var onOpenUpdates: (() -> Void)?
    private var isAuthorized = false

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                self.isAuthorized = granted
            }
        }
    }

    func post(_ payload: FleetNotificationPayload) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = payload.severity == .critical ? .defaultCritical : .default
        content.userInfo = [
            "hostId": payload.hostId.uuidString,
            "tab": payload.metricTab.rawValue
        ]

        let req = UNNotificationRequest(
            identifier: "fleetstats-\(payload.hostId.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    func postUpdateAvailable(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "FleetStats \(version) Available"
        content.body = "Click to open Settings and install the update in place."
        content.sound = .default
        content.userInfo = ["kind": "app_update"]

        let req = UNNotificationRequest(
            identifier: "fleetstats-update-\(version)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if (info["kind"] as? String) == "app_update" {
            await MainActor.run {
                self.onOpenUpdates?()
            }
            return
        }
        guard let hostStr = info["hostId"] as? String,
              let hostID = UUID(uuidString: hostStr) else { return }
        let tabRaw = info["tab"] as? String ?? MetricTab.ram.rawValue
        let tab = MetricTab(rawValue: tabRaw) ?? .ram
        await MainActor.run {
            self.onOpenHost?(hostID, tab)
        }
    }
}
