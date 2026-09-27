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
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
    }

    /// Never becomes key — clicking/dragging the panel must not steal focus
    /// from whatever app (a meeting/video call, a browser) the user is
    /// actually working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
