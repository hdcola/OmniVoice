import OmniVoiceCore
import SwiftUI

/// Shared quick-pick source-language `Picker`, used by both the floating
/// panel and Settings so their behavior can't drift apart — see
/// `RecordingSession.sourceLanguageCode`'s doc for why "自动" only appears
/// for a `.model`-kind engine, and `LanguageCatalog`'s doc for the
/// source/target support asymmetry a couple of its options have.
struct SourceLanguagePicker: View {
    @Binding var sourceLanguageCode: String?
    let transcriptionEngineKind: EngineKind?

    /// The system ASR engine can't recognize a handful of `LanguageCatalog`
    /// entries at all (`supportsSystemASRSource == false`) — offering them
    /// here while `.system` is selected would be a guaranteed-to-fail trap,
    /// since picking one and hitting start throws every time.
    private var options: [LanguageOption] {
        transcriptionEngineKind == .system
            ? LanguageCatalog.common.filter(\.supportsSystemASRSource)
            : LanguageCatalog.common
    }

    var body: some View {
        Picker("源语言", selection: $sourceLanguageCode) {
            if transcriptionEngineKind == .model {
                Text("自动").tag(String?.none)
            }
            ForEach(options) { option in
                Text(option.displayName).tag(Optional(option.code))
            }
            // Only ever matches a value persisted by an older build (before
            // free-text entry was removed in favor of this picker) — kept
            // so that value still displays instead of looking blank/broken.
            if let custom = sourceLanguageCode,
               !options.contains(where: { $0.code == custom }) {
                Text("\(custom)（自定义）").tag(Optional(custom))
            }
        }
    }
}

/// Shared quick-pick target-language `Picker` — see `SourceLanguagePicker`'s
/// doc. Unlike source, target has no "自动" case (`RecordingSession.targetLanguageCode`
/// is never optional) and isn't gated by engine kind.
struct TargetLanguagePicker: View {
    @Binding var targetLanguageCode: String

    var body: some View {
        Picker("目标语言", selection: $targetLanguageCode) {
            ForEach(LanguageCatalog.common) { option in
                Text(option.displayName).tag(option.code)
            }
            if !LanguageCatalog.common.contains(where: { $0.code == targetLanguageCode }) {
                Text("\(targetLanguageCode)（自定义）").tag(targetLanguageCode)
            }
        }
    }
}
