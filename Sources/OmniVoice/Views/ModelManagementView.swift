import OmniVoiceCore
import SwiftUI

/// Dedicated window for downloading/cancelling/deleting a `.model`-kind
/// engine's weights — the single place that actually drives
/// `ModelDownloadManager`. `SettingsView`'s engine picker only offers an
/// engine once something here has been downloaded for it (see that view's
/// `isEngineAvailable(_:)`); this view itself always lists every catalog
/// entry regardless of what's currently selected there, since a variant not
/// yet downloaded needs to be reachable from *somewhere* to bootstrap it.
struct ModelManagementView: View {
    /// Same instance `RecordingSession`/`SettingsView` observe — see
    /// `SettingsView`'s own `downloadManager` doc for why this is passed in
    /// explicitly rather than defaulted to `.shared`.
    @ObservedObject private var downloadManager: ModelDownloadManager
    /// Injected via `.environmentObject` in `OmniVoiceApp.swift`'s
    /// `modelManagement` scene, same as every other window this app opens —
    /// only used here to disable "删除" during an active recording/preload
    /// (see `actionButton(for:)`).
    @EnvironmentObject private var session: RecordingSession
    @State private var errorTitle = "操作失败"
    @State private var errorMessage: String?
    @State private var pendingDeletion: ModelVariant?

    init(modelDownloadManager: ModelDownloadManager) {
        self.downloadManager = modelDownloadManager
    }

    var body: some View {
        Form {
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
        .frame(width: 460)
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
    }

    private var deleteConfirmationTitle: String {
        guard let pendingDeletion else { return "" }
        return "确定要删除「\(pendingDeletion.displayName)」吗？"
    }

    @ViewBuilder
    private func variantRows(forEngineID engineID: String) -> some View {
        ForEach(ProviderCatalog.modelVariants(forEngineID: engineID)) { variant in
            variantRow(for: variant)
        }
    }

    @ViewBuilder
    private func variantRow(for variant: ModelVariant) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(variant.displayName)
                if downloadManager.isDownloading(variant) {
                    // `isDownloading(_:)` (a job exists) rather than
                    // `downloadProgress[variant.id] != nil` — the job starts
                    // (and this row should already read "下载中…") the
                    // instant "下载" is tapped, well before the first network
                    // progress callback arrives (DNS/TLS/redirect can take a
                    // moment); waiting on `downloadProgress` left the button
                    // reading "下载" during that gap, inviting a second tap.
                    if let fraction = downloadManager.downloadProgress[variant.id] {
                        Text("下载中… \(Int(fraction * 100))%")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        ProgressView(value: fraction)
                    } else {
                        Text("准备下载…")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        // `.linear`, not the default circular spinner — this
                        // state flips to the determinate `ProgressView(value:)`
                        // above the moment the first byte count arrives, and
                        // a spinner-to-bar shape change read as a jarring
                        // hiccup rather than the same download simply
                        // gaining a known size.
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                } else if downloadManager.isDownloaded(variant) {
                    Text("已下载 · 约 \(variant.approximateSizeMB) MB")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Text("约 \(variant.approximateSizeMB) MB")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            Spacer()
            actionButton(for: variant)
        }
    }

    @ViewBuilder
    private func actionButton(for variant: ModelVariant) -> some View {
        if downloadManager.isDownloading(variant) {
            Button("取消") { downloadManager.cancelDownload(for: variant) }
        } else if downloadManager.isDownloaded(variant) {
            // Guards against deleting the weights out from under an active
            // recording/preload — an in-flight `loadModel()`/an already
            // *loaded* model doesn't re-read the file after load, but the
            // very next preload/start attempt for this variant would find
            // nothing there and fail confusingly rather than with the clear
            // "尚未下载" message a deliberate re-download produces.
            Button("删除") { pendingDeletion = variant }
                .disabled(session.isSessionActive || session.isPreloadingModel)
        } else {
            Button("下载") { download(variant) }
        }
    }

    private func download(_ variant: ModelVariant) {
        Task {
            do {
                _ = try await downloadManager.ensureDownloaded(variant)
            } catch is CancellationError {
                // The user's own "取消" tap — not a failure worth an alert.
            } catch {
                errorTitle = "下载失败"
                errorMessage = error.localizedDescription
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
        } catch {
            errorTitle = "删除失败"
            errorMessage = error.localizedDescription
        }
    }
}
