import Foundation
import SwiftUI

/// One of `SettingsView`'s tabs — "通用" (permissions, 快捷翻译, 实时转录,
/// 字幕悬浮窗), "模型库" and "关于". Raw values saved by older builds
/// ("engines", "language", "selection") no longer parse and fall back to
/// "通用".
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case models
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .models: return "模型库"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "shippingbox"
        case .about: return "info.circle"
        }
    }
}

/// Shared across the app (one instance, injected via `.environmentObject` in
/// `OmniVoiceApp`) so a click on the menu bar's "模型库…" — which fires
/// *before* `SettingsView` even exists, since `Settings { ... }` only
/// constructs its content on first open — can still steer which tab that
/// view lands on (Task 3.4). `SettingsView`'s `SettingsTabBar` binds
/// straight to `selectedTab`, rather than keeping its own
/// duplicate `@State`, so both this external trigger and the user's own tab
/// clicks go through the one source of truth.
@MainActor
final class SettingsNavigationState: ObservableObject {
    /// The one instance `OmniVoiceApp` injects — also reachable from
    /// `AppDelegate`-side code (notification clicks) that has no SwiftUI
    /// environment to read it from.
    static let shared = SettingsNavigationState()

    private static let defaultsKey = "org.hdcola.omnivoice.settingsSelectedTab"

    /// Restored from `UserDefaults` at launch, then persisted on every
    /// change — Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.1's "默认停留在上次
    /// 访问的 Tab（或「通用」）" window-routing rule.
    @Published var selectedTab: SettingsTab {
        didSet {
            UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.defaultsKey)
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let restored = SettingsTab(rawValue: raw) {
            selectedTab = restored
        } else {
            selectedTab = .general
        }
    }

    /// "模型库…" (menu bar and the in-form nudge next to an undownloaded
    /// engine) — jump straight to the "模型库" tab.
    func openModelLibrary() {
        selectedTab = .models
    }
}
