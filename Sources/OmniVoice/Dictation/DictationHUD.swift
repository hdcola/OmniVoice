import AppKit
import OmniVoiceCore
import SwiftUI

/// The small non-activating bubble that shows a dictation is listening (and
/// what it has heard so far). Never takes focus — the text has to land in the
/// app the user is typing in — and ignores the mouse, except while its text is
/// longer than it can show and wants the scroll wheel.
///
/// Its height follows the text (`setContentHeight`), growing upward from a
/// fixed bottom edge, up to `maxHeight`; beyond that the text scrolls.
final class DictationHUDPanel: NSPanel {
    /// The width, and the height of a one-line bubble.
    static let size = NSSize(width: 380, height: 72)

    /// The tallest the bubble gets before its text scrolls: half the screen,
    /// so it never covers the window the user is typing into.
    static var maxHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(size.height, (screenHeight / 2).rounded())
    }

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

    /// Resizes to `height`, keeping the bottom edge where it is. While the text
    /// scrolls the panel takes the mouse (the wheel); otherwise it stays
    /// click-through.
    func setContentHeight(_ height: CGFloat, isScrollable: Bool) {
        ignoresMouseEvents = !isScrollable
        guard abs(frame.height - height) > 0.5 else { return }
        var next = frame
        next.size.height = height
        setFrame(next, display: true)
    }

    /// Bottom-center of the screen the pointer is on, above the Dock.
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.minY + 80))
    }
}

/// Reports the height of the text inside the scroll view.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct DictationHUDView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var dictation: DictationSession
    /// Told the height the bubble wants and whether its text overflows, so the
    /// panel can follow.
    var onLayout: (CGFloat, Bool) -> Void = { _, _ in }

    @State private var contentHeight: CGFloat = 0

    private static let verticalPadding: CGFloat = 14
    private static let bottomID = "dictation-hud-bottom"

    private var height: CGFloat {
        min(max(contentHeight + 2 * Self.verticalPadding, DictationHUDPanel.size.height), DictationHUDPanel.maxHeight)
    }

    private var isScrollable: Bool {
        contentHeight + 2 * Self.verticalPadding > DictationHUDPanel.maxHeight + 0.5
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Fixed size so swapping icons doesn't shift the text.
            icon.frame(width: 22, height: 22)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: isScrollable) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear.frame(height: 0).id(Self.bottomID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) }
                    )
                }
                // What was just said is what matters while listening.
                .onChange(of: detail) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Self.verticalPadding)
        .frame(width: DictationHUDPanel.size.width, height: height, alignment: .center)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .onChange(of: height, initial: true) { _, _ in onLayout(height, isScrollable) }
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
        if dictation.state == .listening, dictation.previewText.isEmpty {
            return controller.mode == .toggle ? "请说话 · 按 Return 结束并发送" : "请说话"
        }
        return dictation.previewText
    }
}
