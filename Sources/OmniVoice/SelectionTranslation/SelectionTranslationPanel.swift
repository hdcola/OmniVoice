import AppKit
import SwiftUI

/// The ⌥A/⌥S translation panel's window. Unlike `FloatingTranscriptPanel`
/// (which never becomes key, so it can't steal focus from whatever the user
/// is captioning), this one **can** become key — its source pane is an
/// editable text view the user types/pastes into — but is still a
/// `.nonactivatingPanel`: it takes keyboard focus without activating
/// OmniVoice, so the app the user summoned it from stays frontmost and gets
/// focus straight back when the panel hides (Esc), the same way Cida's
/// panel (and Spotlight) behave.
final class SelectionTranslationPanel: NSPanel {
    static let defaultSize = NSSize(width: 560, height: 400)

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 420, height: 280)
        title = "快捷翻译"
    }

    /// Top-centre of the screen under the pointer — where the user's
    /// attention already is, and clear of the bottom-centred transcript
    /// panel (`FloatingTranscriptPanel.positionAtBottomCenterOfScreen()`).
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        let size = frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - visible.height * 0.12
        )
        setFrameOrigin(origin)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// An `NSTextView` for the panel's source (editable) and result (read-only)
/// panes — AppKit rather than SwiftUI's `TextEditor` because the panel needs
/// three things `TextEditor` can't give it:
/// - Return submits and ⇧Return inserts a newline, decided through
///   `insertNewline:` — which an input method never sends while it's still
///   composing, so pressing Return to confirm a pinyin candidate doesn't
///   also start a translation.
/// - Esc hides the panel (`cancelOperation:`).
/// - ⌘C/⌘V/⌘X/⌘A/⌘Z work. OmniVoice is an accessory app whose panel never
///   activates it, so there is no active main menu for those key
///   equivalents to reach — the text view handles them itself.
struct PanelTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var placeholder: String = ""
    var fontSize: CGFloat = 14
    var textColor: NSColor = .labelColor
    /// Extra points between lines and after each paragraph — the result
    /// pane is read, not edited, and dense translated paragraphs need air.
    var lineSpacing: CGFloat = 0
    var paragraphSpacing: CGFloat = 0
    /// Bumped by the owner to move keyboard focus here, with the insertion
    /// point at the end — not a select-all, whose full-pane highlight over
    /// a long selection made the whole panel read as one dense block.
    var focusRequest: Int = 0
    /// Asks SwiftUI for exactly the text's own height (clamped by the
    /// caller's `.frame(maxHeight:)`) instead of taking whatever is offered
    /// — the source pane hugs short selections and leaves the rest of the
    /// panel to the result.
    var fitsContentHeight = false
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // The text view must never draw past the pane SwiftUI gave it — a
        // long source used to paint over the top of the result pane.
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true

        let textView = KeyHandlingTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? KeyHandlingTextView else { return }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        textView.font = attributes[.font] as? NSFont
        textView.typingAttributes = attributes
        // Only while the text actually differs — writing it back on every
        // update would reset the insertion point (and break an input
        // method's marked text) with each keystroke.
        if textView.string != text {
            let grewFromPrevious = !textView.string.isEmpty && text.hasPrefix(textView.string)
            textView.string = text
            // A result that's still filling in paragraph by paragraph stays
            // where the reader is; a new one starts from the top.
            if !isEditable, !grewFromPrevious { textView.scrollToBeginningOfDocument(nil) }
        }
        if let storage = textView.textStorage, storage.length > 0, !textView.hasMarkedText() {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        if context.coordinator.appliedFocusRequest != focusRequest {
            context.coordinator.appliedFocusRequest = focusRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    /// Never larger than SwiftUI's proposal: a representable that reports
    /// more than it's offered is laid out at its own size and overflows the
    /// `.frame` around it (centred, so both up over the header and down over
    /// the result pane) — which is exactly how a long source used to paint
    /// over the whole panel.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let offeredHeight = proposal.height ?? .greatestFiniteMagnitude
        guard fitsContentHeight, let textView = scrollView.documentView as? NSTextView else {
            return CGSize(width: width, height: proposal.height ?? 100)
        }
        // Measured on a copy of the text, not by re-laying out the live
        // text view's container mid-SwiftUI-layout.
        let inset = textView.textContainerInset
        let padding = textView.textContainer?.lineFragmentPadding ?? 5
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: textView.typingAttributes)
            .boundingRect(
                with: NSSize(width: max(width - inset.width * 2 - padding * 2, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        let height = ceil(measured.height + inset.height * 2) + 1
        return CGSize(width: width, height: min(height, offeredHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PanelTextView
        var appliedFocusRequest = 0

        init(_ parent: PanelTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

final class KeyHandlingTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var placeholder = "" {
        didSet { if oldValue != placeholder { needsDisplay = true } }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (key, flags.contains(.shift)) {
        case ("a", false): selectAll(nil)
        case ("c", false): copy(nil)
        case ("x", false) where isEditable: cut(nil)
        case ("v", false) where isEditable: pasteAsPlainText(nil)
        case ("z", false) where isEditable: undoManager?.undo()
        case ("z", true) where isEditable: undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Read-only (result) panes don't get `doCommandBy` for Esc.
    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
