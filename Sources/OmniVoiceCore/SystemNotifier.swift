import AppKit
import Foundation
import UserNotifications

/// Posts macOS system notifications for long-running background work (model
/// downloads) so the user can switch away while it runs.
///
/// Silent no-op outside a real `.app` bundle (`swift run` has no bundle
/// identifier and `UNUserNotificationCenter.current()` traps there), when the
/// user turned "完成时发送系统通知" off, when the app is frontmost (the UI
/// already shows the result), or when notification permission is denied.
@MainActor
public enum SystemNotifier {
    public static let enabledKey = "org.hdcola.omnivoice.notifications.enabled"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Asks for permission the first time (no-op afterwards). Call when the
    /// user starts something worth notifying about, not at launch.
    public static func requestAuthorizationIfNeeded() {
        guard isAvailable, isEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func notify(title: String, body: String, force: Bool = false) {
        guard isAvailable, isEnabled, force || !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
