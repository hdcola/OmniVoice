import AppKit
import OmniVoiceCore
import SwiftUI

/// The "划词与截图翻译" and "快捷翻译引擎" cards of Settings' "快捷翻译" tab — shortcuts, the two-language
/// direction rule (see `SelectionLanguageDirection`; the languages are set in
/// the "语言" card of the "通用" tab) and engine. Permissions
/// live in `PermissionsSettingsCard`.
struct SelectionTranslationSettingsView: View {
    @ObservedObject var controller: SelectionTranslationController
    @ObservedObject var translator: SelectionTranslator
    @ObservedObject var speaker: SelectionSpeaker
    /// Observed so the HY-MT1.5 option un-greys the moment its weights
    /// finish downloading in the "模型库" tab.
    @ObservedObject var downloadManager: ModelDownloadManager
    @EnvironmentObject private var navigation: SettingsNavigationState
    /// Observed so "跟随转录设置" re-resolves the moment the recording's
    /// translation engine changes in the "语音识别" tab.
    @EnvironmentObject private var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            shortcutsCard
            engineCard
        }
    }

    private var shortcutsCard: some View {
        SettingsCard(title: "Translate selection and screenshot", icon: "keyboard") {
            ForEach(Array(GlobalShortcutAction.allCases.enumerated()), id: \.element.id) { index, action in
                if index > 0 { SettingsDivider() }
                ShortcutRecorderRow(controller: controller, action: action)
            }
            SettingsDivider()
            SettingsRow(
                title: "Translate on double ⌘C",
                subtitle: "After selecting text in another app, press ⌘C twice quickly to translate what you just copied; requires the “Input Monitoring” permission"
            ) {
                Toggle("Translate on double ⌘C", isOn: $controller.isDoubleCopyEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow(
                title: "Read the translation aloud when done",
                subtitle: "You can also click ▶ at the top right of the source or translation at any time to read it aloud, using the macOS system voice"
            ) {
                Toggle("Read the translation aloud when done", isOn: $speaker.autoSpeakResult)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow(title: "Reading speed") {
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
            SettingsDivider()
            SettingsRow(
                title: "Download more voices",
                subtitle: "For more natural voices or more languages: open it, then use the menu next to “System Voice” to download"
            ) {
                PillButton(title: "Open Spoken Content Settings") { controller.openSpokenContentSettings() }
            }
            SettingsDivider()
            SettingsNote(text: "In the Translation panel: ⏎ translates, ⇧⏎ inserts a line break, Esc closes.")
        }
    }

    private var engineCard: some View {
        SettingsCard(title: "Quick Translate engine", icon: "cpu") {
            SettingsRow(title: "Engine", subtitle: "Both options run on this Mac") {
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
                SettingsDivider()
                SettingsNote(text: String(localized: "T3PO, used for transcription, is designed for real-time speech and isn't suited to translating whole passages, so Quick Translate will use \(SelectionTranslationEngine.displayName(for: translator.effectiveEngineID)) instead."))
            }
            // 我的语言 / 外语 are set in the "语言" card (shared with the
            // recording and voice input); only this engine's caveat lives here.
            if let unsupported = unsupportedLanguageNames {
                SettingsDivider()
                SettingsNote(
                    text: String(localized: "HY-MT1.5 can currently only translate into Chinese, English, Japanese or Korean; translating into \(unsupported) will fail. Switch to System translation instead."),
                    tint: .orange
                )
            }
            if translator.effectiveEngineID == SelectionTranslationEngine.hymt15, !translator.isModelEngineAvailable {
                SettingsDivider()
                SettingsRow(title: "The HY-MT1.5 model hasn't been downloaded yet") {
                    PillButton(title: "Go to Model Library") { navigation.openModelLibrary() }
                }
            }
        }
    }

    private var followRecordingLabel: String {
        String(localized: "Follow transcription translation engine (\(SelectionTranslationEngine.displayName(for: translator.effectiveEngineID)))")
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
