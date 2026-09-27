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
        VStack(spacing: 0) {
            controlBar
            Divider()
            transcriptList
        }
        .frame(width: 420, height: 280)
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

    /// Start/stop plus the two language pickers — the controls adjusted most
    /// often, so they live here instead of behind the Settings window.
    /// Pickers, not free-text fields: this panel is a non-activating,
    /// never-key `NSPanel` (see `FloatingTranscriptPanel.canBecomeKey`), and
    /// a `TextField` can't take keyboard input without a key window, while a
    /// menu-based `Picker` still works via a plain mouse click.
    private var controlBar: some View {
        HStack(spacing: 10) {
            Button(session.isRunning ? "停止" : "开始") {
                Task {
                    if session.isRunning {
                        await session.stop()
                    } else {
                        await session.start()
                    }
                }
            }
            .disabled(session.isStopping)

            // Source is disabled while running: it's only read once, at
            // `start()`, to configure the ASR engine for that recording
            // (`SpeechAnalyzer`'s locale can't change mid-session) — editing
            // it here wouldn't take effect until the next start.
            Picker("源语言", selection: $session.sourceLanguageCode) {
                Text("自动").tag(String?.none)
                ForEach(Self.languageOptions, id: \.code) { option in
                    Text(option.label).tag(Optional(option.code))
                }
            }
            .labelsHidden()
            .disabled(session.isRunning)

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)

            // Target stays editable while running: unlike source, it isn't
            // baked into a provider at `start()` — the `.translationTask`
            // above rebuilds `translationConfiguration` on every change, so
            // switching it mid-recording actually retargets the next
            // translated segment.
            Picker("目标语言", selection: $session.targetLanguageCode) {
                ForEach(Self.languageOptions, id: \.code) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .labelsHidden()
        }
        .padding(10)
    }

    private var transcriptList: some View {
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
    }

    private func rebuildConfiguration() {
        translationConfiguration = TranslationSession.Configuration(
            source: session.currentSourceLanguage,
            target: session.currentTargetLanguage
        )
    }

    private static let languageOptions: [(code: String, label: String)] = [
        ("zh-CN", "中文"),
        ("en-US", "英语"),
        ("ja-JP", "日语"),
        ("ko-KR", "韩语"),
        ("fr-FR", "法语"),
        ("de-DE", "德语"),
        ("es-ES", "西班牙语"),
    ]
}
