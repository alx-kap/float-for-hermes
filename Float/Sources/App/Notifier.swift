import AppKit
import Observation
import UserNotifications

/// Banners for when Hermes finishes a reply or needs an answer while the panel is hidden.
/// Clicking one opens the panel.
@Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @ObservationIgnored var onOpen: (() -> Void)?
    @ObservationIgnored private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
        Task { await refresh() }
    }

    var isDenied: Bool { authorization == .denied }

    func refresh() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks macOS the first time; afterwards just reports what the user chose in System Settings.
    @discardableResult
    func ensureAuthorized() async -> Bool {
        await refresh()
        if authorization == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refresh()
        }
        return authorization == .authorized || authorization == .provisional
    }

    /// `id` lets a later call replace or withdraw the banner (a prompt's request id, or one per chat for replies).
    func post(id: String, title: String, body: String, thread: String) {
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = thread
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    func withdraw(_ id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func clearAll() {
        center.removeAllDeliveredNotifications()
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.onOpen?() }
    }
}
