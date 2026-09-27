import OmniVoiceCore
import SwiftUI

/// Engine settings — data-driven from `ProviderCatalog` rather than one
/// hand-written `case` per engine, so adding a new community model
/// audio.cpp supports later is a catalog change, not a UI change. Disabled
/// for the whole start→stop lifecycle (`isSessionActive`, not just
/// `isRunning`) — each provider's session is set up fresh from these values
/// at the top of `start()`, so changing them during that setup would either
/// race the read or silently not apply to the run in progress.
///
/// The mic/system-audio toggle lives on the menu bar instead of here — it's
/// adjusted often enough to want quicker access, while this window is
/// reserved for the ones that aren't (which engine, eventually which model
/// variant). Language uses the same `SourceLanguagePicker`/
/// `TargetLanguagePicker` the floating panel does — not a free-text field —
/// so the two can't ever offer different language options.
struct SettingsView: View {
    @EnvironmentObject private var session: RecordingSession
    /// Observed directly (not just reached through `session`) so a variant
    /// row's "已下载"/"约 N MB" caption live-updates while
    /// `ModelDownloadManager.ensureDownloaded(_:progress:)` runs during
    /// `preloadModel()`/`start()` — `RecordingSession` itself doesn't
    /// re-publish on every download tick, only on `statusMessage` changes.
    /// Passed in explicitly (not defaulted to `.shared`) and expected to be
    /// the exact same instance `session` (injected separately, via
    /// `.environmentObject`, since `SettingsView()` is constructed before
    /// that's available) was itself given — see `RecordingSession.init`'s
    /// own injectable `modelDownloadManager` parameter. Hardcoding `.shared`
    /// here instead would silently observe the wrong manager for any
    /// `RecordingSession` constructed with a non-`shared` one (a test, an
    /// eventual SwiftUI preview).
    @ObservedObject private var downloadManager: ModelDownloadManager

    init(modelDownloadManager: ModelDownloadManager) {
        self.downloadManager = modelDownloadManager
    }

    var body: some View {
        Form {
            Section("识别引擎 (ASR)") {
                Picker("引擎", selection: $session.transcriptionEngineID) {
                    ForEach(ProviderCatalog.transcriptionEngines) { engine in
                        Text(engine.displayName).tag(engine.id)
                    }
                }
                modelVariantPicker(
                    for: session.transcriptionEngineID,
                    selection: Binding(
                        get: { session.currentTranscriptionModelVariant?.id },
                        set: { session.transcriptionModelVariantID = $0 }
                    )
                )
            }

            Section("翻译引擎") {
                Picker("引擎", selection: $session.translationEngineID) {
                    ForEach(ProviderCatalog.translationEngines) { engine in
                        Text(engine.displayName).tag(engine.id)
                    }
                }
                modelVariantPicker(
                    for: session.translationEngineID,
                    selection: Binding(
                        get: { session.currentTranslationModelVariant?.id },
                        set: { session.translationModelVariantID = $0 }
                    )
                )
            }

            Section("语言") {
                SourceLanguagePicker(
                    sourceLanguageCode: $session.sourceLanguageCode,
                    transcriptionEngineKind: session.transcriptionEngineKind
                )
                TargetLanguagePicker(targetLanguageCode: $session.targetLanguageCode)
            }
        }
        .padding(20)
        .frame(width: 440)
        // `isPreloadingModel` alongside `isSessionActive`: switching engines
        // mid-preload would race `preloadModel()`'s in-flight `loadModel()`
        // calls against `discardLoadedModelsIfStale()` unloading the very
        // providers it's still awaiting. Also covers a variant's own
        // download: that only ever runs from inside `preloadModel()`/
        // `start()`, both already gated by these same two flags.
        .disabled(session.isSessionActive || session.isPreloadingModel)
    }

    @ViewBuilder
    private func modelVariantPicker(for engineID: String, selection: Binding<String?>) -> some View {
        let variants = ProviderCatalog.modelVariants(forEngineID: engineID)
        if !variants.isEmpty {
            Picker("模型", selection: selection) {
                ForEach(variants) { variant in
                    Text("\(variant.displayName) · \(variantCaption(for: variant))")
                        .tag(Optional(variant.id))
                }
            }
        }
    }

    /// "约 N MB" for a not-yet-downloaded variant, "已下载 · 约 N MB" once
    /// `ModelDownloadManager` has it cached, or a live "下载中… N%" while
    /// `preloadModel()`/`start()` are actively fetching it — the same
    /// `downloadProgress` a floating-panel progress view would observe.
    private func variantCaption(for variant: ModelVariant) -> String {
        if let fraction = downloadManager.downloadProgress[variant.id] {
            return "下载中… \(Int(fraction * 100))%"
        }
        if downloadManager.isDownloaded(variant) {
            return "已下载 · 约 \(variant.approximateSizeMB) MB"
        }
        return "约 \(variant.approximateSizeMB) MB"
    }
}
