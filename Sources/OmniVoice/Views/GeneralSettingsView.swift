import AppKit
import OmniVoiceCore
import SwiftUI

/// Settings' "通用" tab — permissions, the shared 我的语言 / 外语 pair,
/// launch and notifications (with the interface language), the onboarding
/// re-run and every keyboard shortcut. The 字幕悬浮窗 group lives on
/// "语音识别", next to the transcription it affects.
struct GeneralSettingsView: View {
    @EnvironmentObject private var session: RecordingSession
    @EnvironmentObject private var selectionController: SelectionTranslationController
    @EnvironmentObject private var dictationController: DictationController
    @EnvironmentObject private var appDelegate: AppDelegate
    @StateObject private var loginItem = LaunchAtLoginController()
    @AppStorage(PersistedLaunchKey.preloadMode) private var launchPreloadMode = LaunchPreloadMode.off
    @AppStorage(SystemNotifier.enabledKey) private var notificationsEnabled = true
    @State private var interfaceLanguage = AppLanguage.stored()

    var body: some View {
        Form {
            PermissionsSettingsSection(controller: selectionController)
            languageSection
            launchSection
            onboardingSection
            ShortcutsSettingsSection(selectionController: selectionController, dictationController: dictationController)
        }
        .formStyle(.grouped)
    }

    /// 界面语言 — the app's own UI language. Resolved once at launch (see
    /// `AppLanguage`), so a change only shows after a restart.
    private var interfaceLanguageRow: some View {
        let needsRestart = AppLanguage.needsRestart(stored: interfaceLanguage)
        return SettingsFormRow(
            title: String(localized: "Interface language"),
            subtitle: needsRestart
                ? String(localized: "Restart OmniVoice to apply the new language.")
                : String(localized: "Language of menus and windows. Takes effect after restarting OmniVoice."),
            subtitleTint: needsRestart ? .orange : .secondary
        ) {
            HStack(spacing: 8) {
                if needsRestart && AppRelauncher.canRelaunch {
                    Button("Restart Now") { AppRelauncher.relaunch() }
                }
                Picker("Interface language", selection: Binding(
                    get: { interfaceLanguage },
                    set: { interfaceLanguage = $0; AppLanguage.store($0) }
                )) {
                    Text("Follow system").tag(AppLanguage.system)
                    // Each language is named in itself, so it stays readable
                    // when the UI is in the other one.
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                }
                .labelsHidden()
                .accessibilityLabel("Interface language")
                .fixedSize()
            }
        }
    }

    /// 我的语言 / 外语 — the one pair of languages recording, 快捷翻译 and
    /// 语音输入 all share (see `LanguagePreferences`). The side that is
    /// currently the recognizer's source is locked while a recording runs.
    private var languageSection: some View {
        let languages = session.languages
        let isListening = languages.transcriptionDirection == .listenForeign
        return Section(String(localized: "Language")) {
            SettingsFormRow(title: String(localized: "My language"), subtitle: String(localized: "Your own language: captions and Quick Translate translate foreign text into it")) {
                LanguagePicker(String(localized: "My language"), selection: Binding(get: { session.languages.myLanguageCode }, set: { session.languages.myLanguageCode = $0 }), isSourceSide: !isListening)
            }
            SettingsFormRow(title: String(localized: "Foreign language"), subtitle: String(localized: "The foreign language you listen to or read; in Quick Translate, text in your language is translated into it")) {
                LanguagePicker(String(localized: "Foreign language"), selection: Binding(get: { session.languages.foreignLanguageCode }, set: { session.languages.foreignLanguageCode = $0 }), isSourceSide: isListening)
            }
            SettingsFormRow(
                title: String(localized: "Transcription direction"),
                subtitle: session.swapBlockedReason
                    ?? String(localized: "Listen to foreign: captions translate foreign speech into my language; Speak my language: what I say is translated into the foreign language. The ⇄ in the Caption panel also switches it"),
                subtitleTint: session.swapBlockedReason == nil ? .secondary : .orange
            ) {
                Picker("Transcription direction", selection: Binding(
                    get: { languages.transcriptionDirection },
                    set: { if $0 != languages.transcriptionDirection { session.swapTranscriptionDirection() } }
                )) {
                    Text("Listen to foreign").tag(TranscriptionDirection.listenForeign)
                    Text("Speak my language").tag(TranscriptionDirection.speakMine)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel("Transcription direction")
                .fixedSize()
                .disabled(!session.canSwapTranscriptionDirection)
            }
            SettingsFormRow(
                title: String(localized: "Auto-detect foreign language"),
                subtitle: session.transcriptionEngineKind == .model
                    ? String(localized: "When listening to foreign speech, the local model detects the language being spoken")
                    : String(localized: "Requires a local recognition model; System speech recognition needs a fixed language")
            ) {
                Toggle("Auto-detect foreign language", isOn: Binding(get: { session.languages.foreignLanguageAutoDetect }, set: { session.languages.foreignLanguageAutoDetect = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(session.transcriptionEngineKind != .model || session.isSessionActive)
            }
            if let note = localTranslationLanguageNote {
                    SettingsFormRow(title: String(localized: "Local translation model may fall back to Chinese"), subtitle: note, subtitleTint: .orange) {
                    Button("Switch to System translation") { session.translationEngineID = "system.translation" }
                        .disabled(session.isSettingsBusy)
                }
            }
        }
    }

    /// The local translation models are trained for 中/英/日/韩 only and fall
    /// back to Chinese for any other target (see `ModelLanguageMapping`).
    private var localTranslationLanguageNote: String? {
        guard session.translationEngineKind == .model,
              !ModelLanguageMapping.isNativelyTranslatableByLocalModel(code: session.targetLanguageCode)
        else { return nil }
        let name = LanguageCatalog.displayName(for: session.targetLanguageCode)
        return String(localized: "The current translation engine is a local model trained for Chinese, English, Japanese, and Korean; translating into “\(name)” may silently fall back to Chinese.")
    }

    // MARK: - 启动

    /// Launch, notifications and the interface language — the settings that
    /// are about the app itself rather than any one feature.
    private var launchSection: some View {
        Section(String(localized: "Launch and notifications")) {
            launchRows
            notificationRow
            interfaceLanguageRow
        }
    }

    private var launchRows: some View {
        LaunchOptionsRows(
            launchAtLogin: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }),
            preloadMode: $launchPreloadMode,
            needsLoginApproval: loginItem.needsApproval,
            loginError: loginItem.lastError,
            preloadAvailable: session.usesOnDeviceModelEngine,
            memoryNote: session.translationEngineKind == .model
                ? (session.transcriptionEngineKind == .model
                    ? String(localized: "Translation only: about \(session.settingsTranslationMemoryGB) GB; translation and recognition: about \(session.settingsEstimatedMemoryGB) GB")
                    : String(localized: "Translation model: about \(session.settingsTranslationMemoryGB) GB; recognition uses the system engine, nothing to load"))
                : String(localized: "Translation uses the system engine, so “Translation model only” loads nothing; the recognition model is about \(session.settingsEstimatedMemoryGB) GB"),
            translationOnlyAvailable: session.translationEngineKind == .model,
            onOpenLoginItems: { loginItem.openLoginItemsSettings() }
        )
        .onAppear { loginItem.refresh() }
        // Coming back from System Settings → 登录项 (this view stays on
        // screen the whole time, so `onAppear` doesn't fire again).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var notificationRow: some View {
        SettingsFormRow(
            title: String(localized: "Send a system notification when finished"),
            subtitle: String(localized: "When a model download finishes or fails while OmniVoice is in the background, notify you with a system notification")
        ) {
            Toggle("Send a system notification when finished", isOn: $notificationsEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: notificationsEnabled) { _, enabled in
                    if enabled { SystemNotifier.requestAuthorizationIfNeeded() }
                }
        }
    }

    private var onboardingSection: some View {
        Section(String(localized: "Onboarding")) {
            SettingsFormRow(
                title: String(localized: "Re-run onboarding"),
                subtitle: String(localized: "Review permissions, models, and optional features (such as double ⌘C translate) again; your existing settings and downloaded models are kept")
            ) {
                Button("Re-run") { appDelegate.showOnboarding() }
                    // Changing the models swaps engines, which Settings
                    // refuses mid-recording / while a model loads.
                    .disabled(session.isSettingsBusy)
            }
        }
    }
}
