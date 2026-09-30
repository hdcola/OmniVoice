import AppKit
import SwiftUI

/// `NSHostingView` consumes `mouseDown` for its own SwiftUI gesture
/// recognition and never lets it bubble up to the window, so plain
/// `isMovableByWindowBackground` silently does nothing once the content view
/// is SwiftUI — this subclass falls back to `performDrag(with:)` for any
/// `mouseDown` no SwiftUI control inside actually handled (buttons/gestures
/// still consume the event before it reaches here, so this only fires on
/// otherwise-empty background clicks).
///
/// Also owns edge resizing. AppKit's native resize zone for this borderless-
/// looking panel is only a thin strip *outside* the window frame — at the
/// visible edge, just inside it, there was neither a resize cursor nor a
/// resize drag, only `performDrag` moving the whole panel. So a
/// `Self.edgeResizeMargin`-wide strip inside the frame is handled here:
/// the matching resize cursor on hover, and a manual frame resize on drag.
/// The cursor comes from a `.activeAlways` tracking area's `mouseMoved`
/// plus `NSCursor.set()`, not cursor rects/`cursorUpdate(with:)`: those
/// only ever fire while the app is active, and this accessory app's panel
/// is non-activating, so the app is practically never active while the
/// user is hovering it. Even `set()` is dropped by the window server for a
/// background app unless `BackgroundCursor.enable()` has run — see there.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private static var edgeResizeMargin: CGFloat { 5 }

    private lazy var edgeCursorTracker = EdgeCursorTracker { [weak self] event in
        self?.updateEdgeCursor(for: event)
    }
    private var edgeTrackingArea: NSTrackingArea?
    /// Whether the cursor currently showing is one this view set — so
    /// moving back into the interior resets it to the arrow exactly once,
    /// then leaves the cursor to SwiftUI (e.g. text selection's I-beam).
    private var isShowingResizeCursor = false
    private var activeResize: (edge: Edge, startFrame: NSRect, startMouse: NSPoint)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let edgeTrackingArea { removeTrackingArea(edgeTrackingArea) }
        // Owned by a separate object rather than `self`, so these events
        // don't also go through `NSHostingView`'s own `mouseMoved`/
        // `mouseExited` handling (it has tracking areas of its own).
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: edgeCursorTracker
        )
        addTrackingArea(area)
        edgeTrackingArea = area
    }

    /// Claims clicks in the edge strip even where a subview (the
    /// transcript's scroll view spans the full width) would otherwise
    /// receive them, so `mouseDown` below can start a resize.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates; with no superview
        // (e.g. hosted outside a window in a test) it's already local.
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        if resizeEdge(at: localPoint) != nil {
            return self
        }
        return super.hitTest(point)
    }

    /// `NSHostingView`'s own `mouseMoved` (from its own tracking area)
    /// runs after `edgeCursorTracker`'s and resets the cursor to the arrow,
    /// so the edge cursor has to be re-applied after `super`, too.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateEdgeCursor(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if let edge = resizeEdge(at: convert(event.locationInWindow, from: nil)) {
            activeResize = (edge, window.frame, NSEvent.mouseLocation)
            return
        }
        window.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let (edge, startFrame, startMouse) = activeResize else {
            super.mouseDragged(with: event)
            return
        }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        let minSize = window.minSize
        let maxSize = window.maxSize
        var frame = startFrame
        // Screen coordinates: y grows upward, so the top edge is `maxY`.
        if edge.contains(.right) {
            frame.size.width = (startFrame.width + dx).clamped(minSize.width, maxSize.width)
        } else if edge.contains(.left) {
            frame.size.width = (startFrame.width - dx).clamped(minSize.width, maxSize.width)
            frame.origin.x = startFrame.maxX - frame.width
        }
        if edge.contains(.top) {
            frame.size.height = (startFrame.height + dy).clamped(minSize.height, maxSize.height)
        } else if edge.contains(.bottom) {
            frame.size.height = (startFrame.height - dy).clamped(minSize.height, maxSize.height)
            frame.origin.y = startFrame.maxY - frame.height
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard activeResize != nil else {
            super.mouseUp(with: event)
            return
        }
        activeResize = nil
        updateEdgeCursor(for: event)
    }

    private func updateEdgeCursor(for event: NSEvent) {
        // Keep the resize cursor for the whole drag, even if the mouse
        // outruns the edge strip.
        guard activeResize == nil else { return }
        let edge = event.type == .mouseExited
            ? nil
            : resizeEdge(at: convert(event.locationInWindow, from: nil))
        if let edge {
            NSCursor.frameResize(position: edge.cursorPosition, directions: .all).set()
            isShowingResizeCursor = true
        } else if isShowingResizeCursor {
            NSCursor.arrow.set()
            isShowingResizeCursor = false
        }
    }

    /// Which edge(s) `point` (in this view's coordinates) is within
    /// `Self.edgeResizeMargin` of, or `nil` for the interior.
    private func resizeEdge(at point: NSPoint) -> Edge? {
        let margin = Self.edgeResizeMargin
        guard bounds.contains(point) else { return nil }
        var edge: Edge = []
        if point.x < margin { edge.insert(.left) }
        if point.x > bounds.width - margin { edge.insert(.right) }
        let nearLowY = point.y < margin
        let nearHighY = point.y > bounds.height - margin
        if isFlipped ? nearLowY : nearHighY { edge.insert(.top) }
        if isFlipped ? nearHighY : nearLowY { edge.insert(.bottom) }
        return edge.isEmpty ? nil : edge
    }
}

/// The edge(s) of `DraggableHostingView` a point is near — a corner is
/// two at once.
private struct Edge: OptionSet {
    let rawValue: Int
    static let left = Edge(rawValue: 1 << 0)
    static let right = Edge(rawValue: 1 << 1)
    static let top = Edge(rawValue: 1 << 2)
    static let bottom = Edge(rawValue: 1 << 3)

    var cursorPosition: NSCursor.FrameResizePosition {
        switch (contains(.top), contains(.bottom), contains(.left), contains(.right)) {
        case (true, _, true, _): .topLeft
        case (true, _, _, true): .topRight
        case (_, true, true, _): .bottomLeft
        case (_, true, _, true): .bottomRight
        case (true, _, _, _): .top
        case (_, true, _, _): .bottom
        case (_, _, true, _): .left
        default: .right
        }
    }
}

/// Lets this app change the cursor while it isn't the active app, which
/// `DraggableHostingView`'s edge resize cursor depends on: the window server
/// otherwise silently ignores `NSCursor.set()` from a background app (the
/// in-process `NSCursor.current` changes, what's on screen doesn't), and a
/// non-activating panel's app is background whenever the user hovers it.
/// There's no public API for this — `SetsCursorInBackground` is a private
/// CoreGraphics connection property (fine for this outside-the-App-Store
/// app), so both symbols are looked up at runtime: if a future macOS drops
/// them, this is a no-op and the edge resize still works, just without the
/// cursor feedback.
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    static func enable() {
        guard let handle = dlopen(nil, RTLD_NOW),
              let defaultConnection = dlsym(handle, "_CGSDefaultConnection"),
              let setConnectionProperty = dlsym(handle, "CGSSetConnectionProperty")
        else { return }
        let connection = unsafeBitCast(defaultConnection, to: DefaultConnection.self)()
        _ = unsafeBitCast(setConnectionProperty, to: SetConnectionProperty.self)(
            connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue
        )
    }
}

/// Tracking-area owner for `DraggableHostingView`'s edge cursor — see its
/// `updateTrackingAreas()` for why this isn't the view itself.
private final class EdgeCursorTracker: NSResponder {
    private let onEvent: (NSEvent) -> Void

    init(onEvent: @escaping (NSEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseMoved(with event: NSEvent) { onEvent(event) }
    override func mouseEntered(with event: NSEvent) { onEvent(event) }
    override func mouseExited(with event: NSEvent) { onEvent(event) }
}

private extension CGFloat {
    func clamped(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lower), upper)
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
        BackgroundCursor.enable()
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

