import Foundation
import OmniVoiceCore
import ServiceManagement

/// Same `org.hdcola.omnivoice.*` namespacing as `PersistedSettingsKey`.
enum PersistedLaunchKey {
    static let preloadMode = "org.hdcola.omnivoice.launch.preloadMode"
}

/// What `AppDelegate` loads into memory at launch (see "启动时加载模型").
enum LaunchPreloadMode: String, CaseIterable, Identifiable {
    case off
    case translationOnly
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "不加载"
        case .translationOnly: return "仅翻译模型"
        case .all: return "翻译和识别模型"
        }
    }

    var scope: RecordingSession.PreloadScope? {
        switch self {
        case .off: return nil
        case .translationOnly: return .translationOnly
        case .all: return .all
        }
    }

    /// The scope worth running for `session`'s current engines — nil when
    /// nothing would actually load: off, only system engines selected, or
    /// "仅翻译模型" while the translator is a system engine.
    @MainActor
    func effectiveScope(for session: RecordingSession) -> RecordingSession.PreloadScope? {
        guard let scope, session.usesOnDeviceModelEngine else { return nil }
        if scope == .translationOnly, session.translationEngineKind != .model { return nil }
        return scope
    }

    static var stored: LaunchPreloadMode {
        UserDefaults.standard.string(forKey: PersistedLaunchKey.preloadMode)
            .flatMap(LaunchPreloadMode.init(rawValue:)) ?? .off
    }
}

/// "开机时自动启动" — the login item itself is the source of truth
/// (`SMAppService.mainApp.status`), not a stored flag, so a user turning it
/// off in System Settings → 登录项 is reflected the next time `refresh()` runs.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var lastError: String?

    init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
