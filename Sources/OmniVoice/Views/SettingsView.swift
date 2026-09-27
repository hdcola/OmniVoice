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
/// The common-language pickers and the mic/system-audio toggle live on the
/// floating panel and the menu bar respectively instead of here — those are
/// the controls adjusted most often, and this window is reserved for the
/// ones that aren't (which engine, eventually which model variant). This
/// window keeps one advanced escape hatch: free-text BCP-47 entry for a
/// language outside `LanguageCatalog.common`'s curated list (this is a real
/// window, unlike the panel, so a `TextField` here can actually take
/// keyboard input — see `FloatingTranscriptView`'s doc on why it can't).
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

            Section("语言（自定义代码）") {
                Text("常用语言可直接在悬浮窗控制条里切换；这里输入的是不在那份列表里的自定义 BCP-47 代码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("源语言代码（如 en-US；留空为自动，仅模型引擎支持）", text: sourceLanguageBinding)
                TextField("目标语言代码（如 zh-CN）", text: $session.targetLanguageCode)
            }
        }
        .padding(20)
        .frame(width: 440)
        .disabled(session.isSessionActive)
    }

    private var sourceLanguageBinding: Binding<String> {
        Binding(
            get: { session.sourceLanguageCode ?? "" },
            set: { session.sourceLanguageCode = $0.isEmpty ? nil : $0 }
        )
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
