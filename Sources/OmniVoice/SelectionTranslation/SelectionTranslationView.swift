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
                        placeholder: String(localized: "Type or paste text to translate, then press ⏎"),
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
            .help("Close (Esc)")
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
            Button("Automatic (\(LanguageCatalog.localizedName(for: automaticTargetCode)))") {
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
        .help("Language to translate into. Default: My language is translated into the foreign language, any other language into My language.")
    }

    private var sourceLanguageLabel: String {
        guard translator.translatedSourceText != nil else { return String(localized: "Auto-detect") }
        guard let code = translator.detectedSourceCode else { return String(localized: "Not recognized") }
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
        return translator.engineID == SelectionTranslationEngine.followRecording ? String(localized: "Follow transcription · \(name)") : name
    }

    // MARK: - Notice

    @ViewBuilder
    private func noticeBanner(_ notice: SelectionTranslationController.Notice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            switch notice {
            case .accessibilityNeeded:
                Text("Accessibility permission is not granted, so selected text cannot be read automatically. Copy it with ⌘C first, then paste it above with ⌘V.")
                Spacer(minLength: 4)
                Button("Grant Access") { controller.openAccessibilitySettings() }
            case .screenRecordingNeeded:
                Text("Translate screenshot needs Screen Recording permission. After granting it, press the shortcut again.")
                Spacer(minLength: 4)
                Button("Grant Access") { controller.openScreenRecordingSettings() }
            case .nothingRecognized:
                Text("No text was recognized in the selected area.")
                Spacer(minLength: 4)
            case .captureFailed:
                Text("Capturing the screen failed. Please try again.")
                Spacer(minLength: 4)
            case .speechLanguageUnknown:
                Text("The language of this text could not be determined, so a voice for reading it aloud cannot be chosen.")
                Spacer(minLength: 4)
            case .voiceUnavailable(let language):
                Text("No reading voice is available for “\(language)”. Click “Get Language Pack” to open System Settings and download one from the menu next to “System Voice”.")
                Spacer(minLength: 4)
                Button("Get Language Pack") { controller.openSpokenContentSettings() }
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
        let name = target == .source ? String(localized: "Source text") : String(localized: "Translation")
        return Button {
            controller.speak(target)
        } label: {
            Image(systemName: isSpeaking ? "stop.circle" : "play.circle")
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .buttonStyle(.plain)
        // Stopping stays possible even if the source was emptied mid-reading.
        .disabled(!isSpeaking && (disabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        .help(isSpeaking ? String(localized: "Stop reading aloud") : String(localized: "Read \(name) aloud"))
        .accessibilityLabel(isSpeaking ? String(localized: "Stop reading aloud") : String(localized: "Read \(name) aloud"))
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
                Text("Loading HY-MT1.5 model…")
            }
            .foregroundStyle(.secondary)
        case .translating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Translating…")
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        case .idle, .completed:
            Text("The translation will appear here")
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
                Button("Stop") { translator.cancel() }
            }
            Button("Copy Translation") { copyResult() }
                .disabled(translator.resultText.isEmpty)
            Button("Translate") { translator.translate() }
                .disabled(translator.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var footerStatus: some View {
        if translator.isResultStale {
            Text("Source text changed · ⏎ to translate again")
        } else if case .failed(let message) = translator.phase, !translator.resultText.isEmpty {
            Text(message).foregroundStyle(.red)
        } else if translator.isBusy, !translator.resultText.isEmpty {
            Text("Translating…")
        } else {
            Text("⏎ Translate · ⇧⏎ New line · Esc Close")
        }
    }

    private func copyResult() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translator.resultText, forType: .string)
    }
}
