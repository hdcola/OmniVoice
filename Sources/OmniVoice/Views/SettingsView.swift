import OmniVoiceCore
import SwiftUI

/// Engine settings — data-driven from `ProviderCatalog` rather than one
/// hand-written `case` per engine, so adding a new community model
/// audio.cpp supports later is a catalog change, not a UI change. Disabled
/// while a recording is running, same rule the POCs established (each
/// provider's session is set up fresh at `start()`).
///
/// Language pickers and the mic/system-audio toggle live on the floating
/// panel and the menu bar respectively instead of here — those are the
/// controls adjusted most often, and this window is reserved for the ones
/// that aren't (which engine, eventually which model variant).
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
        }
        .padding(20)
        .frame(width: 440)
        .disabled(session.isRunning)
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
