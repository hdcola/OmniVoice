import AppKit
import OmniVoiceCore
import QuartzCore
import ScreenCaptureKit
import Vision

// Screen freezing, region selection and text recognition for ⌥S screenshot
// translation — ported (and restyled without Cida's design system) from
// Cida (https://github.com/Xuanwo/cida, Apache-2.0):
// `Sources/Cida/ScreenCapture.swift`, `CaptureOverlay.swift` and
// `TextRecognition.swift`.

enum ScreenCaptureError: Error {
    case displayUnavailable
}

/// Freezes the whole of a display at its native pixel size, without the
/// pointer, through ScreenCaptureKit. Needs the Screen Recording permission
/// — the same one "包含系统声音" already asks for.
enum ScreenFreezer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only lets
    /// the user flip the switch in System Settings themselves.
    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    static func capture(_ screen: NSScreen) async throws -> CGImage {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ScreenCaptureError.displayUnavailable
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayUnavailable
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
    }
}

/// The full-screen layer ⌥S puts over a frozen screen: a veil over the
/// frozen image, a hint naming what to do, and the dragged frame shown
/// un-veiled. Escape, a right click, or a click without a drag cancels.
@MainActor
enum CaptureOverlay {
    /// Shows `image` over `screen` and returns the part of it the user
    /// framed, or nil when they cancelled.
    static func selectRegion(of image: CGImage, on screen: NSScreen) async -> CGImage? {
        let panel = CaptureOverlayPanel(screen: screen)
        let view = CaptureOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
        panel.contentView = view
        defer { panel.orderOut(nil) }
        return await withCheckedContinuation { continuation in
            view.onFinish = { selection in
                view.onFinish = nil
                guard let selection else {
                    continuation.resume(returning: nil)
                    return
                }
                let pixelRect = CaptureGeometry.pixelRect(
                    for: selection, in: view.bounds.size,
                    imageSize: CGSize(width: image.width, height: image.height)
                )
                continuation.resume(returning: image.cropping(to: pixelRect))
            }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        }
    }
}

/// Maps a selection in the overlay (points, origin bottom-left) onto the
/// frozen image (pixels, origin top-left).
enum CaptureGeometry {
    /// A drag shorter than this on either side is a click, which cancels.
    static let minimumSelectionSide: CGFloat = 4

    static func pixelRect(for selection: CGRect, in viewSize: CGSize, imageSize: CGSize) -> CGRect {
        let scaleX = imageSize.width / viewSize.width
        let scaleY = imageSize.height / viewSize.height
        let rect = CGRect(
            x: selection.minX * scaleX,
            y: (viewSize.height - selection.maxY) * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        ).integral
        return rect.intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func selection(from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        ).intersection(bounds)
    }

    /// The part of the layer's contents a sheet over `selection` shows. The
    /// unit square has its origin at the bottom-left, like the view.
    static func contentsRect(for selection: CGRect, in viewSize: CGSize) -> CGRect {
        CGRect(
            x: selection.minX / viewSize.width, y: selection.minY / viewSize.height,
            width: selection.width / viewSize.width, height: selection.height / viewSize.height
        )
    }
}

final class CaptureOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        hasShadow = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        title = "截图框选"
    }
}

/// The frozen image is the view's layer contents and never redraws. The
/// veil covers it; a drag only moves the selection layer, which shows the
/// same image un-veiled through `contentsRect`.
final class CaptureOverlayView: NSView {
    private let image: CGImage
    private var dragStart: CGPoint?
    private var selection: CGRect?
    var onFinish: ((CGRect?) -> Void)?

    private let veilLayer = CALayer()
    private let selectionLayer = CALayer()
    private let hint = NSTextField(labelWithString: "拖动框选要翻译的文字 · Esc 取消")

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize

        veilLayer.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        selectionLayer.contents = image
        selectionLayer.contentsGravity = .resize
        selectionLayer.borderWidth = 1.5
        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        selectionLayer.masksToBounds = true
        layer?.addSublayer(veilLayer)
        layer?.addSublayer(selectionLayer)

        hint.font = .systemFont(ofSize: 14, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hint.layer?.cornerRadius = 8
        hint.layer?.zPosition = 10
        addSubview(hint)

        updateLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The hint is only a label; every press belongs to the overlay.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func layout() {
        super.layout()
        let size = hint.fittingSize
        let width = size.width + 28
        let height = size.height + 14
        hint.frame = NSRect(x: floor((bounds.width - width) / 2), y: bounds.height - height - 72, width: width, height: height)
        updateLayers()
    }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        veilLayer.frame = bounds
        selectionLayer.frame = selection ?? .zero
        selectionLayer.isHidden = selection == nil
        if let selection, bounds.width > 0, bounds.height > 0 {
            selectionLayer.contentsRect = CaptureGeometry.contentsRect(for: selection, in: bounds.size)
        }
        CATransaction.commit()
        // The hint never covers what's being framed.
        hint.isHidden = selection.map { $0.intersects(hint.frame) } ?? false
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        selection = CaptureGeometry.selection(from: dragStart, to: convert(event.locationInWindow, from: nil), within: bounds)
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection,
              selection.width >= CaptureGeometry.minimumSelectionSide,
              selection.height >= CaptureGeometry.minimumSelectionSide
        else {
            onFinish?(nil)
            return
        }
        onFinish?(selection)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Recognizes the text in a captured part of the screen, on this Mac —
/// nothing is uploaded; only the recognized text goes on to the (also
/// local) translation engine.
enum ScreenTextRecognizer {
    /// The recognized text as paragraphs (see `RecognizedTextLayout`), or
    /// nil when the image holds none. `languageCodes` (the user's two
    /// selection languages) are added to Chinese and English, the pair Cida
    /// found recognizes best by default.
    static func recognizeText(in image: CGImage, languageCodes: [String]) async throws -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        var languages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
        // Only languages Vision can actually read — asking for one it
        // can't (Hindi, say) fails the whole request, not just that language.
        let supported = request.supportedRecognitionLanguages
        for code in languageCodes {
            guard !languages.contains(where: { SelectionLanguageDirection.isSameLanguage($0.minimalIdentifier, code) }),
                  let language = supported.first(where: { SelectionLanguageDirection.isSameLanguage($0.minimalIdentifier, code) })
            else { continue }
            languages.append(language)
        }
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        // With a fixed zh-Hans-first order, English lines come back with
        // full-width punctuation and misread words ("（job", "iob");
        // detecting the language per line reads both scripts as they are.
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        let lines = observations.compactMap { observation -> RecognizedLine? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox.cgRect
            // Vision measures from the bottom-left; the layout reads top-down.
            return RecognizedLine(text: text, frame: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
        return RecognizedTextLayout.text(from: lines)
    }
}
