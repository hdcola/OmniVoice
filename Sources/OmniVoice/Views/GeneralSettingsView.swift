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
        return SettingsCard(title: "语言", icon: "globe") {
            SettingsRow(title: "我的语言", subtitle: "你自己的语言：字幕和快捷翻译都会把外语译成它") {
                LanguagePicker("我的语言", selection: Binding(get: { session.languages.myLanguageCode }, set: { session.languages.myLanguageCode = $0 }), isSourceSide: !isListening)
            }
            SettingsDivider()
            SettingsRow(title: "外语", subtitle: "你要听、要读的外语；快捷翻译里「我的语言」的文字会译成它") {
                LanguagePicker("外语", selection: Binding(get: { session.languages.foreignLanguageCode }, set: { session.languages.foreignLanguageCode = $0 }), isSourceSide: isListening)
            }
            SettingsDivider()
            SettingsRow(
                title: "转录方向",
                subtitle: session.swapBlockedReason
                    ?? "听外语：字幕把外语译成我的语言；说我的语言：把我说的话译成外语。悬浮窗里的 ⇄ 也能切换",
                subtitleTint: session.swapBlockedReason == nil ? .secondary : .orange
            ) {
                Picker("转录方向", selection: Binding(
                    get: { languages.transcriptionDirection },
                    set: { if $0 != languages.transcriptionDirection { session.swapTranscriptionDirection() } }
                )) {
                    Text("听外语").tag(TranscriptionDirection.listenForeign)
                    Text("说我的语言").tag(TranscriptionDirection.speakMine)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel("转录方向")
                .fixedSize()
                .disabled(!session.canSwapTranscriptionDirection)
            }
            SettingsDivider()
            SettingsRow(
                title: "自动检测外语",
                subtitle: session.transcriptionEngineKind == .model
                    ? "听外语时由本地模型判断对方说的语种"
                    : "需要本地识别模型；系统语音识别必须指定语种"
            ) {
                Toggle("自动检测外语", isOn: Binding(get: { session.languages.foreignLanguageAutoDetect }, set: { session.languages.foreignLanguageAutoDetect = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(session.transcriptionEngineKind != .model || session.isSessionActive)
            }
            if let note = localTranslationLanguageNote {
                SettingsDivider()
                SettingsRow(title: "本地翻译模型可能回退为中文", subtitle: note) {
                    PillButton(title: "切换为系统翻译") { session.translationEngineID = "system.translation" }
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
        return "当前翻译引擎是本地模型，针对中、英、日、韩训练；翻译成「\(name)」可能会静默回退为中文。"
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
                    ? "仅翻译约 \(session.settingsTranslationMemoryGB) GB；翻译和识别约 \(session.settingsEstimatedMemoryGB) GB"
                    : "翻译模型约 \(session.settingsTranslationMemoryGB) GB；识别为系统引擎，无需加载")
                : "翻译为系统引擎，「仅翻译模型」不会加载任何内容；识别模型约 \(session.settingsEstimatedMemoryGB) GB",
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
        SettingsCard(title: "通知", icon: "bell") {
            SettingsRow(
                title: "完成时发送系统通知",
                subtitle: "模型下载完成或失败时，如果 OmniVoice 不在前台，用系统通知提醒"
            ) {
                Toggle("完成时发送系统通知", isOn: $notificationsEnabled)
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
        SettingsCard(title: "新手引导", icon: "sparkles") {
            SettingsRow(
                title: "重新运行引导",
                subtitle: "再次查看权限授权、运行模式和可选功能（如连按两次 ⌘C 翻译）；已有的设置和已下载的模型不会被清除"
            ) {
                PillButton(title: "重新运行") { appDelegate.showOnboarding() }
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
        SettingsCard(title: "字幕悬浮窗", icon: "macwindow") {
            SettingsRow(
                title: "启动时显示字幕悬浮窗",
                subtitle: "关闭后启动时不再自动弹出；开始转录时仍会显示，也可从菜单栏打开"
            ) {
                Toggle("启动时显示字幕悬浮窗", isOn: $showFloatingPanelOnLaunch)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            opacitySlider("背景透明度", value: $session.panelBackgroundOpacity, range: 0.1...1.0)
            SettingsDivider()
            // "内容透明度", not "文字透明度" — `panelContentOpacity` fades the
            // whole panel content stack (buttons/pickers/dividers/status bar
            // too), not just the transcript text.
            opacitySlider("内容透明度", value: $session.panelContentOpacity, range: 0.4...1.0)
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
