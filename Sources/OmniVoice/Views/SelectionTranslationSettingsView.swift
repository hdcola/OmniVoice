import AppKit
import OmniVoiceCore
import SwiftUI

/// Settings' "快捷翻译" tab — reading aloud, the two-language direction
/// rule (see `SelectionLanguageDirection`; the languages are set in the
/// "语言" section of the "通用" tab) and engine. Permissions live in
/// `PermissionsSettingsSection`, the shortcuts in `ShortcutsSettingsSection`
/// (both on "通用").
struct SelectionTranslationSettingsView: View {
    @ObservedObject var controller: SelectionTranslationController
    @ObservedObject var translator: SelectionTranslator
    @ObservedObject var speaker: SelectionSpeaker
    /// Observed so the HY-MT1.5 option un-greys the moment its weights
    /// finish downloading in the "模型库" tab.
    @ObservedObject var downloadManager: ModelDownloadManager
    @EnvironmentObject private var navigation: SettingsNavigationState
    /// Observed so "跟随转录翻译引擎" re-resolves the moment the recording's
    /// translation engine changes in the "语音识别" tab.
    @EnvironmentObject private var session: RecordingSession

    var body: some View {
        Form {
            engineSection
            readAloudSection
        }
        .formStyle(.grouped)
    }

    private var readAloudSection: some View {
        Section(String(localized: "Read aloud")) {
            SettingsFormRow(
                title: "Read the translation aloud when done",
                subtitle: "You can also click ▶ at the top right of the source or translation at any time to read it aloud, using the macOS system voice"
            ) {
                Toggle("Read the translation aloud when done", isOn: $speaker.autoSpeakResult)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsFormRow(title: "Reading speed") {
                HStack(spacing: 8) {
                    Slider(value: $speaker.rate, in: SelectionSpeaker.rateRange)
                        .frame(width: 140)
                        .accessibilityLabel("Reading speed")
                    Text(String(format: "%.1f×", speaker.rate / SelectionSpeaker.defaultRate))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            SettingsFormRow(
                title: "Download more voices",
                subtitle: "For more natural voices or more languages: open it, then use the menu next to “System Voice” to download"
            ) {
                Button("Open Spoken Content Settings") { controller.openSpokenContentSettings() }
            }
        }
    }

    private var engineSection: some View {
        Section {
            SettingsFormRow(title: "Engine", subtitle: "Both options run on this Mac") {
                Picker("Quick Translate engine", selection: $translator.engineID) {
                    Text(followRecordingLabel).tag(SelectionTranslationEngine.followRecording)
                    Text(SelectionTranslationEngine.displayName(for: SelectionTranslationEngine.system))
                        .tag(SelectionTranslationEngine.system)
                }
                .labelsHidden()
                .accessibilityLabel("Quick Translate engine")
                .fixedSize()
            }
            if session.translationEngineID == "model.t3po",
               translator.engineID == SelectionTranslationEngine.followRecording {
                SettingsFormNote(text: String(localized: "T3PO, used for transcription, is designed for real-time speech and isn't suited to translating whole passages, so Quick Translate will use \(SelectionTranslationEngine.displayName(for: translator.effectiveEngineID)) instead."))
            }
            // 我的语言 / 外语 are set in the "语言" section (shared with the
            // recording and voice input); only this engine's caveat lives here.
            if let unsupported = unsupportedLanguageNames {
                SettingsFormNote(
                    text: String(localized: "HY-MT1.5 can currently only translate into Chinese, English, Japanese or Korean; translating into \(unsupported) will fail. Switch to System translation instead."),
                    tint: .orange
                )
            }
            if translator.effectiveEngineID == SelectionTranslationEngine.hymt15, !translator.isModelEngineAvailable {
                SettingsFormRow(title: "The HY-MT1.5 model hasn't been downloaded yet") {
                    Button("Go to Model Library") { navigation.openModelLibrary() }
                }
            }
        } header: {
            Text("Quick Translate engine")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("In the Translation panel: ⏎ translates, ⇧⏎ inserts a line break, Esc closes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                GeneralTabHint(topic: .shortcuts)
                GeneralTabHint(topic: .languages)
            }
        }
    }

    private var followRecordingLabel: String {
        String(localized: "Follow transcription translation engine (current: \(SelectionTranslationEngine.displayName(for: translator.followedEngineID)))")
    }

    private var unsupportedLanguageNames: String? {
        guard translator.effectiveEngineID == SelectionTranslationEngine.hymt15 else { return nil }
        let names = [translator.myLanguageCode, translator.foreignLanguageCode]
            .filter { !ModelLanguageMapping.isNativelyTranslatableByLocalModel(code: $0) }
            .map(LanguageCatalog.displayName(for:))
        // 我的语言 and 外语 can both be the same unsupported language.
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? nil : unique.joined(separator: String(localized: ", "))
    }
}
