import OmniVoiceCore
import SwiftData
import SwiftUI

@main
struct OmniVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session: RecordingSession
    private let sessionStore: SessionStore?

    init() {
        // A failed store (disk full, corrupted schema after a migration
        // mistake, ...) shouldn't prevent the app from at least running a
        // recording session with no history — `RecordingSession` treats a
        // nil store as "don't persist", same as the POCs' in-memory-only
        // starting point.
        let store = try? SessionStore()
        sessionStore = store
        _session = StateObject(wrappedValue: RecordingSession(sessionStore: store))
    }

    var body: some Scene {
        MenuBarExtra("OmniVoice", systemImage: "waveform") {
            MenuBarContentView()
                .environmentObject(session)
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("历史记录", id: "history") {
            SessionListView()
                .environmentObject(session)
                .modelContainerIfAvailable(sessionStore?.container)
        }

        Settings {
            SettingsView()
                .environmentObject(session)
        }
    }
}

private extension View {
    /// `SessionListView`/`SessionDetailView` use `@Query`, which needs a
    /// `.modelContainer` in the environment — but `SessionStore.init()` can
    /// fail (see `OmniVoiceApp.init()`'s doc), so this degrades to no
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
