import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One global shortcut's row in Settings: its current combination as a
/// chip; clicking the chip records a new one. While recording, Escape (or
/// clicking elsewhere) cancels, ⌫/⌦ clears the shortcut, and a press
/// without ⌘/⌥/⌃ is refused with a hint.
struct ShortcutRecorderRow: View {
    @ObservedObject var controller: SelectionTranslationController
    let action: GlobalShortcutAction
    @State private var isRecording = false
    @State private var message: String?

    var body: some View {
        SettingsRow(title: action.title, subtitle: message ?? action.subtitle) {
            HStack(spacing: 8) {
                Button {
                    message = nil
                    isRecording.toggle()
                } label: {
                    Text(chipText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(isRecording ? Color.accentColor : .primary)
                        .frame(minWidth: 84)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isRecording ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .background(
                    ShortcutCaptureView(
                        isRecording: $isRecording,
                        onCapture: { shortcut in message = controller.setShortcut(shortcut, for: action) },
                        onInvalidPress: { message = "快捷键需要包含 ⌘、⌥ 或 ⌃" }
                    )
                )
                Button {
                    message = controller.setShortcut(action.defaultShortcut, for: action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("恢复默认")
                .disabled(controller.shortcuts[action] == action.defaultShortcut)
            }
        }
        .onChange(of: isRecording) { _, recording in
            controller.isRecordingShortcut = recording
        }
    }

    private var chipText: String {
        if isRecording { return "按下新快捷键…" }
        return controller.shortcuts[action]?.displayText ?? "未设置"
    }
}

// Ported from Cida (https://github.com/Xuanwo/cida, Apache-2.0),
// `Sources/Cida/ShortcutCaptureView.swift`.

/// Sits invisibly behind the shortcut chip and, while recording, holds the
/// window's first responder so the next key press becomes the shortcut.
struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (GlobalShortcut?) -> Void
    let onInvalidPress: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        ShortcutCaptureNSView()
    }

    func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
        view.onCapture = onCapture
        view.onInvalidPress = onInvalidPress
        view.onEnd = { isRecording = false }
        view.wantsKeyFocus = isRecording
    }
}

final class ShortcutCaptureNSView: NSView {
    var onCapture: (GlobalShortcut?) -> Void = { _ in }
    var onInvalidPress: () -> Void = {}
    var onEnd: () -> Void = {}

    /// Recording holds the keyboard. SwiftUI may set this before the view is
    /// in a window, so the view takes the focus again once it arrives in one.
    var wantsKeyFocus = false {
        didSet { applyKeyFocus() }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyKeyFocus()
    }

    private func applyKeyFocus() {
        guard let window else { return }
        if wantsKeyFocus {
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        } else if window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        record(event)
    }

    /// ⌘ combinations reach the window as key equivalents before any menu
    /// sees them, so the recorder claims them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        record(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        let onEnd = onEnd
        // The responder change can arrive inside a SwiftUI update; the
        // binding is written on the next turn of the run loop.
        DispatchQueue.main.async { onEnd() }
        return true
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Arrow and function keys carry .function even when no modifier is held.
        let isBare = flags.subtracting(.function).isEmpty
        if event.keyCode == UInt16(kVK_Escape), isBare {
            onEnd()
            return
        }
        if [UInt16(kVK_Delete), UInt16(kVK_ForwardDelete)].contains(event.keyCode), isBare {
            onCapture(nil)
            onEnd()
            return
        }
        guard let shortcut = GlobalShortcut(keyCode: event.keyCode, modifierFlags: flags) else {
            onInvalidPress()
            return
        }
        onCapture(shortcut)
        onEnd()
    }
}
