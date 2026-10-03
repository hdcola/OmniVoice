import AppKit
import OmniVoiceCore
import SwiftUI

/// The small non-activating bubble that shows a dictation is listening (and
/// what it has heard so far). Never takes focus — the text has to land in the
/// app the user is typing in — and ignores the mouse: a window either takes
/// every click in its frame or none, so it must not take any while it sits
/// over the user's work.
///
/// Its height follows the text (`setContentHeight`), growing upward from a
/// fixed bottom edge, up to `maxHeight`; beyond that the text shows its newest
/// words.
final class DictationHUDPanel: NSPanel {
    /// The width, and the height of a one-line bubble.
    static let size = NSSize(width: 380, height: 72)

    /// The tallest the bubble gets: half the height of the screen it was last
    /// shown on, so it never covers the window the user is typing into.
    private(set) static var maxHeight: CGFloat = size.height

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

    /// Resizes to `height`, keeping the bottom edge where it is.
    func setContentHeight(_ height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        var next = frame
        next.size.height = height
        setFrame(next, display: true)
    }

    /// Bottom-center of the screen the pointer is on, above the Dock, at the
    /// one-line height — a bubble that was tall last time must not flash up at
    /// that size before the new text shapes it.
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        Self.maxHeight = max(Self.size.height, (area.height / 2).rounded())
        setFrame(
            NSRect(
                x: area.midX - Self.size.width / 2, y: area.minY + 80,
                width: Self.size.width, height: Self.size.height),
            display: false
        )
    }
}

/// Reports the height of the headline.
private struct HeadlineHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Reports the height the whole detail text would take.
private struct DetailHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct DictationHUDView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var dictation: DictationSession
    /// Told the height the bubble wants, so the panel can follow.
    var onLayout: (CGFloat) -> Void = { _ in }

    @State private var headlineHeight: CGFloat = 0
    @State private var detailHeight: CGFloat = 0

    private static let verticalPadding: CGFloat = 14
    private static let spacing: CGFloat = 2
    private static let bottomID = "dictation-hud-bottom"

    /// The room the text gets under the headline, once the bubble is as tall
    /// as it goes.
    private var detailViewportHeight: CGFloat {
        let available = DictationHUDPanel.maxHeight - 2 * Self.verticalPadding - headlineHeight - Self.spacing
        return min(detailHeight, max(available, 0))
    }

    private var height: CGFloat {
        let text = detail.isEmpty ? 0 : Self.spacing + detailViewportHeight
        return max(2 * Self.verticalPadding + headlineHeight + text, DictationHUDPanel.size.height)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Fixed size so swapping icons doesn't shift the text.
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: Self.spacing) {
                // Outside the scroll view so a long text can't push it away.
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .background(
                        GeometryReader { Color.clear.preference(key: HeadlineHeightKey.self, value: $0.size.height) }
                    )
                if !detail.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(detail)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    GeometryReader {
                                        Color.clear.preference(key: DetailHeightKey.self, value: $0.size.height)
                                    }
                                )
                            Color.clear.frame(height: 0).id(Self.bottomID)
                        }
                        .frame(height: detailViewportHeight)
                        // What was just said is what matters while listening.
                        .onChange(of: detail, initial: true) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                        .onChange(of: detailHeight) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Self.verticalPadding)
        // Centered, so a one-line bubble doesn't hug the top of its minimum height.
        .frame(width: DictationHUDPanel.size.width, height: height, alignment: .center)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onPreferenceChange(HeadlineHeightKey.self) { headlineHeight = $0 }
        .onPreferenceChange(DetailHeightKey.self) { detailHeight = $0 }
        .onChange(of: height, initial: true) { _, _ in onLayout(height) }
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
