import AppKit
import OmniVoiceCore
import SwiftUI

/// Settings window — a pill-style `SettingsTabBar` over three tabs: "通用"
/// (permissions, then 快捷翻译, 实时转录 and 字幕悬浮窗 as stacked cards), "模型库" (the
/// full model catalog — the same content that used to be the standalone
/// "模型管理" window) and "关于". Data-driven from `ProviderCatalog` rather
/// than one hand-written `case` per engine, so adding a new community model
/// audio.cpp supports later is a catalog change, not a UI change.
/// One fixed window size for every tab (capped to the screen's height); the
/// long tabs scroll inside it.
enum SettingsWindowLayout {
    static let width: CGFloat = 520

    static var height: CGFloat {
        min(620, (NSScreen.main?.visibleFrame.height ?? 800) - 120)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: RecordingSession
    @EnvironmentObject private var navigation: SettingsNavigationState
    @EnvironmentObject private var selectionController: SelectionTranslationController
    @EnvironmentObject private var dictationController: DictationController
    @EnvironmentObject private var appDelegate: AppDelegate
    /// Read once at launch by `AppDelegate` — flipping it doesn't show/hide
    /// the panel right now, only decides whether it opens on the next start.
    @AppStorage(PersistedFloatingPanelKey.showOnLaunch) private var showFloatingPanelOnLaunch = true
    /// Observed directly (not just reached through `session`) so the engine
    /// picker's labels/inline download cards live-update the moment
    /// something is downloaded or deleted in the "模型库" tab —
    /// `RecordingSession` no longer triggers downloads itself and doesn't
    /// re-publish on every download tick, only on `statusMessage` changes.
    /// Passed in explicitly (not defaulted to `.shared`) and expected to be
    /// the exact same instance `session` was itself given — see
    /// `RecordingSession.init`'s own injectable `modelDownloadManager`
    /// parameter. Hardcoding `.shared` here instead would silently observe
    /// the wrong manager for any `RecordingSession` constructed with a
    /// non-`shared` one (a test, an eventual SwiftUI preview).
    @ObservedObject private var downloadManager: ModelDownloadManager
    @StateObject private var loginItem = LaunchAtLoginController()
    @AppStorage(PersistedLaunchKey.preloadMode) private var launchPreloadMode = LaunchPreloadMode.off
    @AppStorage(SystemNotifier.enabledKey) private var notificationsEnabled = true
    /// Task 4.3 (异常状态内联重试), mirroring `ModelManagementView`'s own —
    /// this tab's inline download row shows its own failure message rather
    /// than a modal `.alert`.
    @State private var inlineDownloadFailures: [String: String] = [:]
    /// Task 4.2 (下载前磁盘空间可视化预检) for the inline row.
    @State private var inlineDiskSpaceWarning: (variant: ModelVariant, error: ModelDownloadError)?

    init(modelDownloadManager: ModelDownloadManager) {
        self.downloadManager = modelDownloadManager
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $navigation.selectedTab)
                .padding(.top, 10)
                .padding(.bottom, 4)
            switch navigation.selectedTab {
            case .general: generalTab
            case .models: modelsTab
            case .about: aboutTab
            }
        }
        .frame(width: SettingsWindowLayout.width, height: SettingsWindowLayout.height)
    }

    // MARK: - Tab 1: 通用

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PermissionsSettingsCard(controller: selectionController)

                languageCard

                SelectionTranslationSettingsView(
                    controller: selectionController,
                    translator: selectionController.translator,
                    downloadManager: downloadManager
                )

                DictationSettingsView(controller: dictationController)

                transcriptionEngineCard
                translationEngineCard
                memoryConsole

                launchCard
                notificationCard

                panelCard

                onboardingCard
            }
            .padding(16)
            // `modelVariantPicker`/`inlineDownloadSection`/the "翻译提交策略"
            // row each insert or remove a row depending on the selected
            // engine; without this the card simply snaps to its new height
            // the instant either `Picker`'s selection changes. Keyed on the
            // two engine IDs (not every field in `session`) so unrelated
            // changes elsewhere — the memory status pill, say — don't also
            // animate.
            .animation(.easeInOut(duration: 0.2), value: session.transcriptionEngineID)
            .animation(.easeInOut(duration: 0.2), value: session.translationEngineID)
        }
    }

    private var transcriptionEngineCard: some View {
        SettingsCard(title: "识别引擎 (ASR)", icon: "waveform") {
            SettingsRow(title: "引擎") {
                Picker("识别引擎", selection: $session.transcriptionEngineID) {
                    // Every catalog engine is always listed, downloaded or
                    // not; an undownloaded `.model` engine is labeled rather
                    // than filtered out (see `engineLabel(for:)`), so it
                    // stays discoverable.
                    ForEach(ProviderCatalog.transcriptionEngines) { engine in
                        Text(engineLabel(for: engine)).tag(engine.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("识别引擎")
                .fixedSize()
                .disabled(isBusy)
            }
            modelVariantPicker(
                for: session.transcriptionEngineID,
                accessibilityName: "识别模型",
                selection: Binding(
                    get: { session.currentTranscriptionModelVariant?.id },
                    set: { session.transcriptionModelVariantID = $0 }
                )
            )
            .disabled(isBusy)
            // No bouncing to a separate window: an undownloaded `.model`
            // engine's download button/progress renders right here.
            inlineDownloadSection(forEngineID: session.transcriptionEngineID)
            // Only `.model` engines act on the pause boundary (system ASR
            // produces its own), so the VAD tuning is hidden for system engines.
            if session.transcriptionEngineKind == .model {
                SettingsDivider()
                SettingsRow(
                    title: "断句停顿时长",
                    subtitle: "说话后静音超过该时长就结束当前句；越长越不易被拆句，但出字更慢"
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $session.vadSilenceSeconds, in: 0.3...3.0, step: 0.1)
                            .frame(width: 140)
                            .accessibilityLabel("断句停顿时长")
                            .accessibilityValue(String(format: "%.1f 秒", session.vadSilenceSeconds))
                        Text(String(format: "%.1f 秒", session.vadSilenceSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "静音电平阈值",
                    subtitle: "低于该音量视为静音；麦克风音量小、轻声说话时调低（更负）"
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $session.vadSilenceDBFS, in: -70...(-20), step: 1)
                            .frame(width: 140)
                            .accessibilityLabel("静音电平阈值")
                            .accessibilityValue(String(format: "%.0f dB", session.vadSilenceDBFS))
                        Text(String(format: "%.0f dB", session.vadSilenceDBFS))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var translationEngineCard: some View {
        SettingsCard(title: "转录翻译引擎", icon: "character.bubble") {
            SettingsRow(title: "引擎") {
                Picker("转录翻译引擎", selection: $session.translationEngineID) {
                    ForEach(ProviderCatalog.translationEngines) { engine in
                        Text(engineLabel(for: engine)).tag(engine.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("转录翻译引擎")
                .fixedSize()
                .disabled(isBusy)
            }
            modelVariantPicker(
                for: session.translationEngineID,
                accessibilityName: "转录翻译模型",
                selection: Binding(
                    get: { session.currentTranslationModelVariant?.id },
                    set: { session.translationModelVariantID = $0 }
                )
            )
            .disabled(isBusy)
            inlineDownloadSection(forEngineID: session.translationEngineID)
            // T3PO is the only engine with a WAIT/TRANS decision to bias
            // (see `TranslationCommitEagerness`'s doc), so its picker stays
            // right here next to the engine choice it biases. Deliberately
            // *not* `.disabled(isBusy)` — safe to change mid-recording, same
            // as `targetLanguageCode`'s picker.
            if session.translationEngineID == "model.t3po" {
                SettingsDivider()
                SettingsRow(title: "翻译提交策略") {
                    Picker("翻译提交策略", selection: $session.translationCommitEagerness) {
                        ForEach(TranslationCommitEagerness.allCases, id: \.self) { eagerness in
                            Text(eagerness.displayName).tag(eagerness)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("翻译提交策略")
                    .fixedSize()
                }
            }
            SettingsDivider()
            translationOutputContent
        }
    }

    /// Row shown at the bottom of the translation card — the `TextField`
    /// when `translationEarlyTranslateThreshold` actually does something for
    /// the current engine pairing, otherwise a short explanation of why not.
    /// The card stays present (only this row's content swaps) so switching
    /// engines doesn't toggle a whole group in and out.
    @ViewBuilder
    private var translationOutputContent: some View {
        // Hidden outright under T3PO (has its own "翻译提交策略" picker
        // above) or the system ASR engine (a genuine no-op there — see
        // `TranslationConfig.earlyTranslateThreshold`'s doc:
        // `SystemTranscriptionProvider` never reports committed text via
        // `.appended` mid-utterance, so `translationProvider.feed(_:)` only
        // ever runs once per segment, immediately followed by `flush()` —
        // there's nothing "early" left to translate by then).
        if session.translationEngineID != "model.t3po", session.transcriptionEngineKind != .system {
            SettingsRow(
                title: "长句提前翻译阈值",
                subtitle: "数值越低出字越快，但长句更容易被拆成多段"
            ) {
                HStack(spacing: 6) {
                    // No range clamp here — `RecordingSession
                    // .translationEarlyTranslateThreshold`'s own `didSet`
                    // already clamps to 20...1000 and persists it.
                    TextField(
                        "长句提前翻译阈值",
                        value: $session.translationEarlyTranslateThreshold,
                        format: .number
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    Text("字").foregroundStyle(.secondary)
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .help(
                            "缓存的原文达到该字数的一半、且遇到句号/问号/换行等断句点时，会提前把已缓存内容翻译一次；"
                                + "达到完整阈值后，即使还没遇到断句点也会强制翻译，避免长句迟迟不出字。"
                                + "数值越低出字越快，但长句越容易被拆成更多段；数值越高单段更完整，但可能等得更久。"
                        )
                }
            }
        } else {
            SettingsNote(text: "当前引擎无需设置长句提前翻译阈值（仅对分段实时输出的翻译引擎有效）。")
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
                languagePicker("我的语言", selection: Binding(get: { session.languages.myLanguageCode }, set: { session.languages.myLanguageCode = $0 }), isSourceSide: !isListening)
            }
            SettingsDivider()
            SettingsRow(title: "外语", subtitle: "你要听、要读的外语；快捷翻译里「我的语言」的文字会译成它") {
                languagePicker("外语", selection: Binding(get: { session.languages.foreignLanguageCode }, set: { session.languages.foreignLanguageCode = $0 }), isSourceSide: isListening)
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
                        .disabled(isBusy)
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

    /// Under the system recognizer the source side can't be one of the
    /// languages it can't recognize — those stay offered on the other side,
    /// where they are only ever a translation target.
    private func languagePicker(_ title: String, selection: Binding<String>, isSourceSide: Bool) -> some View {
        let restricted = isSourceSide && session.transcriptionEngineKind == .system
        let options = restricted ? LanguageCatalog.common.filter(\.supportsSystemASRSource) : LanguageCatalog.common
        return Picker(title, selection: selection) {
            ForEach(options) { option in
                Text(option.displayName).tag(option.code)
            }
            if !options.contains(where: { $0.code == selection.wrappedValue }) {
                Text("\(selection.wrappedValue)（自定义）").tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .accessibilityLabel(title)
        .fixedSize()
        .disabled(isSourceSide && session.isSessionActive)
    }

    /// `isPreloadingModel` alongside `isSessionActive`: switching engines
    /// mid-preload would race `preloadModel()`'s in-flight `loadModel()`
    /// calls against `discardLoadedModelsIfStale()` unloading the very
    /// providers it's still awaiting.
    private var isBusy: Bool {
        session.isSessionActive || session.isPreloadingModel
    }

    /// Task 1.3 (引擎列表展示全部候选) — every catalog engine is always
    /// listed by the `Picker`s above regardless of download state; this
    /// only labels the undownloaded ones so they still read as "go get
    /// this" rather than "ready to use".
    private func hasDownloadedVariant(_ engine: EngineDescriptor) -> Bool {
        guard engine.kind == .model else { return true }
        return ProviderCatalog.modelVariants(forEngineID: engine.id)
            .contains { downloadManager.isDownloaded($0) }
    }

    private func engineLabel(for engine: EngineDescriptor) -> String {
        hasDownloadedVariant(engine) ? engine.displayName : "\(engine.displayName)（未下载 · 点击配置）"
    }

    /// Lists *downloaded* variants — plus the currently-selected one even if
    /// it isn't downloaded (deleted via "模型库", or a stale/synced
    /// selection), to avoid a blank `Picker` selection; marked "（未下载）"
    /// for the same reason `engineLabel(for:)` marks its engine-level
    /// equivalent.
    @ViewBuilder
    /// `accessibilityName` tells the ASR and translation pickers apart for
    /// VoiceOver and UI tests (their visible title is the same "模型").
    private func modelVariantPicker(
        for engineID: String, accessibilityName: String, selection: Binding<String?>
    ) -> some View {
        let variants = ProviderCatalog.modelVariants(forEngineID: engineID)
        let selectedID = selection.wrappedValue
        let shown = variants.filter { downloadManager.isDownloaded($0) || $0.id == selectedID }
        if !shown.isEmpty {
            SettingsDivider()
            SettingsRow(title: "模型") {
                Picker("模型", selection: selection) {
                    ForEach(shown) { variant in
                        Text(variantLabel(for: variant)).tag(Optional(variant.id))
                    }
                }
                .labelsHidden()
                .accessibilityLabel(accessibilityName)
                .fixedSize()
            }
        }
    }

    private func variantLabel(for variant: ModelVariant) -> String {
        downloadManager.isDownloaded(variant)
            ? "\(variant.displayName) · 约 \(variant.approximateSizeMB) MB"
            : "\(variant.displayName)（未下载）"
    }

    /// Task 3.2 — an undownloaded `.model` engine that's currently selected
    /// gets an inline download row per catalog variant, right below its
    /// `Picker`s, instead of only being reachable via "模型库". Each row
    /// mirrors the "模型库" tab's own download affordance (percent,
    /// progress bar, speed/ETA once available).
    @ViewBuilder
    private func inlineDownloadSection(forEngineID engineID: String) -> some View {
        if let engine = (ProviderCatalog.transcriptionEngines + ProviderCatalog.translationEngines)
            .first(where: { $0.id == engineID }), engine.kind == .model, !hasDownloadedVariant(engine) {
            SettingsDivider()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ProviderCatalog.modelVariants(forEngineID: engineID)) { variant in
                    inlineDownloadRow(for: variant)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func inlineDownloadRow(for variant: ModelVariant) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(variant.displayName).font(.callout)
                if downloadManager.isDownloading(variant) {
                    if let fraction = downloadManager.downloadProgress[variant.id] {
                        Text("下载中 \(Int((fraction * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: fraction)
                        if let stats = downloadManager.downloadStats[variant.id] {
                            Text(stats.summaryLine)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("准备下载…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView().progressViewStyle(.linear)
                    }
                } else if let message = inlineDownloadFailures[variant.id] {
                    Text("下载中断：\(message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                    HStack {
                        PillButton(title: "立即重试") { downloadInline(variant) }
                        if variant.downloadURL != nil {
                            PillButton(title: "复制下载链接") { copyDownloadLink(for: variant) }
                        }
                    }
                } else {
                    Text("约 \(variant.approximateSizeMB) MB · 尚未下载")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if downloadManager.isDownloading(variant) {
                PillButton(title: "取消") { downloadManager.cancelDownload(for: variant) }
            } else {
                PillButton(title: "下载并启用") { downloadInline(variant) }
            }
        }
        // Task 4.2 — same copy as `ModelManagementView`'s own disk-space
        // alert (Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.6.1).
        .alert(
            "磁盘空间不足",
            isPresented: Binding(
                get: { inlineDiskSpaceWarning?.variant.id == variant.id },
                set: { if !$0 { inlineDiskSpaceWarning = nil } }
            )
        ) {
            Button("打开存储空间管理") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                inlineDiskSpaceWarning = nil
            }
            Button("知道了", role: .cancel) { inlineDiskSpaceWarning = nil }
        } message: {
            if let inlineDiskSpaceWarning {
                Text("下载「\(inlineDiskSpaceWarning.variant.displayName)」\(inlineDiskSpaceWarning.error.errorDescription ?? "")。请清理磁盘空间后重试。")
            }
        }
    }

    private func copyDownloadLink(for variant: ModelVariant) {
        guard let downloadURL = variant.downloadURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(downloadURL.absoluteString, forType: .string)
    }

    /// Unlike "模型库"'s own download button, this one always applies
    /// the newly-downloaded variant to the engine/variant selection that's
    /// already active on this tab — the whole point of downloading inline
    /// is "I already picked this engine, just get me going", not a second
    /// implicit auto-activation decision the way `ModelManagementView`'s
    /// (which can be triggered for an engine that *isn't* currently
    /// selected) needs to make.
    private func downloadInline(_ variant: ModelVariant) {
        inlineDownloadFailures[variant.id] = nil
        // Task 4.2 — checked before the transfer starts, same as
        // `ModelManagementView.download(_:)`.
        if let warning = downloadManager.insufficientDiskSpaceWarning(for: variant) {
            inlineDiskSpaceWarning = (variant, warning)
            return
        }
        SystemNotifier.requestAuthorizationIfNeeded()
        Task {
            do {
                _ = try await downloadManager.ensureDownloaded(variant)
                if ProviderCatalog.transcriptionEngines.contains(where: { $0.id == variant.engineID }) {
                    session.transcriptionModelVariantID = variant.id
                } else {
                    session.translationModelVariantID = variant.id
                }
                SystemNotifier.notify(
                    title: "模型下载完成", body: "「\(variant.displayName)」已下载并自动启用")
            } catch is CancellationError {
                // The user's own "取消" tap — not a failure worth surfacing.
            } catch {
                // Task 4.3 — inline on this row, not just `statusMessage`.
                inlineDownloadFailures[variant.id] = error.localizedDescription
                SystemNotifier.notify(
                    title: "模型下载失败",
                    body: "「\(variant.displayName)」：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Memory & preload console (Task 3.3)

    /// Moves the floating panel's "预加载模型"/"模型已就绪" affordance
    /// (`FloatingTranscriptView.modelStatusControl`) into Settings, per
    /// Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.2.2 — same
    /// `session.preloadModel()`/`session.unloadModels()` calls, just a
    /// second, more discoverable entry point for users who keep the panel
    /// hidden. The section itself stays present even when nothing's
    /// preload-able (`!usesOnDeviceModelEngine`, a `.system`-only
    /// configuration) — round-5 user report: this whole section popping in
    /// and out was one of the two biggest jumps when switching engines, and
    /// swapping only its interior content (like `translationOutputContent`
    /// above) keeps the jump to the size of the content difference instead
    /// of a full section.
    private var memoryConsole: some View {
        SettingsCard(title: "引擎运行与内存状态", icon: "memorychip") {
            if session.usesOnDeviceModelEngine {
                SettingsRow(title: "模型状态", subtitle: "预计占用内存：约 \(estimatedMemoryGB) GB") {
                    StatusPill(text: memoryStatusText, tone: memoryStatusTone)
                }
                SettingsDivider()
                HStack {
                    Spacer()
                    PillButton(
                        title: "⚡ 预加载到内存",
                        isWorking: session.isPreloadingModel,
                        workingTitle: "加载中…"
                    ) {
                        Task { await session.preloadModel() }
                    }
                    .disabled(session.isSessionActive || session.isPreloadingModel || session.isModelLoaded)

                    PillButton(title: "🧹 释放内存占用") {
                        session.unloadModels()
                    }
                    .disabled(!session.hasLoadedModels || session.isSessionActive || session.isPreloadingModel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                SettingsNote(text: "当前引擎均为系统内置，无需预加载或释放内存。")
            }
        }
    }

    private var memoryStatusTone: StatusPill.Tone {
        if session.isPreloadingModel { return .warning }
        return session.hasLoadedModels ? .good : .neutral
    }

    private var memoryStatusText: String {
        if session.isPreloadingModel { return "正在加载中…" }
        if session.isModelLoaded { return "已载入内存（就绪）" }
        return session.hasLoadedModels ? "仅翻译模型已载入" : "空闲（未载入内存）"
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
                    ? "仅翻译约 \(translationMemoryGB) GB；翻译和识别约 \(estimatedMemoryGB) GB"
                    : "翻译模型约 \(translationMemoryGB) GB；识别为系统引擎，无需加载")
                : "翻译为系统引擎，「仅翻译模型」不会加载任何内容；识别模型约 \(estimatedMemoryGB) GB",
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
                    .disabled(isBusy)
            }
        }
    }

    private var translationMemoryGB: Int {
        guard session.translationEngineKind == .model,
            let variant = session.currentTranslationModelVariant
        else { return 0 }
        return variant.recommendedMemoryGB
    }

    /// Sum of `recommendedMemoryGB` for every currently-selected `.model`
    /// engine's active variant — an estimate, not a live measurement (no
    /// API here for actual RSS/VRAM), same spirit as §4.2.2's "预计占用统一
    /// 内存：12.4 GB (R2T2: 2.4GB + T3PO: 10.0GB)" line.
    private var estimatedMemoryGB: Int {
        var total = 0
        if session.transcriptionEngineKind == .model, let variant = session.currentTranscriptionModelVariant {
            total += variant.recommendedMemoryGB
        }
        if session.translationEngineKind == .model, let variant = session.currentTranslationModelVariant {
            total += variant.recommendedMemoryGB
        }
        return total
    }

    // MARK: - Tab 2: 模型库

    private var modelsTab: some View {
        ModelManagementView(modelDownloadManager: downloadManager)
    }

    // MARK: - 字幕悬浮窗

    /// Deliberately outside any `.disabled(isBusy)` — these only ever touch
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

    // MARK: - Tab 3: 关于

    private static let repositoryURL = URL(string: "https://github.com/hdcola/OmniVoice")!

    private var aboutTab: some View {
        // The content is vertically centered in the window; `minHeight`
        // keeps it that way while still letting a short window scroll.
        GeometryReader { proxy in
            ScrollView {
                aboutContent
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    private var aboutContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                Text("OmniVoice").font(.system(size: 24, weight: .bold))
                Text("v\(appVersionString)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("macOS 离线实时双语字幕、转录与快捷翻译")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)

            Link(destination: Self.repositoryURL) {
                VStack(spacing: 3) {
                    Text("⭐ 在 GitHub 点个 Star").font(.system(size: 14, weight: .semibold))
                    Text("如果 OmniVoice 对你有帮助，在 GitHub 点个 ⭐ 吧！")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.yellow.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            SettingsCard {
                aboutButton("查看新功能", icon: "sparkles") { appDelegate.showAllWhatsNew() }
                SettingsDivider()
                aboutLink("GitHub", icon: "chevron.left.forwardslash.chevron.right", url: Self.repositoryURL)
                SettingsDivider()
                aboutLink("版本发布", icon: "shippingbox", url: Self.repositoryURL.appendingPathComponent("releases"))
                SettingsDivider()
                aboutLink("反馈问题", icon: "exclamationmark.bubble", url: Self.repositoryURL.appendingPathComponent("issues"))
            }

            Text("系统引擎基于 macOS Speech / Translation 框架；本地引擎基于 audio.cpp（R2T2）与 llama.cpp（T3PO / HY-MT1.5），完全离线运行。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Text("Apache License 2.0")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private func aboutLink(_ title: String, icon: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                Text(title).font(.system(size: 13))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func aboutButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                Text(title).font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appVersionString: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(shortVersion) (\($0))" } ?? shortVersion
    }
}
