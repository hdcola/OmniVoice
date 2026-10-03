import AppKit
import OmniVoiceCore
import SwiftUI
import Translation

/// Content of `SelectionTranslationPanel`: a language-direction header, the
/// editable source pane, the result pane, and a footer with status and
/// actions.
///
/// Also hosts the `.translationTask` for `SelectionTranslator`'s system
/// engine — see `SelectionTranslator.systemTranslationConfiguration`'s doc.
/// The panel (and so this view) is created once by
/// `SelectionTranslationController` and only ever hidden/shown, so the task
/// stays mounted for the app's lifetime, same reasoning as
/// `FloatingTranscriptView`'s bridge.
struct SelectionTranslationView: View {
    @ObservedObject var controller: SelectionTranslationController
    @ObservedObject var translator: SelectionTranslator
    @ObservedObject var speaker: SelectionSpeaker

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 8) {
                // Capped at roughly five lines: the source is context, the
                // translation is what's being read, so a long selection
                // scrolls inside its own card instead of crowding out the
                // result.
                HStack(alignment: .top, spacing: 0) {
                    PanelTextView(
                        text: $translator.sourceText,
                        isEditable: true,
                        placeholder: "输入或粘贴要翻译的文字，按 ⏎ 翻译",
                        fontSize: 13,
                        textColor: .secondaryLabelColor,
                        lineSpacing: 2,
                        focusRequest: controller.sourceFocusRequest,
                        fitsContentHeight: true,
                        onSubmit: { translator.translate() },
                        onCancel: { controller.hidePanel() }
                    )
                    .frame(minHeight: 44, maxHeight: 110)
                    speakButton(.source, text: translator.sourceText)
                }
                .clipped()
                .background(paneBackground)
                if let notice = controller.notice {
                    noticeBanner(notice)
                }
                HStack(alignment: .top, spacing: 0) {
                    resultPane
                    speakButton(.result, text: translator.resultText, disabled: translator.isBusy)
                }
                .clipped()
                .background(paneBackground)
            }
            .padding(.horizontal, 12)
            footer
        }
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // The panel's (hidden) title bar would otherwise push everything
        // down, leaving an empty band above the header.
        .ignoresSafeArea()
        .translationTask(translator.systemTranslationConfiguration) { session in
            await translator.runPendingSystemJob { text in
                try await session.translate(text).targetText
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .foregroundStyle(.secondary)
            Text(sourceLanguageLabel)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            targetMenu
            Spacer()
            Text(engineName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                controller.hidePanel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Picks a target for this selection only — `SelectionTranslator.load(_:)`
    /// goes back to the automatic direction for the next one.
    private var targetMenu: some View {
        Menu {
            Button("自动（\(LanguageCatalog.localizedName(for: automaticTargetCode))）") {
                translator.targetOverrideCode = nil
                translator.translate()
            }
            Divider()
            ForEach(LanguageCatalog.common) { option in
                Button(option.displayName) {
                    translator.targetOverrideCode = option.code
                    translator.translate()
                }
            }
        } label: {
            Text(LanguageCatalog.localizedName(for: translator.targetCode))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("译成哪种语言。默认：我的语言译成外语，其他语言译成我的语言")
    }

    private var sourceLanguageLabel: String {
        guard translator.translatedSourceText != nil else { return "自动检测" }
        guard let code = translator.detectedSourceCode else { return "未能识别" }
        return LanguageCatalog.localizedName(for: code)
    }

    /// What the automatic direction would pick for the current source text.
    private var automaticTargetCode: String {
        SelectionLanguageDirection.targetCode(
            forDetected: translator.detectedSourceCode,
            myLanguageCode: translator.myLanguageCode,
            foreignLanguageCode: translator.foreignLanguageCode
        )
    }

    private var engineName: String {
        let name = SelectionTranslationEngine.displayName(for: translator.effectiveEngineID)
        return translator.engineID == SelectionTranslationEngine.followRecording ? "跟随转录 · \(name)" : name
    }

    // MARK: - Notice

    @ViewBuilder
    private func noticeBanner(_ notice: SelectionTranslationController.Notice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            switch notice {
            case .accessibilityNeeded:
                Text("未授予「辅助功能」权限，无法自动读取选中的文字。可先 ⌘C 复制，再在上方 ⌘V 粘贴。")
                Spacer(minLength: 4)
                Button("去授权") { controller.openAccessibilitySettings() }
            case .screenRecordingNeeded:
                Text("截图翻译需要「屏幕录制」权限。授权后请重新按一次快捷键。")
                Spacer(minLength: 4)
                Button("去授权") { controller.openScreenRecordingSettings() }
            case .nothingRecognized:
                Text("框选的区域里没有识别出文字。")
                Spacer(minLength: 4)
            case .captureFailed:
                Text("截取屏幕失败，请重试。")
                Spacer(minLength: 4)
            case .speechLanguageUnknown:
                Text("无法判断这段文字的语言，没法选择朗读语音。")
                Spacer(minLength: 4)
            case .voiceUnavailable(let language):
                Text("没有可用的「\(language)」朗读语音。可在 系统设置 → 辅助功能 → 朗读内容 里下载。")
                Spacer(minLength: 4)
                Button("去下载") { controller.openSpokenContentSettings() }
            }
            Button {
                controller.dismissNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Speech

    private func speakButton(_ target: SelectionSpeaker.Target, text: String, disabled: Bool = false) -> some View {
        let isSpeaking = speaker.speaking == target
        let name = target == .source ? "原文" : "译文"
        return Button {
            controller.speak(target)
        } label: {
            Image(systemName: isSpeaking ? "stop.circle" : "play.circle")
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .buttonStyle(.plain)
        .disabled(disabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help(isSpeaking ? "停止朗读" : "朗读\(name)")
        .accessibilityLabel(isSpeaking ? "停止朗读" : "朗读\(name)")
    }

    // MARK: - Result

    @ViewBuilder
    private var resultPane: some View {
        ZStack(alignment: .topLeading) {
            PanelTextView(
                text: .constant(translator.resultText),
                isEditable: false,
                fontSize: 15,
                lineSpacing: 4,
                paragraphSpacing: 6,
                onCancel: { controller.hidePanel() }
            )
            .opacity(translator.isResultStale ? 0.55 : 1)
            if translator.resultText.isEmpty {
                resultPlaceholder
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 90, maxHeight: .infinity)
    }

    private var paneBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.05))
    }

    @ViewBuilder
    private var resultPlaceholder: some View {
        switch translator.phase {
        case .loadingModel:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在加载 HY-MT1.5 模型…")
            }
            .foregroundStyle(.secondary)
        case .translating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("翻译中…")
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        case .idle, .completed:
            Text("译文会显示在这里")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            footerStatus
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if translator.isBusy {
                Button("停止") { translator.cancel() }
            }
            Button("复制译文") { copyResult() }
                .disabled(translator.resultText.isEmpty)
            Button("翻译") { translator.translate() }
                .disabled(translator.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var footerStatus: some View {
        if translator.isResultStale {
            Text("原文已修改 · ⏎ 重新翻译")
        } else if case .failed(let message) = translator.phase, !translator.resultText.isEmpty {
            Text(message).foregroundStyle(.red)
        } else if translator.isBusy, !translator.resultText.isEmpty {
            Text("翻译中…")
        } else {
            Text("⏎ 翻译 · ⇧⏎ 换行 · Esc 关闭")
        }
    }

    private func copyResult() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translator.resultText, forType: .string)
    }
}
