import AppKit
import Combine
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
    private var isRunningCancellable: AnyCancellable?
    /// Task 4.1 (首次启动向导) — kept alive only for as long as the window
    /// itself is open; released once the user finishes/skips it.
    private var onboardingWindow: NSWindow?
    /// ⌥A/⌥S selection translation — constructed here (not lazily) for the
    /// same reason as `session`: its global hot keys must work from launch,
    /// before any menu or window has been opened.
    let selectionController: SelectionTranslationController

    override init() {
        // A failed store (disk full, corrupted schema after a migration
        // mistake, ...) shouldn't prevent the app from at least running a
        // recording session with no history — `RecordingSession` treats a
        // nil store as "don't persist".
        let store = try? SessionStore()
        sessionStore = store
        let session = RecordingSession(sessionStore: store)
        self.session = session
        selectionController = SelectionTranslationController(
            translator: SelectionTranslator(
                modelDownloadManager: session.modelDownloadManager,
                preferredModelVariantID: { [weak session] in session?.translationModelVariantID },
                recordingEngineID: { [weak session] in session?.translationEngineID }
            )
        )
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
        // Only place a brand-new panel — one whose position/size was just
        // restored from a previous run (`didRestoreFrame`, see
        // `FloatingTranscriptPanel.init`) should open exactly where the user
        // left it, not get repositioned out from under that.
        if !panel.didRestoreFrame {
            panel.positionAtBottomCenterOfScreen()
        }
        floatingPanel = panel

        // Shown from launch (not just on demand) since the panel hosts the
        // controls used most often (start/stop, language pickers) alongside
        // the live transcript — `toggleFloatingPanel()`/the panel's own
        // close button still let the user hide it manually.
        panel.orderFrontRegardless()

        // ...but the user can also hide it (menu toggle or the panel's own
        // close button) and then start a recording from the menu bar's own
        // start/stop button — without this, that recording would proceed
        // with no visible feedback at all, since nothing else re-shows the
        // panel once it's been hidden.
        isRunningCancellable = session.$isRunning
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak panel] _ in
                panel?.orderFrontRegardless()
            }

        presentOnboardingIfNeeded()
    }

    /// Task 4.1 — shown exactly once, on the very first launch (see
    /// `PersistedOnboardingKey.hasCompletedOnboarding`'s doc), as its own
    /// titled/resizable window rather than a `.sheet` on the floating
    /// panel — that panel is a non-activating `NSPanel` that never becomes
    /// key (see `FloatingTranscriptPanel.canBecomeKey`), which a SwiftUI
    /// sheet needs its presenting window to be able to become in order to
    /// receive keyboard focus/dismiss correctly.
    private func presentOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: PersistedOnboardingKey.hasCompletedOnboarding) else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Height bumped from 420 to 440 (Problem 1, round-4 user report) —
        // the third "均衡低内存模式" mode card has one extra bullet line
        // versus the original two cards, growing Step 2's natural height
        // slightly; this window has no `.resizable` style mask, so without
        // the extra headroom the bottom action row could clip.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "欢迎使用 OmniVoice"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: OnboardingView(
                session: session, downloadManager: session.modelDownloadManager,
                onFinished: { [weak self, weak window] in
                    window?.close()
                    self?.onboardingWindow = nil
                }
            )
        )
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
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
        // Quitting mid-recording (Cmd+Q, system shutdown, ...) previously
        // left that recording's history record with no `endedAt` — close
        // it out first, before touching anything model-related below.
        session.finalizeActiveSessionBeforeQuit()

        // `RecordingSession` now keeps a `.model`-kind engine's weights
        // loaded across stop/start cycles (see `isModelLoaded`'s doc), so
        // unlike before, something *can* still be loaded here — synchronously
        // release it before exit, since ggml's Metal backend asserts if its
        // GPU resources outlive process exit (see
        // `InProcessTranslator.unload()`'s doc).
        session.unloadModelsBeforeQuit()
        // Same Metal exit-time concern for the selection panel's own
        // HY-MT1.5 copy (see `SelectionTranslator`'s doc).
        selectionController.translator.unloadModelBeforeQuit()
    }
}
