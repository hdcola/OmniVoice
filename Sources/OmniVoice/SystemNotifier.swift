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
enum SystemNotifier {
    static let modelDownloadCategory = "model_download"
    static let enabledKey = "org.hdcola.omnivoice.notifications.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Retained here because `UNUserNotificationCenter.delegate` is weak.
    private static let clickHandler = NotificationClickHandler()

    /// Routes a click on a download notification to Settings → 模型库. Call
    /// once at launch; the app is an `LSUIElement`, so without this a click
    /// would activate the process but show nothing.
    static func installClickHandler() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = clickHandler
    }

    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Asks for permission the first time (no-op afterwards). Call when the
    /// user starts something worth notifying about, not at launch.
    static func requestAuthorizationIfNeeded() {
        guard isAvailable, isEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `force` only skips this type's own foreground check — while the app is
    /// frontmost macOS still suppresses the banner unless a
    /// `UNUserNotificationCenterDelegate.willPresent` returns `[.banner, .sound]`.
    static func notify(title: String, body: String, force: Bool = false) {
        guard isAvailable, isEnabled, force || !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = modelDownloadCategory
        content.userInfo = ["route": "models"]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

private final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Dismissing the banner (or a future custom action) must not pull the
        // app forward; only a click on the banner itself routes anywhere.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            response.notification.request.content.userInfo["route"] as? String == "models"
        else {
            completionHandler()
            return
        }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            SettingsNavigationState.shared.openModelLibrary()
            if let open = SettingsNavigationState.shared.openSettingsWindow {
                open()
            } else {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            completionHandler()
        }
    }
}
