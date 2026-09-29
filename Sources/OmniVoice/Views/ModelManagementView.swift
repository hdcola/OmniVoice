import AppKit
import OmniVoiceCore
import SwiftUI

/// Dedicated window for downloading/cancelling/deleting a `.model`-kind
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
    @State private var errorTitle = "操作失败"
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
        Form {
            if let activationBanner {
                activationBannerView(activationBanner)
            }
            bundleSection
            Section("识别引擎模型") {
                ForEach(ProviderCatalog.transcriptionEngines.filter { $0.kind == .model }) { engine in
                    variantRows(forEngineID: engine.id)
                }
            }
            Section("翻译引擎模型") {
                ForEach(ProviderCatalog.translationEngines.filter { $0.kind == .model }) { engine in
                    variantRows(forEngineID: engine.id)
                }
            }
        }
        .padding(20)
        .alert(
            errorTitle,
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let variant = pendingDeletion {
                    delete(variant)
                }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        }
        // Task 4.2 — pre-flight disk-space warning, copy per
        // Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.6.1.
        .alert(
            "磁盘空间不足",
            isPresented: Binding(get: { diskSpaceWarning != nil }, set: { if !$0 { diskSpaceWarning = nil } })
        ) {
            Button("打开存储空间管理") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                diskSpaceWarning = nil
            }
            Button("知道了", role: .cancel) { diskSpaceWarning = nil }
        } message: {
            if let diskSpaceWarning {
                Text(
                    "下载「\(diskSpaceWarning.variant.displayName)」\(diskSpaceWarning.error.errorDescription ?? "")。请清理磁盘空间后重试。"
                )
            }
        }
    }

    private var deleteConfirmationTitle: String {
        guard let pendingDeletion else { return "" }
        return "确定要删除「\(pendingDeletion.displayName)」吗？"
    }

    // MARK: - Task 2.1 — Auto-activation banner

    private struct ActivationBanner {
        let message: String
        let companionSuggestion: (message: String, variant: ModelVariant)?
        let undo: () -> Void
    }

    private func activationBannerView(_ banner: ActivationBanner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text("🎉 \(banner.message)")
                    .font(.callout)
                Spacer()
                Button("撤销切换") {
                    banner.undo()
                    activationBanner = nil
                }
                .font(.caption)
            }
            if let companion = banner.companionSuggestion {
                HStack {
                    Text("💡 \(companion.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("立即下载 \(companion.variant.displayName)（约 \(companion.variant.approximateSizeMB) MB）") {
                        download(companion.variant)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
                message: "「\(variant.displayName)」已下载完成！已自动将识别引擎切换为\(variant.displayName)。",
                companionSuggestion: companionSuggestion(forDownloadedTranscription: variant),
                undo: { session.transcriptionEngineID = previousEngineID }
            )
        } else if ProviderCatalog.translationEngines.contains(where: { $0.id == variant.engineID }) {
            guard session.translationEngineKind == .system else { return }
            let previousEngineID = session.translationEngineID
            session.translationEngineID = variant.engineID
            session.translationModelVariantID = variant.id
            activationBanner = ActivationBanner(
                message: "「\(variant.displayName)」已下载完成！已自动将翻译引擎切换为\(variant.displayName)。",
                companionSuggestion: companionSuggestion(forDownloadedTranslation: variant),
                undo: { session.translationEngineID = previousEngineID }
            )
        }
    }

    /// Just downloaded a translation model (T3PO/HY-MT1.5) but R2T2 isn't
    /// downloaded yet — surfaces the §4.3.3 "搭配 R2T2 识别引擎可获得最佳实时
    /// 打字机体验" nudge. `nil` once R2T2 is already downloaded, or for a
    /// transcription-side download (nothing to suggest downward from).
    private func companionSuggestion(forDownloadedTranscription variant: ModelVariant) -> (String, ModelVariant)? {
        nil
    }

    private func companionSuggestion(forDownloadedTranslation variant: ModelVariant) -> (String, ModelVariant)? {
        guard let r2t2 = ProviderCatalog.variant(forID: "r2t2-q8_0"), !downloadManager.isDownloaded(r2t2) else {
            return nil
        }
        return ("搭配 R2T2 识别引擎可获得最佳实时打字机体验", r2t2)
    }

    // MARK: - Task 2.3 — Recommended bundles

    private var bundleSection: some View {
        Section("💡 推荐方案快速配置") {
            ForEach(ProviderCatalog.bundles) { bundle in
                bundleCard(for: bundle)
            }
        }
    }

    private func bundleVariants(_ bundle: ModelBundle) -> [ModelVariant] {
        bundle.variantIDs.compactMap(ProviderCatalog.variant(forID:))
    }

    private func bundleCard(for bundle: ModelBundle) -> some View {
        let variants = bundleVariants(bundle)
        let downloadedCount = variants.filter { downloadManager.isDownloaded($0) }.count
        let remaining = variants.filter { !downloadManager.isDownloaded($0) }
        let isBundleDownloading = variants.contains { downloadManager.isDownloading($0) || pendingBundleDownloads.contains($0.id) }
        let remainingSizeMB = remaining.reduce(0) { $0 + $1.approximateSizeMB }

        return VStack(alignment: .leading, spacing: 6) {
            Text(bundle.displayName).font(.headline)
            Text(bundle.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(
                    downloadedCount == variants.count
                        ? "状态：已全部下载"
                        : "状态：已下载 \(downloadedCount)/\(variants.count)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                if downloadedCount < variants.count {
                    Button {
                        downloadBundle(bundle)
                    } label: {
                        if isBundleDownloading {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("下载中…")
                            }
                        } else {
                            Text(
                                downloadedCount == 0
                                    ? "⬇️ 一键配置此方案（约 \(remainingSizeMB) MB）"
                                    : "⬇️ 一键下载剩余组件（约 \(remainingSizeMB) MB）"
                            )
                        }
                    }
                    .disabled(isBundleDownloading)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func downloadBundle(_ bundle: ModelBundle) {
        let variants = bundleVariants(bundle).filter { !downloadManager.isDownloaded($0) }
        for variant in variants {
            pendingBundleDownloads.insert(variant.id)
            download(variant) {
                pendingBundleDownloads.remove(variant.id)
            }
        }
    }

    // MARK: - Rich model cards (Task 2.2)

    @ViewBuilder
    private func variantRows(forEngineID engineID: String) -> some View {
        ForEach(ProviderCatalog.modelVariants(forEngineID: engineID)) { variant in
            variantCard(for: variant)
        }
    }

    @ViewBuilder
    private func variantCard(for variant: ModelVariant) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(variant.displayName).font(.headline)
                Spacer()
                actionButton(for: variant)
            }
            Text("版本：\(variant.quantization) · 文件大小：约 \(variant.approximateSizeMB) MB · 预计显存/内存占用：约 \(variant.recommendedMemoryGB) GB")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !variant.summary.isEmpty {
                Text("优势：\(variant.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            statusLine(for: variant)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusLine(for variant: ModelVariant) -> some View {
        if downloadManager.isDownloading(variant) {
            downloadingStatus(for: variant)
        } else if downloadManager.isDownloaded(variant) {
            Text("🟢 校验通过，就绪")
                .font(.caption)
                .foregroundStyle(.green)
        } else if let message = failedVariants[variant.id] {
            inlineFailureCard(for: variant, message: message)
        } else {
            Text("约 \(variant.approximateSizeMB) MB · 尚未下载")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("⚠️ 下载中断：\(message)")
                .font(.caption)
                .foregroundStyle(.red)
            HStack {
                Button("立即重试") { download(variant) }
                    .font(.caption)
                if variant.downloadURL != nil {
                    Button("复制下载链接") { copyDownloadLink(for: variant) }
                        .font(.caption)
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
    /// progress bar — falls back to the old "准备下载…" spinner state before
    /// the first byte-count callback arrives (see `ModelManagementView`'s
    /// previous revision for why that gap needs its own state at all).
    @ViewBuilder
    private func downloadingStatus(for variant: ModelVariant) -> some View {
        if let fraction = downloadManager.downloadProgress[variant.id] {
            // `.rounded()`, not a bare `Int(...)` truncation — see
            // `SettingsView`'s `opacitySlider` doc for why (binary
            // floating-point rounding can land a hair under a "clean"
            // percentage).
            Text("下载中 \(Int((fraction * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .font(.caption)
            ProgressView(value: fraction)
            if let stats = downloadManager.downloadStats[variant.id] {
                Text(stats.summaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("准备下载…")
                .foregroundStyle(.secondary)
                .font(.caption)
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
            Button("取消") { downloadManager.cancelDownload(for: variant) }
        } else if downloadManager.isDownloaded(variant) {
            HStack(spacing: 8) {
                // Guards against deleting the weights out from under an
                // active recording/preload — an in-flight `loadModel()`/an
                // already *loaded* model doesn't re-read the file after
                // load, but the very next preload/start attempt for this
                // variant would find nothing there and fail confusingly
                // rather than with the clear "尚未下载" message a deliberate
                // re-download produces.
                Button("删除") { pendingDeletion = variant }
                    .disabled(session.isSessionActive || session.isPreloadingModel)
            }
        } else {
            Button("下载") { download(variant) }
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
        Task {
            defer { completion?() }
            do {
                _ = try await downloadManager.ensureDownloaded(variant)
                autoActivateIfSystemEngineStillSelected(variant)
            } catch is CancellationError {
                // The user's own "取消" tap — not a failure worth an alert.
            } catch {
                // Task 4.3 — inline on this variant's own card, not a modal
                // `.alert` (see `inlineFailureCard(for:message:)`'s doc).
                failedVariants[variant.id] = error.localizedDescription
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
            if session.isModelLoaded
                && (session.currentTranscriptionModelVariant?.id == variant.id
                    || session.currentTranslationModelVariant?.id == variant.id)
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
            errorTitle = "删除失败"
            errorMessage = error.localizedDescription
        }
    }
}
