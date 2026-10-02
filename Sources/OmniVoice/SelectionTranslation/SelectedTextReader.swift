import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

// Ported from Cida (https://github.com/Xuanwo/cida, Apache-2.0),
// `Sources/Cida/SelectedText.swift`.

/// What the frontmost application says about its selection.
enum SelectionAnswer: Equatable {
    /// The focused element's selection, trimmed.
    case selection(String)
    /// The focused element has nothing selected. The selection can still be
    /// somewhere else: Telegram Desktop keeps the focus in its message field
    /// while text in a message is selected. `elementText` is the text the
    /// element holds, nil when it does not say.
    case nothingSelected(elementText: String?)
    /// The application cannot say what is selected: it has no focused
    /// element, or its focused element does not offer `kAXSelectedText`.
    case unreadable(AXError)
    /// There is nothing to bring in and nothing to copy: a password field,
    /// this app itself, or no Accessibility permission.
    case withheld
}

/// Reads the text selected in the frontmost application for ⌥A: first
/// through the Accessibility API, then — for an app whose focused element
/// can't say (many Electron/web views) — by sending it ⌘C and reading the
/// pasteboard, which is put back the way it was afterwards.
///
/// Both paths need the Accessibility permission (reading another app's
/// AX tree, and posting a synthetic key event); without it `read()` returns
/// nil and the panel opens empty for the user to paste into.
@MainActor
enum SelectedTextReader {
    /// How long the whole AX exchange may take before the selection counts
    /// as empty — an app that doesn't answer must not hold the panel back.
    static let readDeadline: Duration = .milliseconds(150)

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's "allow Accessibility" prompt (once per launch at
    /// most, as macOS rate-limits it itself).
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func read() async -> String? {
        let answer = await answerWithinDeadline()
        let elementText: String?
        switch answer {
        case .selection(let selection):
            return selection
        case .withheld:
            return nil
        case .unreadable:
            elementText = nil
        case .nothingSelected(let text):
            elementText = text
        }
        let copied = await PasteboardSelectionCopier().copySelection()
        // With nothing selected, VS Code copies the line the cursor is on,
        // and that line is in the element's own text; a selection somewhere
        // else is not.
        let isElementLine = copied.map { elementText?.contains($0) ?? false } ?? false
        return isElementLine ? nil : copied
    }

    /// Trims the edges the way the source pane shows it; a selection of only
    /// whitespace is no selection.
    static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// A late answer is dropped.
    private static func answerWithinDeadline() async -> SelectionAnswer {
        await withCheckedContinuation { continuation in
            let isResumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (SelectionAnswer) -> Void = { answer in
                let isFirst = isResumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                if isFirst {
                    continuation.resume(returning: answer)
                }
            }
            Task { @MainActor in
                resume(await currentSelection())
            }
            Task {
                try? await Task.sleep(for: readDeadline)
                // Not `.withheld`: an app that is slow to answer (a big web
                // page building its accessibility tree) still has a
                // selection ⌘C can copy.
                resume(.unreadable(.cannotComplete))
            }
        }
    }

    private static func currentSelection() async -> SelectionAnswer {
        guard
            AXIsProcessTrusted(),
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return .withheld
        }
        let processIdentifier = application.processIdentifier
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(returning: AccessibilitySelection.read(of: processIdentifier))
            }
        }
    }
}

/// The Accessibility half of `SelectedTextReader`, run off the main thread.
private enum AccessibilitySelection {
    /// Each Accessibility message gets at most this long; the read deadline
    /// bounds the whole exchange.
    static let messagingTimeout: Float = 0.1

    static func read(of processIdentifier: pid_t) -> SelectionAnswer {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        // Electron applications build their accessibility tree only for
        // clients that ask for it; the first read after this may still find
        // nothing.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            application, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard focusedError == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .unreadable(focusedError)
        }
        let focused = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole) == .success,
           subrole as? String == kAXSecureTextFieldSubrole
        {
            return .withheld
        }
        var selected: CFTypeRef?
        switch AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selected) {
        case .success:
            guard let text = selected as? String else { return .unreadable(.illegalArgument) }
            if let selection = normalized(text) {
                return .selection(selection)
            }
            return .nothingSelected(elementText: heldText(of: focused))
        // The element has the attribute but nothing in it: nothing is selected.
        case .noValue:
            return .nothingSelected(elementText: heldText(of: focused))
        case let error:
            return .unreadable(error)
        }
    }

    /// `SelectedTextReader.normalized(_:)` is main-actor isolated; this runs
    /// on a background queue.
    private static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func heldText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

/// Sends ⌘C to the frontmost application and takes the text it copies, then
/// puts the pasteboard back the way it was.
@MainActor
struct PasteboardSelectionCopier {
    /// How long the application gets to copy before the selection counts as
    /// empty. An application with nothing to copy never writes, so ⌥A
    /// without a selection waits all of it; one that copies has written
    /// within 25 ms in Cida's measurements (TextEdit, Safari, Terminal,
    /// Chrome, Obsidian, Slack), and a later copy is still put back.
    var copyDeadline: Duration = .milliseconds(50)
    /// How long a copy that arrives after the deadline is still put back.
    var lateCopyWindow: Duration = .seconds(1)

    func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(of: pasteboard)
        let changeCount = pasteboard.changeCount
        guard CopyCommand.post() else { return nil }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: copyDeadline)
        // The application clears the pasteboard before it writes, so a
        // changed count with no types yet means the copy is still being
        // written.
        while pasteboard.changeCount == changeCount || pasteboard.types?.isEmpty != false, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard pasteboard.changeCount != changeCount else {
            putBackLateCopy(on: pasteboard, after: changeCount, restoring: snapshot)
            return nil
        }
        let text = Self.copiedText(on: pasteboard)
        snapshot.restore(to: pasteboard)
        return text
    }

    private static let sensitiveTypes: Set<NSPasteboard.PasteboardType> = [
        PasteboardSnapshot.transientType,
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    /// Only text counts: files copied in Finder also carry their names as
    /// text, and an image is not a selection to translate.
    static func copiedText(on pasteboard: NSPasteboard) -> String? {
        // Password managers mark what they copy so it isn't kept or shown
        // (http://nspasteboard.org); it must not reach the translator either.
        if let types = pasteboard.types, types.contains(where: sensitiveTypes.contains) { return nil }
        let copiesFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        guard !copiesFiles else { return nil }
        return SelectedTextReader.normalized(pasteboard.string(forType: .string))
    }

    /// A slow application may copy after the deadline. One change within
    /// the window is taken to be that copy and put back; any other count
    /// means someone else wrote to the pasteboard, and that is left alone.
    private func putBackLateCopy(on pasteboard: NSPasteboard, after changeCount: Int, restoring snapshot: PasteboardSnapshot) {
        let window = lateCopyWindow
        Task { @MainActor in
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: window)
            while pasteboard.changeCount == changeCount, clock.now < end {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard pasteboard.changeCount == changeCount + 1 else { return }
            snapshot.restore(to: pasteboard)
        }
    }
}

/// Every item on the pasteboard with the data of each of its types, so that
/// it can be written back unchanged.
@MainActor
struct PasteboardSnapshot {
    /// Tells clipboard managers not to record a write
    /// (http://nspasteboard.org): the contents put back are already in their
    /// history.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    init(of pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }
        restored[0].setData(Data(), forType: Self.transientType)
        pasteboard.writeObjects(restored)
    }
}

/// ⌘C as the frontmost application receives it from the keyboard.
@MainActor
enum CopyCommand {
    /// Posts ⌘C with only ⌘ held: the user is still holding the shortcut's
    /// ⌥, and ⌥⌘C is a different command (Finder's Copy as Pathname).
    /// Nothing is posted while secure input is on, when keystrokes are not
    /// meant to be seen or synthesized.
    static func post() -> Bool {
        guard !IsSecureEventInputEnabled() else { return false }
        let source = CGEventSource(stateID: .privateState)
        let keyCode = CGKeyCode(keyCode(typing: "c") ?? kVK_ANSI_C)
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

    /// The key that types `character` with ⌘ held in the current keyboard
    /// layout: C is not on the same key in Dvorak, and "Dvorak - QWERTY ⌘"
    /// moves it back only while ⌘ is down.
    private static func keyCode(typing character: Character) -> Int? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return layoutData.withUnsafeBytes { buffer -> Int? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return nil
            }
            for keyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDown), commandState,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, characters.count, &length, &characters
                )
                if status == noErr, length == 1, String(utf16CodeUnits: characters, count: 1) == String(character) {
                    return keyCode
                }
            }
            return nil
        }
    }
}
