import OmniVoiceCore
import SwiftData
import SwiftUI

@main
struct OmniVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("OmniVoice", systemImage: "waveform") {
            MenuBarContentView()
                .environmentObject(appDelegate.session)
                .environmentObject(appDelegate)
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("历史记录", id: "history") {
            SessionListView()
                .environmentObject(appDelegate.session)
                .modelContainerIfAvailable(appDelegate.modelContainer)
        }

        // `Window`, not `WindowGroup` — a `WindowGroup` opens a brand new
        // window instance on every `openWindow(id:)` call (it's designed for
        // multi-document windows), which repeated clicks on "模型管理…"/the
        // Settings shortcut would otherwise keep stacking up. `Window` is
        // macOS's singleton-window scene: `openWindow(id:)` reuses/refocuses
        // the one instance instead.
        Window("模型管理", id: "modelManagement") {
            ModelManagementView(modelDownloadManager: appDelegate.session.modelDownloadManager)
                .environmentObject(appDelegate.session)
        }
        // Without this, the window's frame defaults to something larger
        // than `ModelManagementView`'s own `.frame(width: 460)` content,
        // leaving visible empty space the user could then drag even wider —
        // `.contentSize` keeps the window sized to exactly what its content
        // asks for.
        .windowResizability(.contentSize)

        Settings {
            SettingsView(modelDownloadManager: appDelegate.session.modelDownloadManager)
                .environmentObject(appDelegate.session)
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
