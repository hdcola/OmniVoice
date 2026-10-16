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
        SettingsCard(title: "Speech recognition engine (ASR)", icon: "waveform") {
            SettingsRow(title: "Engine") {
                Picker("Speech recognition engine", selection: $session.transcriptionEngineID) {
                    // Every catalog engine is always listed, downloaded or
                    // not; an undownloaded `.model` engine is labeled rather
                    // than filtered out (see `engineLabel(for:)`), so it
                    // stays discoverable.
                    ForEach(ProviderCatalog.transcriptionEngines) { engine in
                        Text(engineLabel(for: engine)).tag(engine.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Speech recognition engine")
                .fixedSize()
                .disabled(session.isSettingsBusy)
            }
            modelVariantPicker(
                for: session.transcriptionEngineID,
                accessibilityName: String(localized: "Speech recognition model"),
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
                    title: "Sentence pause length",
                    subtitle: "Silence longer than this ends the current sentence; longer values split sentences less often but make text appear more slowly"
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $session.vadSilenceSeconds, in: 0.3...3.0, step: 0.1)
                            .frame(width: 140)
                            .accessibilityLabel("Sentence pause length")
                            .accessibilityValue(String(format: String(localized: "%.1f s"), session.vadSilenceSeconds))
                        Text(String(format: String(localized: "%.1f s"), session.vadSilenceSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "Silence level threshold",
                    subtitle: "Audio quieter than this counts as silence; lower it (more negative) if your microphone is quiet or you speak softly"
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $session.vadSilenceDBFS, in: -70...(-20), step: 1)
                            .frame(width: 140)
                            .accessibilityLabel("Silence level threshold")
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
        SettingsCard(title: "Transcription translation engine", icon: "character.bubble") {
            SettingsRow(title: "Engine") {
                Picker("Transcription translation engine", selection: $session.translationEngineID) {
                    ForEach(ProviderCatalog.translationEngines) { engine in
                        Text(engineLabel(for: engine)).tag(engine.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Transcription translation engine")
                .fixedSize()
                .disabled(session.isSettingsBusy)
            }
            modelVariantPicker(
                for: session.translationEngineID,
                accessibilityName: String(localized: "Transcription translation model"),
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
                SettingsRow(title: "Translation commit strategy") {
                    Picker("Translation commit strategy", selection: $session.translationCommitEagerness) {
                        ForEach(TranslationCommitEagerness.allCases, id: \.self) { eagerness in
                            Text(eagerness.displayName).tag(eagerness)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Translation commit strategy")
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
                title: "Early-translation threshold for long sentences",
                subtitle: "Lower values show text sooner, but long sentences are more likely to be split into several parts"
            ) {
                HStack(spacing: 6) {
                    // No range clamp here — `RecordingSession
                    // .translationEarlyTranslateThreshold`'s own `didSet`
                    // already clamps to 20...1000 and persists it.
                    TextField(
                        "Early-translation threshold for long sentences",
                        value: $session.translationEarlyTranslateThreshold,
                        format: .number
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    Text("characters").foregroundStyle(.secondary)
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .help(
                            String(localized: "When the cached source text reaches half this many characters and hits a sentence break (period, question mark, line break), the cached text is translated early; once it reaches the full threshold it is translated even without a break, so long sentences don't stall. Lower values show text sooner but split long sentences into more parts; higher values keep each part more complete but may wait longer.")
                        )
                }
            }
        } else {
            SettingsNote(text: "The current engine doesn't need an early-translation threshold (it only applies to translation engines that output in segments in real time).")
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
        hasDownloadedVariant(engine) ? engine.displayName : String(localized: "\(engine.displayName) (not downloaded · click to set up)")
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
            SettingsRow(title: "Model") {
                Picker("Model", selection: selection) {
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
            ? String(localized: "\(variant.displayName) · about \(variant.approximateSizeMB) MB")
            : String(localized: "\(variant.displayName) (not downloaded)")
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
                        Text("Downloading \(Int((fraction * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: fraction)
                        if let stats = downloadManager.downloadStats[variant.id] {
                            Text(stats.summaryLine)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Preparing download…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView().progressViewStyle(.linear)
                    }
                } else if let message = inlineDownloadFailures[variant.id] {
                    Text("Download interrupted: \(message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                    HStack {
                        PillButton(title: "Retry Now") { downloadInline(variant) }
                        if variant.downloadURL != nil {
                            PillButton(title: "Copy Download Link") { copyDownloadLink(for: variant) }
                        }
                    }
                } else {
                    Text("About \(variant.approximateSizeMB) MB · not downloaded yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if downloadManager.isDownloading(variant) {
                PillButton(title: "Cancel") { downloadManager.cancelDownload(for: variant) }
            } else {
                PillButton(title: "Download and Enable") { downloadInline(variant) }
            }
        }
        // Task 4.2 — same copy as `ModelManagementView`'s own disk-space
        // alert (Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.6.1).
        .alert(
            "Not Enough Disk Space",
            isPresented: Binding(
                get: { inlineDiskSpaceWarning?.variant.id == variant.id },
                set: { if !$0 { inlineDiskSpaceWarning = nil } }
            )
        ) {
            Button("Open Storage Management") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                inlineDiskSpaceWarning = nil
            }
            Button("Got It", role: .cancel) { inlineDiskSpaceWarning = nil }
        } message: {
            if let inlineDiskSpaceWarning {
                Text("Downloading “\(inlineDiskSpaceWarning.variant.displayName)” \(inlineDiskSpaceWarning.error.errorDescription ?? ""). Free up some disk space and try again.")
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
                    title: String(localized: "Model Download Complete"),
                    body: String(localized: "“\(variant.displayName)” was downloaded and enabled automatically"))
            } catch is CancellationError {
                // The user's own "取消" tap — not a failure worth surfacing.
            } catch {
                // Task 4.3 — inline on this row, not just `statusMessage`.
                inlineDownloadFailures[variant.id] = error.localizedDescription
                SystemNotifier.notify(
                    title: String(localized: "Model Download Failed"),
                    body: String(localized: "“\(variant.displayName)”: \(error.localizedDescription)"))
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
        SettingsCard(title: "Engine status and memory", icon: "memorychip") {
            if session.usesOnDeviceModelEngine {
                SettingsRow(title: "Model status", subtitle: String(localized: "Estimated memory use: about \(session.settingsEstimatedMemoryGB) GB")) {
                    StatusPill(text: memoryStatusText, tone: memoryStatusTone)
                }
                SettingsDivider()
                HStack {
                    Spacer()
                    PillButton(
                        title: "⚡ Preload into Memory",
                        isWorking: session.isPreloadingModel,
                        workingTitle: "Loading…"
                    ) {
                        Task { await session.preloadModel() }
                    }
                    .disabled(session.isSessionActive || session.isPreloadingModel || session.isModelLoaded)

                    PillButton(title: "🧹 Free Memory") {
                        session.unloadModels()
                    }
                    .disabled(!session.hasLoadedModels || session.isSessionActive || session.isPreloadingModel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                SettingsNote(text: "The current engines are built into macOS; there is nothing to preload or free.")
            }
        }
    }

    private var memoryStatusTone: StatusPill.Tone {
        if session.isPreloadingModel { return .warning }
        return session.hasLoadedModels ? .good : .neutral
    }

    private var memoryStatusText: String {
        if session.isPreloadingModel { return String(localized: "Loading…") }
        if session.isModelLoaded { return String(localized: "Loaded in memory (ready)") }
        return session.hasLoadedModels ? String(localized: "Only the translation model is loaded") : String(localized: "Idle (not loaded in memory)")
    }
}
