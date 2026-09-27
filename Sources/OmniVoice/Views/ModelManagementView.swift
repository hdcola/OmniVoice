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
            "下载失败",
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
                Text("\(variant.displayName) · \(variant.quantization)")
                if let fraction = downloadManager.downloadProgress[variant.id] {
                    Text("下载中… \(Int(fraction * 100))%")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    ProgressView(value: fraction)
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
        if downloadManager.downloadProgress[variant.id] != nil {
            Button("取消") { downloadManager.cancelDownload(for: variant) }
        } else if downloadManager.isDownloaded(variant) {
            Button("删除") { pendingDeletion = variant }
        } else {
            Button("下载") { download(variant) }
        }
    }

    private func download(_ variant: ModelVariant) {
        Task {
            do {
                _ = try await downloadManager.ensureDownloaded(variant)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ variant: ModelVariant) {
        do {
            try downloadManager.deleteCachedModel(for: variant)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
