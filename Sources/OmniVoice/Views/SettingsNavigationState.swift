import Foundation
import SwiftUI

/// One of `SettingsView`'s four tabs (Task 3.1) — Docs/UX-SETTINGS-MODEL-MANAGEMENT.md
/// §4.1's "语音与引擎 / 模型库管理 / 语言与字幕 / 关于".
enum SettingsTab: String, CaseIterable, Identifiable {
    case engines
    case models
    case language
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .engines: return "语音与引擎"
        case .models: return "模型库管理"
        case .language: return "语言与悬浮窗"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .engines: return "mic"
        case .models: return "shippingbox"
        case .language: return "globe"
        case .about: return "info.circle"
        }
    }
}

/// Shared across the app (one instance, injected via `.environmentObject` in
/// `OmniVoiceApp`) so a click on the menu bar's "模型管理…" — which fires
/// *before* `SettingsView` even exists, since `Settings { ... }` only
/// constructs its content on first open — can still steer which tab that
/// view lands on (Task 3.4). `SettingsView` itself binds its `TabView`'s
/// `selection` straight to `selectedTab`, rather than keeping its own
/// duplicate `@State`, so both this external trigger and the user's own tab
/// clicks go through the one source of truth.
@MainActor
final class SettingsNavigationState: ObservableObject {
    private static let defaultsKey = "org.omnivoice.settingsSelectedTab"

    /// Restored from `UserDefaults` at launch, then persisted on every
    /// change — Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.1's "默认停留在上次
    /// 访问的 Tab（或「语音与引擎」）" window-routing rule.
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
            selectedTab = .engines
        }
    }

    /// "模型管理…" (menu bar and the in-form nudge next to an undownloaded
    /// engine) — jump straight to the "模型库管理" tab.
    func openModelLibrary() {
        selectedTab = .models
    }
}
