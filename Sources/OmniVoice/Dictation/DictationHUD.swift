import AppKit
import OmniVoiceCore
import SwiftUI

/// The small non-activating bubble that shows a dictation is listening (and
/// what it has heard so far). Never takes focus — the text has to land in the
/// app the user is typing in — and ignores the mouse.
final class DictationHUDPanel: NSPanel {
    static let size = NSSize(width: 380, height: 72)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Bottom-center of the screen the pointer is on, above the Dock.
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: area.midX - Self.size.width / 2, y: area.minY + 80))
    }
}

struct DictationHUDView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var dictation: DictationSession

    var body: some View {
        HStack(spacing: 12) {
            // Fixed size so swapping icons doesn't shift the text.
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: DictationHUDPanel.size.width, height: DictationHUDPanel.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var icon: some View {
        if controller.notice != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if dictation.state == .listening {
            Image(systemName: "mic.fill").foregroundStyle(.red)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var headline: String {
        if controller.notice != nil { return "听写" }
        switch dictation.state {
        case .idle, .starting: return dictation.statusDetail ?? "准备中…"
        case .listening: return dictation.isUsingLocalModel ? "正在听写 · 本地模型" : "正在听写 · 系统识别"
        case .finishing: return "识别中…"
        }
    }

    private var detail: String {
        if let notice = controller.notice { return notice }
        if dictation.state == .listening, dictation.previewText.isEmpty { return "请说话" }
        return dictation.previewText
    }
}
