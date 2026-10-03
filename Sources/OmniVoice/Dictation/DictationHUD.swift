import AppKit
import OmniVoiceCore
import SwiftUI
import Translation

/// The small non-activating bubble that shows a dictation is listening (and
/// what it has heard so far). Never takes focus — the text has to land in the
/// app the user is typing in — and ignores the mouse unless it has buttons
/// to offer (`setInteractive`): a window either takes every click in its
/// frame or none, so it only takes them while it is the bubble itself.
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

    /// Whether the bubble takes the mouse — for its buttons. It never takes
    /// focus either way. Its frame is the bubble, so no clicks meant for the
    /// app underneath are lost beyond the bubble's own area.
    func setInteractive(_ interactive: Bool) {
        ignoresMouseEvents = !interactive
    }

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
    /// Its system-engine bridge lives here — a `TranslationSession` only
    /// exists inside a view (see `SelectionTranslator.systemTranslationConfiguration`).
    @ObservedObject var translator: SelectionTranslator
    /// Told the height the bubble wants, so the panel can follow.
    var onLayout: (CGFloat) -> Void = { _ in }

    @State private var headlineHeight: CGFloat = 0
    @State private var detailHeight: CGFloat = 0

    private static let verticalPadding: CGFloat = 14
    private static let spacing: CGFloat = 2

    private var review: DictationReview? { controller.review }

    /// The room the text gets under the headline, once the bubble is as tall
    /// as it goes.
    private var detailViewportHeight: CGFloat {
        let available = DictationHUDPanel.maxHeight - 2 * Self.verticalPadding - headlineHeight - Self.spacing
        return min(detailHeight, max(available, 0))
    }

    private var hasDetail: Bool { review != nil || !detail.isEmpty }

    private var height: CGFloat {
        let text = hasDetail ? Self.spacing + detailViewportHeight : 0
        return max(2 * Self.verticalPadding + headlineHeight + text, DictationHUDPanel.size.height)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let review {
            VStack(alignment: .leading, spacing: 8) {
                if let translation = review.translation {
                    Text(translation).font(.system(size: 13))
                }
                Text(review.original)
                    .font(.system(size: review.translation == nil ? 13 : 12))
                    .foregroundStyle(review.translation == nil ? .primary : .secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(detail)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Fixed size so swapping icons doesn't shift the text.
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: Self.spacing) {
                // Kept apart from the text so a long one can't push it away.
                HStack(alignment: .top, spacing: 8) {
                    Text(headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    headerButton
                }
                .background(
                    GeometryReader { Color.clear.preference(key: HeadlineHeightKey.self, value: $0.size.height) }
                )
                if hasDetail {
                    // An invisible copy of the text sizes the box (and measures
                    // the height the whole text needs). While listening, the
                    // visible one sits at the box's bottom edge, so when the
                    // text is taller the newest words stay in view and the
                    // oldest are clipped; a review scrolls instead, from its
                    // top.
                    detailContent
                        .hidden()
                        .background(
                            GeometryReader {
                                Color.clear.preference(key: DetailHeightKey.self, value: $0.size.height)
                            }
                        )
                        .frame(height: detailViewportHeight, alignment: .top)
                        .overlay(alignment: review == nil ? .bottomLeading : .topLeading) {
                            if review == nil {
                                detailContent
                            } else {
                                ScrollView(.vertical) { detailContent }
                            }
                        }
                        .clipped()
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
        .translationTask(translator.systemTranslationConfiguration) { session in
            await translator.runPendingSystemJob { text in
                try await session.translate(text).targetText
            }
        }
    }

    /// The quick translate switch while listening in 按一下开始 mode; "输入原文"
    /// once there is a translation to look at.
    @ViewBuilder
    private var headerButton: some View {
        if let review {
            if review.stage == .ready {
                Button("输入原文") { controller.confirmReview(send: false, useOriginal: true) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else if controller.notice == nil, dictation.state == .listening, controller.mode == .toggle {
            Toggle(isOn: $controller.translateEnabled) {
                Label("译成\(LanguageCatalog.displayName(for: translator.foreignLanguageCode))", systemImage: "character.bubble")
            }
            .toggleStyle(.button)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if controller.notice != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if let review {
            switch review.stage {
            case .translating: ProgressView().controlSize(.small)
            case .ready: Image(systemName: "character.bubble.fill").foregroundStyle(.tint)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } else if dictation.state == .listening {
            Image(systemName: "mic.fill").foregroundStyle(.red)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var headline: String {
        if controller.notice != nil { return "听写" }
        if let review {
            let trigger = controller.triggerKey.title
            switch review.stage {
            case .translating: return "翻译中… · Esc 放弃"
            case .ready: return "译文 · Return 输入并发送 · \(trigger) 仅输入 · Esc 放弃"
            case .failed(let message): return "\(message) · Return 输入原文并发送 · \(trigger) 仅输入 · Esc 放弃"
            }
        }
        switch dictation.state {
        case .idle, .starting: return dictation.statusDetail ?? "准备中…"
        case .listening: return dictation.isUsingLocalModel ? "正在听写 · 本地模型" : "正在听写 · 系统识别"
        case .finishing: return "识别中…"
        }
    }

    private var detail: String {
        if let notice = controller.notice { return notice }
        if dictation.state == .listening, dictation.previewText.isEmpty {
            guard controller.mode == .toggle else { return "请说话" }
            return controller.translateEnabled ? "请说话 · 按 Return 结束并翻译" : "请说话 · 按 Return 结束并发送"
        }
        return dictation.previewText
    }
}
