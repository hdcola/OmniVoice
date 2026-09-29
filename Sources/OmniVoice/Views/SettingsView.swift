import AppKit
import OmniVoiceCore
import SwiftUI

/// Settings window — a `TabView` (Task 3.1) over four tabs: "语音与引擎"
/// (engine choice, inline model download, the memory/preload console),
/// "模型库管理" (the full model catalog — the same content that used to be
/// the standalone "模型管理" window), "语言与悬浮窗" (language pickers + panel
/// opacity), and "关于". Data-driven from `ProviderCatalog` rather than one
/// hand-written `case` per engine, so adding a new community model
/// audio.cpp supports later is a catalog change, not a UI change.
struct SettingsView: View {
    @EnvironmentObject private var session: RecordingSession
    @EnvironmentObject private var navigation: SettingsNavigationState
    /// Observed directly (not just reached through `session`) so the engine
    /// picker's labels/inline download cards live-update the moment
    /// something is downloaded or deleted in the "模型库管理" tab —
    /// `RecordingSession` no longer triggers downloads itself and doesn't
    /// re-publish on every download tick, only on `statusMessage` changes.
    /// Passed in explicitly (not defaulted to `.shared`) and expected to be
    /// the exact same instance `session` was itself given — see
    /// `RecordingSession.init`'s own injectable `modelDownloadManager`
    /// parameter. Hardcoding `.shared` here instead would silently observe
    /// the wrong manager for any `RecordingSession` constructed with a
    /// non-`shared` one (a test, an eventual SwiftUI preview).
    @ObservedObject private var downloadManager: ModelDownloadManager
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
        TabView(selection: $navigation.selectedTab) {
            engineTab
                .tabItem { Label(SettingsTab.engines.title, systemImage: SettingsTab.engines.systemImage) }
                .tag(SettingsTab.engines)
            modelsTab
                .tabItem { Label(SettingsTab.models.title, systemImage: SettingsTab.models.systemImage) }
                .tag(SettingsTab.models)
            languageTab
                .tabItem { Label(SettingsTab.language.title, systemImage: SettingsTab.language.systemImage) }
                .tag(SettingsTab.language)
            aboutTab
                .tabItem { Label(SettingsTab.about.title, systemImage: SettingsTab.about.systemImage) }
                .tag(SettingsTab.about)
        }
        // Task 3.1 — fixed 560×480, big enough for the richer engine cards/
        // memory console without the old 440pt-wide `Form` clipping them.
        .frame(width: 560, height: 480)
    }

    // MARK: - Tab 1: 语音与引擎

    private var engineTab: some View {
        Form {
            Section("识别引擎 (ASR)") {
                Picker("引擎", selection: $session.transcriptionEngineID) {
                    // Task 1.3 (引擎列表展示全部候选) — every catalog engine
                    // is always listed, downloaded or not; an undownloaded
                    // `.model` engine is labeled rather than filtered out
                    // entirely (see `engineLabel(for:)`), so it stays
                    // discoverable instead of silently "vanishing" until
                    // something's downloaded for it.
                    ForEach(ProviderCatalog.transcriptionEngines) { engine in
                        Text(engineLabel(for: engine)).tag(engine.id)
                    }
                }
                .disabled(isBusy)
                modelVariantPicker(
                    for: session.transcriptionEngineID,
                    selection: Binding(
                        get: { session.currentTranscriptionModelVariant?.id },
                        set: { session.transcriptionModelVariantID = $0 }
                    )
                )
                .disabled(isBusy)
                // Task 3.2 (内联模型下载与状态卡片) — no more bouncing to a
                // separate window: an undownloaded `.model` engine's
                // download button/progress renders right here.
                inlineDownloadSection(forEngineID: session.transcriptionEngineID)
            }

            Section("翻译引擎") {
                Picker("引擎", selection: $session.translationEngineID) {
                    // Same reasoning as the ASR engine `Picker` above.
                    ForEach(ProviderCatalog.translationEngines) { engine in
                        Text(engineLabel(for: engine)).tag(engine.id)
                    }
                }
                .disabled(isBusy)
                modelVariantPicker(
                    for: session.translationEngineID,
                    selection: Binding(
                        get: { session.currentTranslationModelVariant?.id },
                        set: { session.translationModelVariantID = $0 }
                    )
                )
                .disabled(isBusy)
                inlineDownloadSection(forEngineID: session.translationEngineID)
                // T3PO is the only engine with a WAIT/TRANS decision to bias
                // (see `TranslationCommitEagerness`'s doc), so it gets its
                // own picker; every other (one-shot) engine instead exposes
                // the actual character threshold it reads
                // (`TranslationConfig.earlyTranslateThreshold`'s doc) as a
                // plain, directly user-configurable number — showing both
                // controls at once, or the wrong one for the selected
                // engine, would just be confusing. Deliberately *not*
                // `.disabled(isBusy)` in either branch — safe to change
                // mid-recording, same as `targetLanguageCode`'s picker.
                if session.translationEngineID == "model.t3po" {
                    Picker("翻译提交策略", selection: $session.translationCommitEagerness) {
                        ForEach(TranslationCommitEagerness.allCases, id: \.self) { eagerness in
                            Text(eagerness.displayName).tag(eagerness)
                        }
                    }
                } else if session.transcriptionEngineKind != .system {
                    // Task 1.4 (清理无效参数干扰) — See
                    // `TranslationConfig.earlyTranslateThreshold`'s doc for
                    // why this Stepper is a genuine no-op under the system
                    // ASR engine: `SystemTranscriptionProvider` never
                    // reports committed text via `.appended` mid-utterance —
                    // a finalized result *is* its segment boundary — so
                    // `translationProvider.feed(_:)` only ever runs once per
                    // segment, with the whole utterance already, immediately
                    // followed by `flush()` in the same call. There's
                    // nothing "early" left to translate by then. Rather
                    // than show it disabled with an explanatory caption
                    // (the old behavior), it's hidden outright.
                    Stepper(
                        "长句提前翻译阈值：\(session.translationEarlyTranslateThreshold) 字",
                        value: $session.translationEarlyTranslateThreshold, in: 20...1000, step: 10
                    )
                }
            }

            memoryConsole
        }
        .padding(20)
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
    /// it isn't downloaded (deleted via "模型库管理", or a stale/synced
    /// selection), to avoid a blank `Picker` selection; marked "（未下载）"
    /// for the same reason `engineLabel(for:)` marks its engine-level
    /// equivalent.
    @ViewBuilder
    private func modelVariantPicker(for engineID: String, selection: Binding<String?>) -> some View {
        let variants = ProviderCatalog.modelVariants(forEngineID: engineID)
        let selectedID = selection.wrappedValue
        let shown = variants.filter { downloadManager.isDownloaded($0) || $0.id == selectedID }
        if !shown.isEmpty {
            Picker("模型", selection: selection) {
                ForEach(shown) { variant in
                    Text(variantLabel(for: variant)).tag(Optional(variant.id))
                }
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
    /// `Picker`s, instead of only being reachable via "模型库管理". Each row
    /// mirrors the "模型库管理" tab's own download affordance (percent,
    /// progress bar, speed/ETA once available).
    @ViewBuilder
    private func inlineDownloadSection(forEngineID engineID: String) -> some View {
        if let engine = (ProviderCatalog.transcriptionEngines + ProviderCatalog.translationEngines)
            .first(where: { $0.id == engineID }), engine.kind == .model, !hasDownloadedVariant(engine) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ProviderCatalog.modelVariants(forEngineID: engineID)) { variant in
                    inlineDownloadRow(for: variant)
                }
            }
            .padding(.top, 2)
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
                    Text("⚠️ 下载中断：\(message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                    HStack {
                        Button("立即重试") { downloadInline(variant) }.font(.caption)
                        if variant.downloadURL != nil {
                            Button("复制下载链接") { copyDownloadLink(for: variant) }.font(.caption)
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
                Button("取消") { downloadManager.cancelDownload(for: variant) }
            } else {
                Button("⬇️ 一键下载并启用") { downloadInline(variant) }
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

    /// Unlike "模型库管理"'s own download button, this one always applies
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
        Task {
            do {
                _ = try await downloadManager.ensureDownloaded(variant)
                if ProviderCatalog.transcriptionEngines.contains(where: { $0.id == variant.engineID }) {
                    session.transcriptionModelVariantID = variant.id
                } else {
                    session.translationModelVariantID = variant.id
                }
            } catch is CancellationError {
                // The user's own "取消" tap — not a failure worth surfacing.
            } catch {
                // Task 4.3 — inline on this row, not just `statusMessage`.
                inlineDownloadFailures[variant.id] = error.localizedDescription
            }
        }
    }

    // MARK: - Memory & preload console (Task 3.3)

    /// Moves the floating panel's "预加载模型"/"模型已就绪" affordance
    /// (`FloatingTranscriptView.modelStatusControl`) into Settings, per
    /// Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.2.2 — same
    /// `session.preloadModel()`/`session.unloadModels()` calls, just a
    /// second, more discoverable entry point for users who keep the panel
    /// hidden. Only shown once a `.model`-kind engine is actually selected
    /// for something (`usesOnDeviceModelEngine`) — a `.system`-only
    /// configuration has nothing to preload/release.
    @ViewBuilder
    private var memoryConsole: some View {
        if session.usesOnDeviceModelEngine {
            Section("引擎运行与显存状态") {
                HStack(spacing: 6) {
                    statusIndicatorDot
                    Text(memoryStatusText)
                        .font(.callout)
                }
                Text("预计占用统一内存：约 \(estimatedMemoryGB) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button {
                        Task { await session.preloadModel() }
                    } label: {
                        HStack(spacing: 5) {
                            if session.isPreloadingModel {
                                ProgressView().controlSize(.small)
                            }
                            Text(session.isPreloadingModel ? "加载中…" : "⚡ 预加载到显存")
                        }
                    }
                    .disabled(session.isSessionActive || session.isPreloadingModel || session.isModelLoaded)

                    Button("🧹 释放显存占用") {
                        session.unloadModels()
                    }
                    .disabled(!session.isModelLoaded || session.isSessionActive || session.isPreloadingModel)
                }
            }
        }
    }

    private var statusIndicatorDot: some View {
        Circle()
            .fill(statusIndicatorColor)
            .frame(width: 10, height: 10)
    }

    private var statusIndicatorColor: Color {
        if session.isPreloadingModel { return .yellow }
        return session.isModelLoaded ? .green : .gray
    }

    private var memoryStatusText: String {
        if session.isPreloadingModel { return "🟡 正在加载中…" }
        return session.isModelLoaded ? "🟢 当前模型已加载至显存 (就绪)" : "⚪ 空闲 (未载入显存)"
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

    // MARK: - Tab 2: 模型库管理

    private var modelsTab: some View {
        ModelManagementView(modelDownloadManager: downloadManager)
    }

    // MARK: - Tab 3: 语言与悬浮窗

    private var languageTab: some View {
        Form {
            Section("语言") {
                SourceLanguagePicker(
                    sourceLanguageCode: $session.sourceLanguageCode,
                    transcriptionEngineKind: session.transcriptionEngineKind
                )
                TargetLanguagePicker(
                    targetLanguageCode: $session.targetLanguageCode,
                    translationEngineID: session.translationEngineID,
                    onSwitchToSystemTranslation: { session.translationEngineID = "system.translation" },
                    // Belt-and-suspenders alongside this whole `Section`'s
                    // own `.disabled(isBusy)` below (Review Round 1
                    // Must-Fix 1) — keeps the button's own guard/caption
                    // correct even if this picker is ever reused outside
                    // a `.disabled` ancestor.
                    isSessionActive: session.isSessionActive
                )
            }
            .disabled(isBusy)

            // Deliberately outside the `.disabled(isBusy)` section above —
            // these only ever touch `FloatingTranscriptView`'s own SwiftUI
            // opacity (see `panelBackgroundOpacity`/`panelContentOpacity`'s
            // docs), never anything `start()` reads once at setup time, so
            // there's no race to guard against; adjusting either while
            // recording (to see through the panel at whatever's behind it,
            // without losing legibility) is exactly when they're most
            // useful. Two separate sliders, not one — a single shared value
            // (an earlier version of this had exactly that, driving
            // `NSWindow.alphaValue`) faded the transcript text right along
            // with the background, so a panel transparent enough to not
            // block the view behind it also made the text hard to read.
            Section("悬浮窗") {
                opacitySlider(
                    "背景透明度", value: $session.panelBackgroundOpacity, range: 0.1...1.0
                )
                // "内容透明度", not "文字透明度" — `panelContentOpacity`
                // fades the whole panel content stack (buttons/pickers/
                // dividers/status bar too), not just the transcript text.
                opacitySlider(
                    "内容透明度", value: $session.panelContentOpacity, range: 0.4...1.0
                )
            }
        }
        .padding(20)
    }

    private func opacitySlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: range)
            // `.rounded()`, not a bare `Int(...)` truncation — a `Slider`'s
            // underlying `Double` can land a hair under a "clean" percentage
            // from binary floating-point rounding (e.g. 0.29999999999999994
            // for what's visually 0.3), which truncation reads as 29% —
            // jittery/off-by-one against where the thumb actually looks.
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: - Tab 4: 关于

    private var aboutTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OmniVoice").font(.title2.bold())
                    Text("macOS 离线实时双语字幕与转录工具")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("版本 \(appVersionString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("引擎") {
                Text("系统引擎基于 macOS Speech / Translation 框架；本地引擎基于 audio.cpp（R2T2）与 llama.cpp（T3PO / HY-MT1.5），完全离线运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var appVersionString: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(shortVersion) (\($0))" } ?? shortVersion
    }
}
