import AppKit
import OmniVoiceCore
import SwiftUI

/// "模型库" tab for downloading/cancelling/deleting a `.model`-kind
/// engine's weights — the single place that actually drives
/// `ModelDownloadManager`. `SettingsView`'s engine picker links back here
/// (Task 1.3) whenever a not-yet-downloaded engine is selected; this view
/// itself always lists every catalog entry regardless of what's currently
/// selected there, since a variant not yet downloaded needs to be reachable
/// from *somewhere* to bootstrap it.
struct ModelManagementView: View {
    /// Same instance `RecordingSession`/`SettingsView` observe — see
    /// `SettingsView`'s own `downloadManager` doc for why this is passed in
    /// explicitly rather than defaulted to `.shared`.
    @ObservedObject private var downloadManager: ModelDownloadManager
    /// Injected via `.environmentObject` — used both to disable "删除"
    /// during an active recording/preload (see `actionButton(for:)`) and,
    /// per Task 2.1, to auto-activate a freshly-downloaded engine.
    @EnvironmentObject private var session: RecordingSession
    @State private var errorTitle = String(localized: "Operation Failed")
    @State private var errorMessage: String?
    @State private var pendingDeletion: ModelVariant?
    /// Task 2.1 (下载后自动激活与反馈) — set right after a download this view
    /// itself auto-activated, cleared on "撤销切换" or once the user
    /// dismisses it. `nil` the rest of the time (nothing to show).
    @State private var activationBanner: ActivationBanner?
    /// Which variant IDs a bundle download most recently kicked off — purely
    /// so `bundleCard(for:)` can show "下载中" immediately for every member,
    /// same reasoning `ModelDownloadManager.isDownloading(_:)`'s doc gives
    /// for reading a job's existence rather than waiting on its first
    /// progress tick.
    @State private var pendingBundleDownloads: Set<String> = []
    /// Task 4.3 (异常状态内联重试) — per-variant failure message (network
    /// interruption, checksum mismatch, ...), rendered as an inline error
    /// bar on that variant's own card with "重试"/"复制下载链接" actions,
    /// instead of a modal `.alert` that says nothing about *which* card
    /// failed once dismissed.
    @State private var failedVariants: [String: String] = [:]
    /// Task 4.2 (下载前磁盘空间可视化预检) — set instead of starting a
    /// download when `ModelDownloadManager.insufficientDiskSpaceWarning(for:)`
    /// already knows it won't fit, so the user sees this *before* a
    /// multi-GB transfer even begins.
    @State private var diskSpaceWarning: (variant: ModelVariant, error: ModelDownloadError)?

    init(modelDownloadManager: ModelDownloadManager) {
        self.downloadManager = modelDownloadManager
    }

    var body: some View {
        // A bare `Form` doesn't scroll on macOS (round-4 user report: with
        // both recommended bundles and every model variant rendered, the
        // bottom cards were clipped off, unreachable), so the cards live in
        // a `ScrollView`.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let activationBanner {
                    activationBannerView(activationBanner)
                }
                bundleSection
                SettingsCard(title: "Speech recognition models", icon: "waveform") {
                    modelRows(for: ProviderCatalog.transcriptionEngines)
                }
                SettingsCard(title: "Translation models", icon: "character.bubble") {
                    modelRows(for: ProviderCatalog.translationEngines)
                }
            }
            .padding(16)
        }
        .alert(
            errorTitle,
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let variant = pendingDeletion {
                    delete(variant)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        }
        // Task 4.2 — pre-flight disk-space warning, copy per
        // Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.6.1.
        .alert(
            "Not Enough Disk Space",
            isPresented: Binding(get: { diskSpaceWarning != nil }, set: { if !$0 { diskSpaceWarning = nil } })
        ) {
            Button("Open Storage Management") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                diskSpaceWarning = nil
            }
            Button("Got It", role: .cancel) { diskSpaceWarning = nil }
        } message: {
            if let diskSpaceWarning {
                Text(
                    "Couldn’t download “\(diskSpaceWarning.variant.displayName)”: \(diskSpaceWarning.error.errorDescription ?? ""). Free up some disk space and try again."
                )
            }
        }
    }

    private var deleteConfirmationTitle: String {
        guard let pendingDeletion else { return "" }
        return String(localized: "Delete “\(pendingDeletion.displayName)”?")
    }

    // MARK: - Task 2.1 — Auto-activation banner

    private struct ActivationBanner {
        let message: String
        let companionSuggestion: (message: String, variant: ModelVariant)?
        let undo: () -> Void
    }

    private func activationBannerView(_ banner: ActivationBanner) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.accentColor)
                Text(banner.message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                PillButton(title: "Undo Switch") {
                    banner.undo()
                    activationBanner = nil
                }
            }
            if let companion = banner.companionSuggestion {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.secondary)
                    Text(companion.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    PillButton(title: String(localized: "Download \(companion.variant.displayName) (about \(companion.variant.approximateSizeMB) MB)")) {
                        download(companion.variant)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5))
    }

    /// Checks whether `variant`'s owning engine's *category* (ASR vs.
    /// translation) is still on its `.system` engine, and if so switches it
    /// over to `variant`'s engine and shows the undo-able banner above. A
    /// no-op if the category is already on a `.model` engine — auto-activating
    /// over a *different* model the user deliberately picked would be a much
    /// more surprising override than switching away from the always-available
    /// system default.
    ///
    /// Review Round 1 Must-Fix 3 — also a no-op while `session.isSessionActive`:
    /// a download can take minutes, easily long enough to span a recording
    /// started on the system engine in the meantime, and flipping
    /// `transcriptionEngineID`/`translationEngineID` here would fire their
    /// `didSet`'s unconditional `discardLoadedModelsIfStale()`, tearing down
    /// the very engine that recording is actively feeding. The download
    /// itself still completes and stays ready — this only defers the
    /// *auto-activation*, which a later, idle download-completion (or the
    /// user switching manually afterward) can still apply.
    private func autoActivateIfSystemEngineStillSelected(_ variant: ModelVariant) {
        guard !session.isSessionActive else { return }
        if ProviderCatalog.transcriptionEngines.contains(where: { $0.id == variant.engineID }) {
            guard session.transcriptionEngineKind == .system else { return }
            let previousEngineID = session.transcriptionEngineID
            session.transcriptionEngineID = variant.engineID
            session.transcriptionModelVariantID = variant.id
            activationBanner = ActivationBanner(
                message: String(localized: "“\(variant.displayName)” has finished downloading! The speech recognition engine was switched to \(variant.displayName) automatically."),
                companionSuggestion: companionSuggestion(forDownloadedTranscription: variant),
                undo: { session.transcriptionEngineID = previousEngineID }
            )
        } else if ProviderCatalog.translationEngines.contains(where: { $0.id == variant.engineID }) {
            guard session.translationEngineKind == .system else { return }
            let previousEngineID = session.translationEngineID
            session.translationEngineID = variant.engineID
            session.translationModelVariantID = variant.id
            activationBanner = ActivationBanner(
                message: String(localized: "“\(variant.displayName)” has finished downloading! The translation engine was switched to \(variant.displayName) automatically."),
                companionSuggestion: companionSuggestion(forDownloadedTranslation: variant),
                undo: { session.translationEngineID = previousEngineID }
            )
        }
    }

    /// Just downloaded a translation model (T3PO/HY-MT1.5) but R2T2 isn't
    /// downloaded yet (in *any* precision) — surfaces the §4.3.3 "搭配 R2T2 识别引擎可获得最佳实时
    /// 打字机体验" nudge. `nil` once R2T2 is already downloaded, or for a
    /// transcription-side download (nothing to suggest downward from).
    private func companionSuggestion(forDownloadedTranscription variant: ModelVariant) -> (String, ModelVariant)? {
        nil
    }

    private func companionSuggestion(forDownloadedTranslation variant: ModelVariant) -> (String, ModelVariant)? {
        guard let r2t2 = ProviderCatalog.companionSuggestion(
            forEngineID: "model.r2t2", isDownloaded: downloadManager.isDownloaded
        ) else {
            return nil
        }
        return (String(localized: "Pair it with the R2T2 speech recognition engine for the best real-time typewriter experience"), r2t2)
    }

    // MARK: - Task 2.3 — Recommended bundles

    private var bundleSection: some View {
        SettingsCard(title: "Recommended setups", icon: "sparkles") {
            ForEach(Array(ProviderCatalog.bundles.enumerated()), id: \.element.id) { index, bundle in
                if index > 0 { SettingsDivider() }
                bundleCard(for: bundle)
            }
        }
    }

    /// Round-4 user report (Docs/UX-SETTINGS-MODEL-MANAGEMENT.md's bundle
    /// section) — a bare "已下载 X/Y" count reads as contradictory once two
    /// bundles share a variant (both recommended pairings here use
    /// `r2t2-q8_0`): downloading R2T2 for 方案A also, correctly, counts
    /// toward 方案B's own total, but nothing on screen said *why* 方案B could
    /// already show progress the user never explicitly asked it to download.
    /// This itemized checklist makes that shared state visible per variant,
    /// instead of only a count — see `bundleCard(for:)`.
    private func bundleChecklist(_ status: ModelBundleStatus) -> some View {
        HStack(spacing: 12) {
            ForEach(status.variants) { variant in
                let isDownloaded = status.downloadedVariants.contains(variant)
                HStack(spacing: 4) {
                    Image(systemName: isDownloaded ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isDownloaded ? Color.green : Color.secondary)
                    Text(variant.displayName)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func bundleCard(for bundle: ModelBundle) -> some View {
        // `ModelBundle.status(isDownloaded:)` resolves strictly against
        // `bundle.variantIDs` — the exact quantization each bundle names,
        // never every variant sharing its engine family, and never counted
        // twice (see that type's doc for the full reasoning this was
        // audited against).
        let status = bundle.status(isDownloaded: downloadManager.isDownloaded)
        let isBundleDownloading = status.variants.contains {
            downloadManager.isDownloading($0) || pendingBundleDownloads.contains($0.id)
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(bundle.displayName).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if status.isFullyDownloaded {
                    StatusPill(text: "All downloaded", tone: .good)
                } else {
                    StatusPill(
                        text: String(localized: "Downloaded \(status.downloadedVariants.count)/\(status.variants.count)"),
                        tone: status.downloadedVariants.isEmpty ? .neutral : .warning
                    )
                }
            }
            Text(bundle.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Itemized per variant, not just a count: two bundles share a
            // variant (both recommended pairings use `r2t2-q8_0`), so a bare
            // "已下载 X/Y" read as contradictory (round-4 user report).
            bundleChecklist(status)
            if !status.isFullyDownloaded {
                HStack {
                    Spacer()
                    PillButton(
                        title: status.downloadedVariants.isEmpty
                            ? String(localized: "Set Up This Plan (about \(status.remainingSizeMB) MB)")
                            : String(localized: "Download Remaining Components (about \(status.remainingSizeMB) MB)"),
                        isWorking: isBundleDownloading,
                        workingTitle: "Downloading…"
                    ) {
                        downloadBundle(bundle)
                    }
                    .disabled(isBundleDownloading)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func downloadBundle(_ bundle: ModelBundle) {
        let variants = bundle.status(isDownloaded: downloadManager.isDownloaded).remainingVariants
        for variant in variants {
            pendingBundleDownloads.insert(variant.id)
            download(variant) {
                pendingBundleDownloads.remove(variant.id)
            }
        }
    }

    // MARK: - Rich model cards (Task 2.2)

    /// Every model variant of the given engines, one divider-separated row
    /// each; engines with no downloadable weights (the `.system` ones) have
    /// no variants and contribute nothing.
    @ViewBuilder
    private func modelRows(for engines: [EngineDescriptor]) -> some View {
        let variants = engines.filter { $0.kind == .model }
            .flatMap { ProviderCatalog.modelVariants(forEngineID: $0.id) }
        ForEach(Array(variants.enumerated()), id: \.element.id) { index, variant in
            if index > 0 { SettingsDivider() }
            variantCard(for: variant)
        }
    }

    @ViewBuilder
    private func variantCard(for variant: ModelVariant) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(variant.displayName).font(.system(size: 13, weight: .semibold))
                Text("\(variant.quantization) · about \(variant.approximateSizeMB) MB · about \(variant.recommendedMemoryGB) GB memory")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if !variant.summary.isEmpty {
                    Text(variant.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                statusLine(for: variant)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            actionButton(for: variant)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func statusLine(for variant: ModelVariant) -> some View {
        if downloadManager.isDownloading(variant) {
            downloadingStatus(for: variant)
        } else if downloadManager.isDownloaded(variant) {
            StatusPill(text: "Verified, ready", tone: .good)
        } else if let message = failedVariants[variant.id] {
            inlineFailureCard(for: variant, message: message)
        } else {
            StatusPill(text: "Not downloaded yet", tone: .neutral)
        }
    }

    /// Task 4.3 (异常状态内联重试) — replaces the old modal error `.alert`
    /// for a download failure: the card itself now says what went wrong,
    /// with a same-tap retry and a "复制下载链接" escape hatch for a user
    /// who'd rather fetch the file with a third-party downloader/on another
    /// network and import it manually (Docs/UX-SETTINGS-MODEL-MANAGEMENT.md
    /// §4.6.2).
    private func inlineFailureCard(for variant: ModelVariant, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Download interrupted: \(message)")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                PillButton(title: "Retry Now") { download(variant) }
                if variant.downloadURL != nil {
                    PillButton(title: "Copy Download Link") { copyDownloadLink(for: variant) }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyDownloadLink(for variant: ModelVariant) {
        guard let downloadURL = variant.downloadURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(downloadURL.absoluteString, forType: .string)
    }

    /// Task 2.4's speed/ETA readout, rendered next to the determinate
    /// progress bar — falls back to the "准备下载…" state before the first
    /// byte-count callback arrives.
    @ViewBuilder
    private func downloadingStatus(for variant: ModelVariant) -> some View {
        if let fraction = downloadManager.downloadProgress[variant.id] {
            // `.rounded()`, not a bare `Int(...)` truncation — see
            // `SettingsView`'s `opacitySlider` doc for why (binary
            // floating-point rounding can land a hair under a "clean"
            // percentage).
            Text("Downloading \(Int((fraction * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            ProgressView(value: fraction)
            if let stats = downloadManager.downloadStats[variant.id] {
                Text(stats.summaryLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Preparing download…")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            // `.linear`, not the default circular spinner — this state
            // flips to the determinate `ProgressView(value:)` above the
            // moment the first byte count arrives, and a spinner-to-bar
            // shape change read as a jarring hiccup rather than the same
            // download simply gaining a known size.
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    @ViewBuilder
    private func actionButton(for variant: ModelVariant) -> some View {
        if downloadManager.isDownloading(variant) {
            PillButton(title: "Cancel") { downloadManager.cancelDownload(for: variant) }
        } else if downloadManager.isDownloaded(variant) {
            // Guards against deleting the weights out from under an active
            // recording/preload — an in-flight `loadModel()`/an already
            // *loaded* model doesn't re-read the file after load, but the
            // very next preload/start attempt for this variant would find
            // nothing there and fail confusingly rather than with the clear
            // "尚未下载" message a deliberate re-download produces.
            PillButton(title: "Delete", tint: .red) { pendingDeletion = variant }
                .disabled(session.isSessionActive || session.isPreloadingModel)
        } else {
            PillButton(title: "Download") { download(variant) }
        }
    }

    private func download(_ variant: ModelVariant, completion: (() -> Void)? = nil) {
        failedVariants[variant.id] = nil
        // Task 4.2 — checked here, before the transfer even starts, not just
        // relying on `ensureDownloaded(_:)`'s own safety-net check deep
        // inside `runJob(for:)`.
        if let warning = downloadManager.insufficientDiskSpaceWarning(for: variant) {
            diskSpaceWarning = (variant, warning)
            completion?()
            return
        }
        SystemNotifier.requestAuthorizationIfNeeded()
        Task {
            defer { completion?() }
            do {
                _ = try await downloadManager.ensureDownloaded(variant)
                autoActivateIfSystemEngineStillSelected(variant)
                SystemNotifier.notify(
                    title: String(localized: "Model Download Complete"),
                    body: String(localized: "“\(variant.displayName)” was downloaded and is ready to use"))
            } catch is CancellationError {
                // The user's own "取消" tap — not a failure worth an alert.
            } catch {
                // Task 4.3 — inline on this variant's own card, not a modal
                // `.alert` (see `inlineFailureCard(for:message:)`'s doc).
                failedVariants[variant.id] = error.localizedDescription
                SystemNotifier.notify(
                    title: String(localized: "Model Download Failed"),
                    body: String(localized: "“\(variant.displayName)”: \(error.localizedDescription)"))
            }
        }
    }

    private func delete(_ variant: ModelVariant) {
        do {
            try downloadManager.deleteCachedModel(for: variant)
            // The disabled-while-active guard on the "删除" button above
            // only covers a recording/preload in progress — a model that
            // was preloaded earlier and left resident (`stop()` doesn't
            // unload, see its own doc) can still be sitting in memory with
            // nothing active. Deleting its file out from under that loaded
            // instance would otherwise leave `isModelLoaded` reading "就绪"
            // (and `start()`'s `reusingLoaded` happily reusing it) while
            // Settings/Model Management both show "未下载" — unload it too
            // so every view of the state agrees.
            // A translation-only load (`hasLoadedModels` without
            // `isModelLoaded`) holds just the translator's weights.
            if (session.hasLoadedModels && session.currentTranslationModelVariant?.id == variant.id)
                || (session.isModelLoaded && session.currentTranscriptionModelVariant?.id == variant.id)
            {
                session.unloadModels()
            }
            // Without this, deleting the last downloaded variant for the
            // currently-selected engine left Settings pointing at a
            // `.model` engine with nothing behind it — the next "开始
            //转录"/"预加载模型" would then fail with a "尚未下载" message
            // the user has no reason to expect right after deleting
            // something on purpose. Falls back to the corresponding
            // `.system` engine instead, same as a fresh install where
            // nothing was ever downloaded.
            session.fallBackToSystemEngineIfModelUnavailable()
        } catch {
            errorTitle = String(localized: "Delete Failed")
            errorMessage = error.localizedDescription
        }
    }
}
