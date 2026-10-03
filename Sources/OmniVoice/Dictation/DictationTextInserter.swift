import AppKit
import Carbon.HIToolbox

/// Types dictated text into whatever app has the keyboard focus: put it on
/// the pasteboard, press ⌘V, and put the user's own clipboard back. Pasting
/// (rather than synthesizing key presses) is what keeps CJK text, emoji and
/// input-method-heavy apps working.
@MainActor
enum DictationTextInserter {
    enum Outcome: Equatable {
        case pasted
        /// Left on the pasteboard instead; the reason is for the user.
        case copiedOnly(String)
    }

    /// How long ⌘V gets to be read before the old pasteboard comes back.
    private static let pasteSettleDelay: Duration = .milliseconds(400)

    /// - Parameter thenReturn: press Return in the focused app once the text
    ///   has landed (never when it could only be copied).
    static func insert(_ text: String, thenReturn: Bool = false) async -> Outcome {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Keeps clipboard managers from filing every dictation as a copy.
        pasteboard.setData(Data(), forType: PasteboardSnapshot.transientType)
        let ownChangeCount = pasteboard.changeCount

        guard SelectedTextReader.isAccessibilityTrusted else {
            return .copiedOnly("需要「辅助功能」权限才能自动输入，文字已复制，可手动粘贴")
        }
        guard postPaste() else {
            return .copiedOnly("当前输入框不允许自动输入（如密码框），文字已复制，可手动粘贴")
        }
        try? await Task.sleep(for: pasteSettleDelay)
        if thenReturn { pressReturn() }
        // Something else copied in the meantime: that is the newer clipboard.
        if pasteboard.changeCount == ownChangeCount {
            snapshot.restore(to: pasteboard)
        }
        return .pasted
    }

    /// A bare Return, tagged so `DictationReturnInterceptor` lets it through.
    static func pressReturn() {
        guard !IsSecureEventInputEnabled() else { return }
        let source = CGEventSource(stateID: .privateState)
        source?.userData = DictationReturnInterceptor.ownEventMarker
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: keyDown)
            event?.flags = []
            event?.post(tap: .cgSessionEventTap)
        }
    }

    /// ⌘V with only ⌘ held — the event source is private, so a modifier the
    /// user is still physically holding doesn't leak into it. Nothing is
    /// posted while secure input is on.
    private static func postPaste() -> Bool {
        guard !IsSecureEventInputEnabled() else { return false }
        let source = CGEventSource(stateID: .privateState)
        let keyCode = CGKeyCode(CopyCommand.keyCode(typing: "v") ?? kVK_ANSI_V)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
