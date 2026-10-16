import OmniVoiceCore
import SwiftUI

/// Picker for one side of the 我的语言 / 外语 pair (Settings → 通用 → 语言).
/// Under the system recognizer the source side can't be one of the
/// languages it can't recognize — those stay offered on the other side,
/// where they are only ever a translation target.
struct LanguagePicker: View {
    @EnvironmentObject private var session: RecordingSession
    let title: String
    let selection: Binding<String>
    let isSourceSide: Bool

    init(_ title: String, selection: Binding<String>, isSourceSide: Bool) {
        self.title = title
        self.selection = selection
        self.isSourceSide = isSourceSide
    }

    var body: some View {
        let restricted = isSourceSide && session.transcriptionEngineKind == .system
        let options = restricted ? LanguageCatalog.common.filter(\.supportsSystemASRSource) : LanguageCatalog.common
        Picker(LocalizedStringKey(title), selection: selection) {
            ForEach(options) { option in
                Text(option.displayName).tag(option.code)
            }
            if !options.contains(where: { $0.code == selection.wrappedValue }) {
                Text("\(selection.wrappedValue) (custom)").tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .accessibilityLabel(LocalizedStringKey(title))
        .fixedSize()
        .disabled(isSourceSide && session.isSessionActive)
    }
}
