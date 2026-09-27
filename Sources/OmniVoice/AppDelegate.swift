import AppKit
import OmniVoiceCore
import SwiftData
import SwiftUI

/// Owns `RecordingSession`/`SessionStore` (constructed eagerly, in `init()`,
/// not lazily from some SwiftUI view's `onAppear`) and the floating
/// transcript panel's lifecycle.
///
/// Deliberately **not** owned by `OmniVoiceApp`'s `@StateObject` + a
/// `MenuBarContentView.onAppear` hook (an earlier version of this file did
/// exactly that) — `MenuBarExtra(.menu)` only instantiates its content (and
/// therefore only fires that `onAppear`) the first time the user actually
/// opens the menu. Today that happens to be harmless, since the menu is also
/// the only way to start a recording — but it means the floating panel and
/// its `.translationTask` bridge (see `FloatingTranscriptView`) are wired up
/// by *coincidence*, not by anything that guarantees it. Any future
/// non-menu entry point (a global hotkey, auto-starting a recording on
/// launch) would silently skip this setup with no error. Owning
/// construction here, in `applicationDidFinishLaunching` — guaranteed to run
/// exactly once, at launch, regardless of what the user does with the menu —
/// removes that fragility.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var session: RecordingSession
    private let sessionStore: SessionStore?
    private(set) var floatingPanel: FloatingTranscriptPanel?

    override init() {
        // A failed store (disk full, corrupted schema after a migration
        // mistake, ...) shouldn't prevent the app from at least running a
        // recording session with no history — `RecordingSession` treats a
        // nil store as "don't persist".
        let store = try? SessionStore()
        sessionStore = store
        session = RecordingSession(sessionStore: store)
        super.init()
    }

    /// For `.modelContainer(_:)` in `OmniVoiceApp`'s history window — nil if
    /// `SessionStore.init()` failed (see `init()`'s doc above).
    var modelContainer: ModelContainer? { sessionStore?.container }

    func applicationDidFinishLaunching(_ notification: Notification) {
        session.refreshDevices()

        let panel = FloatingTranscriptPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280))
        panel.contentView = DraggableHostingView(
            rootView: FloatingTranscriptView(session: session, onClose: { [weak panel] in
                panel?.orderOut(nil)
            })
        )
        panel.center()
        floatingPanel = panel

        // The panel now hosts the controls used most often (start/stop,
        // language pickers) alongside the live transcript, so it's shown
        // from launch rather than only on demand — `toggleFloatingPanel()`
        // (menu item) still lets the user hide it manually.
        panel.orderFrontRegardless()
    }

    func toggleFloatingPanel() {
        guard let panel = floatingPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // TODO once `ModelTranscriptionProvider`/`ModelTranslationProvider`
        // are implemented: synchronously unload any loaded in-process model
        // backend here — see `mac-poc-hybrid`'s `AppDelegate` doc for why
        // this matters (ggml's Metal backend asserts if GPU resources
        // outlive process exit). Not needed yet: the system engines this
        // skeleton actually runs hold nothing that needs an explicit
        // synchronous teardown.
    }
}
