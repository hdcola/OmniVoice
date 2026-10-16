import SwiftUI
import OmniVoiceCore

/// The String(localized: "Voice input") card of Settings' String(localized: "Voice input") tab. Permissions live in
/// `PermissionsSettingsCard`.
struct DictationSettingsView: View {
    @ObservedObject var controller: DictationController
    @EnvironmentObject private var session: RecordingSession

    var body: some View {
        SettingsCard(title: String(localized: "Voice input"), icon: "waveform.badge.mic") {
            SettingsRow(
                title: String(localized: "Enable voice input"),
                subtitle: String(localized: "Hold the trigger key in any app and speak; the text is typed at the cursor when you release it. Requires Input Monitoring, Accessibility and Microphone permissions.")
            ) {
                Toggle("Enable voice input", isOn: $controller.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow(title: String(localized: "Trigger key"), subtitle: String(localized: "Pressing it alone types nothing; it does not trigger when pressed together with another key.")) {
                Picker("Trigger key", selection: $controller.triggerKey) {
                    ForEach(DictationTriggerKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Trigger key")
                .fixedSize()
            }
            .disabled(!controller.isEnabled || controller.dictation.isActive || controller.isPolishing || controller.review != nil)
            SettingsDivider()
            SettingsRow(title: String(localized: "Trigger mode")) {
                Picker("Trigger mode", selection: $controller.mode) {
                    Text("Hold to talk").tag(DictationTriggerMachine.Mode.hold)
                    Text("Press once to start, press again to stop").tag(DictationTriggerMachine.Mode.toggle)
                }
                .labelsHidden()
                .accessibilityLabel("Trigger mode")
                .fixedSize()
            }
            .disabled(!controller.isEnabled || controller.dictation.isActive || controller.isPolishing || controller.review != nil)
            SettingsDivider()
            SettingsRow(
                title: String(localized: "Translate to foreign language before typing (\(languageName(session.languages.foreignLanguageCode)))"),
                subtitle: controller.mode == .toggle
                    ? String(localized: "After you finish speaking, the translation is shown for confirmation: Return types and sends, the trigger key only types, Esc discards, and you can type the original instead. Uses the translation engine chosen in the Quick Translate tab; if you spoke the foreign language, it is typed directly. You can also toggle this at any time from the button on the bubble while dictating.")
                    : String(localized: "Set the trigger mode to “Press once to start, press again to stop” first — with Hold to talk there is no place to confirm the translation.")
            ) {
                Toggle("Translate to foreign language before typing", isOn: $controller.translateEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .disabled(!controller.isEnabled || controller.mode != .toggle)
            SettingsDivider()
            SettingsRow(
                title: String(localized: "Pause music during voice input"),
                subtitle: String(localized: "Pauses playing music or video when you start speaking and resumes it afterwards; only content paused by this feature is resumed.")
            ) {
                Toggle("Pause music during voice input", isOn: $controller.pauseMediaEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .disabled(!controller.isEnabled)
            SettingsDivider()
            DictationPolishSettingsRows(controller: controller)
            SettingsDivider()
            SettingsRow(
                title: String(localized: "Dictation language"),
                subtitle: String(localized: "The language to recognize; Auto-detect is only available when a local recognition model is loaded.")
            ) {
                Picker("Dictation language", selection: dictationLanguageSelection) {
                    Text("My language (\(languageName(session.languages.myLanguageCode)))").tag(DictationLanguageChoice.mine)
                    Text("Foreign language (\(languageName(session.languages.foreignLanguageCode)))").tag(DictationLanguageChoice.foreign)
                    Text(session.transcriptionEngineKind == .model ? String(localized: "Auto-detect") : String(localized: "Auto-detect (requires local model)"))
                        .tag(DictationLanguageChoice.auto)
                        .disabled(session.transcriptionEngineKind != .model)
                }
                .labelsHidden()
                .accessibilityLabel("Dictation language")
                .fixedSize()
            }
            .disabled(!controller.isEnabled || controller.dictation.isActive || controller.isPolishing || controller.review != nil)
            SettingsDivider()
            SettingsRow(
                title: String(localized: "Maximum duration per dictation"),
                subtitle: String(localized: "Ends automatically at this limit and types what was recognized, so the microphone is not left on if you forget to stop; raise it for long passages.")
            ) {
                Picker("Maximum duration per dictation", selection: $controller.maxDuration) {
                    ForEach(DictationMaxDuration.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Maximum duration per dictation")
                .fixedSize()
            }
            .disabled(!controller.isEnabled)
            if let warmup = controller.warmupMessage {
                SettingsDivider()
                SettingsNote(text: warmup)
            }
            SettingsDivider()
            SettingsNote(text: String(localized: "The recognition engine and microphone follow the Speech Recognition tab: if a local model is selected and loaded (turn on “Load model at launch” in the General tab), it is reused; otherwise System speech recognition is used, and also while recording captions. Press Esc to cancel; in “Press once to start” mode, press Return to finish and send with Return automatically. The clipboard is borrowed while typing and restored afterwards."))
        }
    }

    /// 自动检测 only works with a local model; elsewhere voice input uses
    /// 我的语言 (see `RecordingSession.dictationLanguageCode`), so show that —
    /// the stored choice is kept for when a local model is selected again.
    private var dictationLanguageSelection: Binding<DictationLanguageChoice> {
        Binding(
            get: {
                let choice = session.languages.dictationLanguage
                return choice == .auto && session.transcriptionEngineKind != .model ? .mine : choice
            },
            set: { session.languages.dictationLanguage = $0 }
        )
    }

    private func languageName(_ code: String) -> String {
        LanguageCatalog.displayName(for: code)
    }
}
