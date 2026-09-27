import AppKit
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
    @Environment(\.openWindow) private var openWindow
    /// Observed directly (not just reached through `session`) so
    /// `isEngineAvailable(_:)`/a downloaded variant's row live-update the
    /// moment "模型管理" (`ModelManagementView`) downloads or deletes
    /// something — `RecordingSession` no longer triggers downloads itself
    /// (see `resolveModelPath`'s doc) and doesn't re-publish on every
    /// download tick, only on `statusMessage` changes. Passed in explicitly
    /// (not defaulted to `.shared`) and expected to be the exact same
    /// instance `session` (injected separately, via `.environmentObject`,
    /// since `SettingsView()` is constructed before that's available) was
    /// itself given — see `RecordingSession.init`'s own injectable
    /// `modelDownloadManager` parameter. Hardcoding `.shared` here instead
    /// would silently observe the wrong manager for any `RecordingSession`
    /// constructed with a non-`shared` one (a test, an eventual SwiftUI
    /// preview).
    @ObservedObject private var downloadManager: ModelDownloadManager

    init(modelDownloadManager: ModelDownloadManager) {
        self.downloadManager = modelDownloadManager
    }

    var body: some View {
        Form {
            Section("识别引擎 (ASR)") {
                HStack {
                    Picker("引擎", selection: $session.transcriptionEngineID) {
                        ForEach(ProviderCatalog.transcriptionEngines.filter(isEngineAvailable)) { engine in
                            Text(engine.displayName).tag(engine.id)
                        }
                    }
                    modelManagementButton
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
                HStack {
                    Picker("引擎", selection: $session.translationEngineID) {
                        ForEach(ProviderCatalog.translationEngines.filter(isEngineAvailable)) { engine in
                            Text(engine.displayName).tag(engine.id)
                        }
                    }
                    modelManagementButton
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
        // providers it's still awaiting.
        .disabled(session.isSessionActive || session.isPreloadingModel)
    }

    /// Next to each engine `Picker` (not buried at the bottom of the form) —
    /// downloading/deleting a `.model`-kind engine's weights always happens
    /// in "模型管理" (`ModelManagementView`) now, never inline here, so this
    /// is the whole form's only way back to it. `.disabled(false)` overrides
    /// the form-wide `.disabled` above — opening a window doesn't touch
    /// engine/model selection, so there's no race with an in-flight
    /// preload/recording to guard against.
    private var modelManagementButton: some View {
        Button("模型管理…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "modelManagement")
        }
        .disabled(false)
    }

    /// A `.model`-kind engine only shows up in the engine `Picker` above once
    /// something for it has been downloaded — bootstrapping a brand-new
    /// engine always goes through the "模型管理" window instead (see
    /// `ModelManagementView`), which lists every catalog variant regardless
    /// of download state.
    private func isEngineAvailable(_ engine: EngineDescriptor) -> Bool {
        guard engine.kind == .model else { return true }
        return ProviderCatalog.modelVariants(forEngineID: engine.id)
            .contains { downloadManager.isDownloaded($0) }
    }

    /// Only lists *downloaded* variants — a not-yet-downloaded one has
    /// nothing useful to show here (nothing to select, nothing to act on;
    /// downloading only ever happens from "模型管理" now), so it's simply
    /// left out rather than shown disabled or with its own download button.
    /// An engine is only ever listed above once at least one of its variants
    /// is downloaded (see `isEngineAvailable(_:)`), so this `Picker` never
    /// ends up empty.
    @ViewBuilder
    private func modelVariantPicker(for engineID: String, selection: Binding<String?>) -> some View {
        let downloaded = ProviderCatalog.modelVariants(forEngineID: engineID).filter { downloadManager.isDownloaded($0) }
        if !downloaded.isEmpty {
            Picker("模型", selection: selection) {
                ForEach(downloaded) { variant in
                    Text("\(variant.displayName) · 约 \(variant.approximateSizeMB) MB")
                        .tag(Optional(variant.id))
                }
            }
        }
    }
}
