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

    var body: some View {
        Form {
            Section("识别引擎 (ASR)") {
                Picker("引擎", selection: $session.transcriptionEngineID) {
                    ForEach(ProviderCatalog.transcriptionEngines) { engine in
                        Text(engine.displayName).tag(engine.id)
                    }
                }
                modelVariantPicker(for: session.transcriptionEngineID)
            }

            Section("翻译引擎") {
                Picker("引擎", selection: $session.translationEngineID) {
                    ForEach(ProviderCatalog.translationEngines) { engine in
                        Text(engine.displayName).tag(engine.id)
                    }
                }
                modelVariantPicker(for: session.translationEngineID)
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
        // calls against `discardPreloadedModelsIfStale()` unloading the very
        // providers it's still awaiting.
        .disabled(session.isSessionActive || session.isPreloadingModel)
    }

    @ViewBuilder
    private func modelVariantPicker(for engineID: String) -> some View {
        let variants = ProviderCatalog.modelVariants(forEngineID: engineID)
        if !variants.isEmpty {
            Picker("模型", selection: .constant(variants.first?.id)) {
                ForEach(variants) { variant in
                    Text("\(variant.displayName) · 约 \(variant.approximateSizeMB) MB")
                        .tag(Optional(variant.id))
                }
            }
            .disabled(true) // TODO: enable once Model*Provider is implemented (see their doc comments).
        }
    }
}
