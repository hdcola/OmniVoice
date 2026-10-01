import AppKit
import Carbon.HIToolbox

// Ported from Cida (https://github.com/Xuanwo/cida, Apache-2.0),
// `Sources/Cida/GlobalShortcut.swift` — minus its command-line text form
// and menu key-equivalent helpers, which this app has no use for.

/// A key combination that works from any application. It always carries
/// ⌘, ⌥ or ⌃, so plain typing in another application can never trigger it.
struct GlobalShortcut: Equatable, Hashable, Codable {
    struct Modifiers: OptionSet, Hashable, Codable {
        let rawValue: UInt8

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
        /// At least one of these makes a combination a shortcut.
        static let required: Modifiers = [.control, .option, .command]

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        init(_ flags: NSEvent.ModifierFlags) {
            var modifiers = Modifiers()
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            self = modifiers
        }

        var carbonFlags: UInt32 {
            var flags: UInt32 = 0
            if contains(.control) { flags |= UInt32(controlKey) }
            if contains(.option) { flags |= UInt32(optionKey) }
            if contains(.shift) { flags |= UInt32(shiftKey) }
            if contains(.command) { flags |= UInt32(cmdKey) }
            return flags
        }

        /// In the order macOS prints them: ⌃ ⌥ ⇧ ⌘.
        var symbols: [String] {
            var symbols: [String] = []
            if contains(.control) { symbols.append("⌃") }
            if contains(.option) { symbols.append("⌥") }
            if contains(.shift) { symbols.append("⇧") }
            if contains(.command) { symbols.append("⌘") }
            return symbols
        }
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    static let optionA = GlobalShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: .option)
    static let optionS = GlobalShortcut(keyCode: UInt16(kVK_ANSI_S), modifiers: .option)

    init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The combination a key press describes, or nil when the press is a
    /// bare modifier or lacks ⌘, ⌥ and ⌃.
    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let modifiers = Modifiers(modifierFlags)
        guard !modifiers.isDisjoint(with: .required), !Self.modifierKeyCodes.contains(Int(keyCode)) else {
            return nil
        }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    /// Modifier symbols, then the key, one entry each — e.g. ["⌥", "A"].
    var displayTokens: [String] {
        modifiers.symbols + [keyDisplayName]
    }

    /// `displayTokens` joined by spaces, e.g. "⌥ A".
    var displayText: String {
        displayTokens.joined(separator: " ")
    }

    var keyDisplayName: String {
        if let name = Self.specialKeyNames[Int(keyCode)] {
            return name
        }
        return Self.character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    private static let modifierKeyCodes: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option,
        kVK_RightOption, kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖",
        kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "?",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11",
        kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
        kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// The unmodified character the current keyboard layout assigns to a key.
    private static func character(for keyCode: UInt16) -> String? {
        guard
            let inputSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
            return text.unicodeScalars.allSatisfy { $0.properties.isWhitespace || $0.value < 0x20 } ? nil : text
        }
    }
}

/// What a global shortcut does; each action has its own combination in
/// Settings, and no two actions may share one.
enum GlobalShortcutAction: String, CaseIterable, Identifiable {
    /// Shows or hides the selection translation panel, bringing in the
    /// frontmost app's selection.
    case translateSelection
    /// Freezes the screen, lets the user frame some text, and translates it.
    case captureText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translateSelection: return "划词翻译"
        case .captureText: return "截图翻译"
        }
    }

    var subtitle: String {
        switch self {
        case .translateSelection: return "翻译任意应用中选中的文字"
        case .captureText: return "框选屏幕上的文字并翻译"
        }
    }

    var defaultShortcut: GlobalShortcut {
        switch self {
        case .translateSelection: return .optionA
        case .captureText: return .optionS
        }
    }

    var defaultsKey: String { "org.omnivoice.selection.shortcut.\(rawValue)" }
}
