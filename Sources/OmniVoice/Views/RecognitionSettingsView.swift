import AppKit
import OmniVoiceCore
import SwiftUI

/// Settings' "语音识别" tab — the recognition engine (with VAD tuning), the
/// transcription-translation engine and the engine memory console, with the
/// inline download rows that go with an undownloaded engine.
struct RecognitionSettingsView: View {
    @EnvironmentObject private var session: RecordingSession
    /// Observed directly (not just reached through `session`) so the engine
    /// picker's labels/inline download cards live-update the moment
    /// something is downloaded or deleted in the "模型库" tab —
    /// `RecordingSession` no longer triggers downloads itself and doesn't
    /// re-publish on every download tick, only on `statusMessage` changes.
    /// Passed in explicitly (not defaulted to `.shared`) and expected to be
    /// the exact same instance `session` was itself given.
    @ObservedObject private var downloadManager: ModelDownloadManager
    /// Task 4.3 (异常状态内联重试), mirroring `ModelManagementView`'s own —
    /// the inline download row shows its own failure message rather than a
    /// modal `.alert`.
    @State private var inlineDownloadFailures: [String: String] = [:]
    /// Task 4.2 (下载前磁盘空间可视化预检) for the inline row.
    @State private var inlineDiskSpaceWarning: (variant: ModelVariant, error: ModelDownloadError)?

    init(modelDownloadManager: ModelDownloadManager) {
        self.downloadManager = modelDownloadManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                transcriptionEngineCard
                translationEngineCard
                memoryConsole
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
                .disabled(session.isSettingsBusy)
            }
            modelVariantPicker(
                for: session.transcriptionEngineID,
                accessibilityName: "识别模型",
                selection: Binding(
                    get: { session.currentTranscriptionModelVariant?.id },
                    set: { session.transcriptionModelVariantID = $0 }
                )
            )
            .disabled(session.isSettingsBusy)
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
                .disabled(session.isSettingsBusy)
            }
            modelVariantPicker(
                for: session.translationEngineID,
                accessibilityName: "转录翻译模型",
                selection: Binding(
                    get: { session.currentTranslationModelVariant?.id },
                    set: { session.translationModelVariantID = $0 }
                )
            )
            .disabled(session.isSettingsBusy)
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
                SettingsRow(title: "模型状态", subtitle: "预计占用内存：约 \(session.settingsEstimatedMemoryGB) GB") {
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
}
