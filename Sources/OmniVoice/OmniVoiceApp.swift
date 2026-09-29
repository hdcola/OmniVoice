import OmniVoiceCore
import SwiftData
import SwiftUI

@main
struct OmniVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Task 3.4 — shared between `MenuBarContentView` (whose "模型管理…" row
    /// needs to steer `SettingsView` before that view even exists, since
    /// `Settings { ... }` only constructs its content on first open) and
    /// `SettingsView` itself (whose `TabView` binds directly to
    /// `selectedTab`). See `SettingsNavigationState`'s own doc.
    @StateObject private var settingsNavigation = SettingsNavigationState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(modelDownloadManager: appDelegate.session.modelDownloadManager)
                .environmentObject(appDelegate.session)
                .environmentObject(appDelegate)
                .environmentObject(settingsNavigation)
        } label: {
            MenuBarLabel(modelDownloadManager: appDelegate.session.modelDownloadManager, session: appDelegate.session)
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("历史记录", id: "history") {
            SessionListView()
                .environmentObject(appDelegate.session)
                .modelContainerIfAvailable(appDelegate.modelContainer)
        }

        // "模型库管理" now lives as a tab inside `SettingsView` (Task 3.1/3.4)
        // instead of this standalone `Window` scene — a click on "模型管理…"
        // opens Settings and switches `settingsNavigation.selectedTab` to
        // `.models` rather than a second window, so there's exactly one
        // place model download/delete state is rendered, not two that could
        // drift out of sync mid-download.
        Settings {
            SettingsView(modelDownloadManager: appDelegate.session.modelDownloadManager)
                .environmentObject(appDelegate.session)
                .environmentObject(settingsNavigation)
        }
    }
}

private extension View {
    /// `SessionListView`/`SessionDetailView` use `@Query`, which needs a
    /// `.modelContainer` in the environment — but `SessionStore.init()` can
    /// fail (see `AppDelegate.init()`'s doc), so this degrades to no
    /// container (an empty, non-persisting history window) rather than
    /// crashing the whole app over a history feature being unavailable.
    @ViewBuilder
    func modelContainerIfAvailable(_ container: ModelContainer?) -> some View {
        if let container {
            self.modelContainer(container)
        } else {
            self
        }
    }
}
