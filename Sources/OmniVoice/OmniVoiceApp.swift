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
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("历史记录", id: "history") {
            SessionListView()
                .environmentObject(appDelegate.session)
                .modelContainerIfAvailable(appDelegate.modelContainer)
        }

        Settings {
            SettingsView()
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
