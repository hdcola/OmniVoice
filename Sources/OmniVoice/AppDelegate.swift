import AppKit
import OmniVoiceCore
import SwiftUI

/// Owns the floating transcript panel's lifecycle and hooks app termination.
///
/// The panel is created once, lazily, the first time `attach(session:)` runs
/// (from `MenuBarContentView`'s `onAppear`) and then just shown/hidden via
/// `toggleFloatingPanel()` — it stays alive (off-screen, `orderOut`) rather
/// than being torn down when hidden, so its hosted `FloatingTranscriptView`
/// keeps its `.translationTask` bridge running across the panel's own
/// show/hide cycles (see `RecordingSession.translationBridgeStream()`'s doc:
/// that continuation is meant to persist independent of window visibility).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var floatingPanel: FloatingTranscriptPanel?

    func attach(session: RecordingSession) {
        guard floatingPanel == nil else { return }
        let panel = FloatingTranscriptPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240))
        panel.contentView = NSHostingView(rootView: FloatingTranscriptView(session: session))
        panel.center()
        floatingPanel = panel
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
