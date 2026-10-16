import AppKit
import OmniVoiceCore
import SwiftUI

/// Settings' "通用" tab — permissions, the shared 我的语言 / 外语 pair,
/// launch options, notifications, the floating subtitle panel and the
/// onboarding re-run.
struct GeneralSettingsView: View {
    @EnvironmentObject private var session: RecordingSession
    @EnvironmentObject private var selectionController: SelectionTranslationController
    @EnvironmentObject private var appDelegate: AppDelegate
    /// Read once at launch by `AppDelegate` — flipping it doesn't show/hide
    /// the panel right now, only decides whether it opens on the next start.
    @AppStorage(PersistedFloatingPanelKey.showOnLaunch) private var showFloatingPanelOnLaunch = true
    @StateObject private var loginItem = LaunchAtLoginController()
    @AppStorage(PersistedLaunchKey.preloadMode) private var launchPreloadMode = LaunchPreloadMode.off
    @AppStorage(SystemNotifier.enabledKey) private var notificationsEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PermissionsSettingsCard(controller: selectionController)

                languageCard

                launchCard
                notificationCard

                panelCard

                onboardingCard
            }
            .padding(16)
        }
    }

    /// 我的语言 / 外语 — the one pair of languages recording, 快捷翻译 and
    /// 语音输入 all share (see `LanguagePreferences`). The side that is
    /// currently the recognizer's source is locked while a recording runs.
    private var languageCard: some View {
        let languages = session.languages
        let isListening = languages.transcriptionDirection == .listenForeign
        return SettingsCard(title: String(localized: "Language"), icon: "globe") {
            SettingsRow(title: String(localized: "My language"), subtitle: String(localized: "Your own language: captions and Quick Translate translate foreign text into it")) {
                LanguagePicker(String(localized: "My language"), selection: Binding(get: { session.languages.myLanguageCode }, set: { session.languages.myLanguageCode = $0 }), isSourceSide: !isListening)
            }
            SettingsDivider()
            SettingsRow(title: String(localized: "Foreign language"), subtitle: String(localized: "The foreign language you listen to or read; in Quick Translate, text in your language is translated into it")) {
                LanguagePicker(String(localized: "Foreign language"), selection: Binding(get: { session.languages.foreignLanguageCode }, set: { session.languages.foreignLanguageCode = $0 }), isSourceSide: isListening)
            }
            SettingsDivider()
            SettingsRow(
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
            SettingsDivider()
            SettingsRow(
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
                SettingsDivider()
                SettingsRow(title: String(localized: "Local translation model may fall back to Chinese"), subtitle: note) {
                    PillButton(title: String(localized: "Switch to System translation")) { session.translationEngineID = "system.translation" }
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

    private var launchCard: some View {
        LaunchOptionsCard(
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

    private var notificationCard: some View {
        SettingsCard(title: String(localized: "Notifications"), icon: "bell") {
            SettingsRow(
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
    }

    private var onboardingCard: some View {
        SettingsCard(title: String(localized: "Onboarding"), icon: "sparkles") {
            SettingsRow(
                title: String(localized: "Re-run onboarding"),
                subtitle: String(localized: "Review permissions, run mode, and optional features (such as double ⌘C translate) again; your existing settings and downloaded models are kept")
            ) {
                PillButton(title: String(localized: "Re-run")) { appDelegate.showOnboarding() }
                    // Changing the run mode swaps engines, which Settings
                    // refuses mid-recording / while a model loads.
                    .disabled(session.isSettingsBusy)
            }
        }
    }

    // MARK: - 字幕悬浮窗

    /// Deliberately outside any `.disabled(session.isSettingsBusy)` — these only ever touch
    /// `FloatingTranscriptView`'s own SwiftUI opacity (see
    /// `panelBackgroundOpacity`/`panelContentOpacity`'s docs), never
    /// anything `start()` reads once at setup time, so there's no race to
    /// guard against; adjusting either while recording (to see through the
    /// panel at whatever's behind it, without losing legibility) is exactly
    /// when they're most useful. Two separate sliders, not one — a single
    /// shared value (an earlier version of this had exactly that, driving
    /// `NSWindow.alphaValue`) faded the transcript text right along with the
    /// background, so a panel transparent enough to not block the view
    /// behind it also made the text hard to read.
    private var panelCard: some View {
        SettingsCard(title: String(localized: "Caption panel"), icon: "macwindow") {
            SettingsRow(
                title: String(localized: "Show the Caption panel at launch"),
                subtitle: String(localized: "When off, it no longer appears automatically at launch; it still shows when live transcription starts, and can be opened from the Menu bar")
            ) {
                Toggle("Show the Caption panel at launch", isOn: $showFloatingPanelOnLaunch)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            opacitySlider(String(localized: "Background opacity"), value: $session.panelBackgroundOpacity, range: 0.1...1.0)
            SettingsDivider()
            // "内容透明度", not "文字透明度" — `panelContentOpacity` fades the
            // whole panel content stack (buttons/pickers/dividers/status bar
            // too), not just the transcript text.
            opacitySlider(String(localized: "Content opacity"), value: $session.panelContentOpacity, range: 0.4...1.0)
        }
    }

    private func opacitySlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        SettingsRow(title: label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range)
                    .frame(width: 180)
                // `.rounded()`, not a bare `Int(...)` truncation — a
                // `Slider`'s underlying `Double` can land a hair under a
                // "clean" percentage from binary floating-point rounding
                // (e.g. 0.29999999999999994 for what's visually 0.3), which
                // truncation reads as 29% — jittery/off-by-one against where
                // the thumb actually looks.
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
