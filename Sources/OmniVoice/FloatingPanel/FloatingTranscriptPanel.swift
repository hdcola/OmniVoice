import AppKit
import SwiftUI

/// `NSHostingView` consumes `mouseDown` for its own SwiftUI gesture
/// recognition and never lets it bubble up to the window, so plain
/// `isMovableByWindowBackground` silently does nothing once the content view
/// is SwiftUI — this subclass falls back to `performDrag(with:)` for any
/// `mouseDown` no SwiftUI control inside actually handled (buttons/gestures
/// still consume the event before it reaches here, so this only fires on
/// otherwise-empty background clicks).
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// A non-activating, always-on-top, semi-transparent panel that shows the
/// live transcript while the user is in a meeting/lecture — separate from
/// the main history window so it can float over other apps without ever
/// stealing focus or showing up in the Dock/Cmd-Tab switcher.
final class FloatingTranscriptPanel: NSPanel {
    private static let frameAutosaveName = "FloatingTranscriptPanel"

    /// Whether `init` found (and applied) a previously-saved frame — the
    /// caller (`AppDelegate`) only falls back to `positionAtBottomCenterOfScreen()`
    /// when this is `false`, so a restored position/size is never
    /// immediately overridden.
    private(set) var didRestoreFrame = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Matches `FloatingTranscriptView`'s `.frame(minWidth:minHeight:...)`
        // — without this, `.resizable` in the style mask lets the user drag
        // the window smaller than the SwiftUI content can actually shrink to.
        minSize = NSSize(width: 380, height: 200)
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        // Replaced by a custom close button in the control bar
        // (`FloatingTranscriptView`) that calls `orderOut(nil)` — same
        // effect, but themed to match the panel instead of a stray native
        // traffic light sitting on top of a titlebar-less panel.
        standardWindowButton(.closeButton)?.isHidden = true

        // Remembers this panel's position/size (in `UserDefaults.standard`,
        // under "NSWindow Frame FloatingTranscriptPanel") across quit/relaunch
        // — dragging or resizing the panel (both already wired up above)
        // triggers AppKit's own frame-change notifications, which
        // `setFrameAutosaveName(_:)` is enough to hook into on its own; no
        // `windowDidMove`/`windowDidResize` delegate needed. Its `Bool`
        // return already covers the *restore* side too (it both applies a
        // previously-saved frame, if one exists, and arranges future saves
        // under the same name in one call — an explicit separate
        // `setFrameUsingName(_:)` call first would just be redundant): `true`
        // if a saved frame existed and was applied, `false` on a fresh
        // install (nothing saved yet) or if the saved frame doesn't fit any
        // connected screen (falls back to `contentRect`/`center()` either
        // way).
        didRestoreFrame = setFrameAutosaveName(Self.frameAutosaveName)
    }

    /// Never becomes key — clicking/dragging the panel must not steal focus
    /// from whatever app (a meeting/video call, a browser) the user is
    /// actually working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Where a brand-new panel (see `didRestoreFrame`) opens — bottom-center
    /// of the main screen, not dead center (`center()`), since that's where
    /// live captions/subtitles conventionally sit (meeting apps, system
    /// dictation, ...) and stays out of the way of whatever's in the middle
    /// of the screen the user is actually looking at. `visibleFrame` (not
    /// `frame`) already excludes the Dock/menu bar, so this doesn't need its
    /// own check for either.
    func positionAtBottomCenterOfScreen() {
        // `NSScreen.main` (the screen holding the key window) can come back
        // `nil` in the short window right at launch, before this
        // never-key/never-main accessory app has any window the system
        // considers key/main yet — `NSScreen.screens.first` still gives a
        // real screen to place the panel on in that case, falling back to
        // `center()`'s own no-op-safe behavior only if there's truly no
        // screen at all (e.g. a headless CI runner).
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            center()
            return
        }
        let visibleFrame = screen.visibleFrame
        let panelFrame = frame
        let origin = NSPoint(
            x: visibleFrame.midX - panelFrame.width / 2,
            y: visibleFrame.minY + Self.bottomMargin
        )
        setFrameOrigin(origin)
    }

    /// Gap left below the panel and the bottom of `visibleFrame` — enough to
    /// clear the Dock (when it's set to auto-hide, `visibleFrame` doesn't
    /// account for it) and to not look glued to the very edge of the screen.
    private static let bottomMargin: CGFloat = 72
}
