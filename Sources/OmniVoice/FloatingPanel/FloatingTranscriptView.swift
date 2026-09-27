import OmniVoiceCore
import SwiftUI
import Translation

/// Content of the floating panel: a compact, semi-transparent live view of
/// the current recording's transcript/translation.
///
/// Also hosts the `.translationTask` bridge for `SystemTranslationProvider`
/// (see that type's doc, and `RecordingSession.translationBridgeStream()`) —
/// `TranslationSession` can only be vended inside a SwiftUI view, and this
/// view is the one guaranteed to be mounted for the app's entire lifetime
/// (created once by `AppDelegate`, only ever hidden/shown, never torn down),
/// which is exactly what that bridge's continuation needs.
struct FloatingTranscriptView: View {
    @ObservedObject var session: RecordingSession
    @State private var translationConfiguration: TranslationSession.Configuration?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if session.lines.isEmpty {
                    Text("等待开始…")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.lines) { line in
                    if !line.displaySource.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.displaySource)
                                .font(.system(size: 14, weight: .medium))
                            if !line.displayTranslation.isEmpty {
                                Text(line.displayTranslation)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 240)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { rebuildConfiguration() }
        .onChange(of: session.sourceLanguageCode) { rebuildConfiguration() }
        .onChange(of: session.targetLanguageCode) { rebuildConfiguration() }
        .translationTask(translationConfiguration) { translationSession in
            for await request in session.translationBridgeStream() {
                let result = try? await translationSession.translate(request.text)
                session.resolveTranslationBridgeResult(result?.targetText ?? "")
            }
        }
    }

    private func rebuildConfiguration() {
        translationConfiguration = TranslationSession.Configuration(
            source: session.currentSourceLanguage,
            target: session.currentTargetLanguage
        )
    }
}
