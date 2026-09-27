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
    /// Hides the panel — `panel.orderOut(nil)` via `AppDelegate`. Threaded
    /// in as a closure rather than reaching for `NSApp.delegate`/environment
    /// injection: this view is constructed directly as the panel's own
    /// content view, outside any SwiftUI `Scene`, so there's no environment
    /// to inject it through in the first place.
    let onClose: () -> Void
    @State private var translationConfiguration: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            transcriptList
            Divider()
            statusBar
        }
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
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
    /// menu-based `Picker` still works via a plain mouse click. (Settings
    /// uses the same `SourceLanguagePicker`/`TargetLanguagePicker` — not
    /// because it has this panel's key-window constraint, but so the two
    /// don't offer different language options.)
    private var controlBar: some View {
        HStack(spacing: 10) {
            Button(session.isRunning ? "停止" : (session.isStarting ? "启动中…" : "开始")) {
                Task {
                    if session.isRunning {
                        await session.stop()
                    } else {
                        await session.start()
                    }
                }
            }
            .disabled(session.isStopping || session.isStarting)

            // Disabled for the whole start→stop lifecycle (isSessionActive,
            // not just isRunning): it's only read once, at the top of
            // `start()`, to configure the ASR engine for that recording
            // (`SpeechAnalyzer`'s locale can't change mid-session) — editing
            // it during setup would either race that read or silently not
            // apply until the next start.
            SourceLanguagePicker(
                sourceLanguageCode: $session.sourceLanguageCode,
                transcriptionEngineKind: session.transcriptionEngineKind
            )
            .labelsHidden()
            .disabled(session.isSessionActive)

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)

            // Target stays editable while running: unlike source, it isn't
            // baked into a provider at `start()` — the `.translationTask`
            // above rebuilds `translationConfiguration` on every change, so
            // switching it mid-recording actually retargets the next
            // translated segment.
            TargetLanguagePicker(targetLanguageCode: $session.targetLanguageCode)
                .labelsHidden()

            Spacer()

            PanelCloseButton(action: onClose)
        }
        .padding(10)
    }

    private var transcriptList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Not `session.lines.isEmpty`: `start()` seeds `lines` with
                // one placeholder row before any real content ever arrives
                // (see `RecordingSession.start()`), so a session that failed
                // to start, or one that was stopped before anyone said
                // anything, still has a non-empty `lines` with nothing
                // displayable in it — `session.lines.isEmpty` alone would
                // leave the panel looking blank instead of showing this.
                if session.lines.allSatisfy(\.displaySource.isEmpty) {
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

    /// Surfaces `RecordingSession.statusMessage` (e.g. "识别引擎启动失败:
    /// ...") on the panel itself — without this, a failed `start()` gave no
    /// visible indication of what went wrong: the button just went back to
    /// "开始" and the transcript area stayed empty, and this message
    /// otherwise only ever appeared in the menu bar dropdown.
    private var statusBar: some View {
        Text(session.statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            // Longer messages (a localized error description tacked onto a
            // permission hint, say) get cut off by `.lineLimit(1)` at the
            // panel's default width — the tooltip is how the full text
            // stays reachable without needing to widen the panel.
            .help(session.statusMessage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private func rebuildConfiguration() {
        translationConfiguration = TranslationSession.Configuration(
            source: session.currentSourceLanguage,
            target: session.currentTargetLanguage
        )
    }
}

/// Themed replacement for the panel's native close button (hidden in
/// `FloatingTranscriptPanel` — a native traffic light looked out of place
/// with no titlebar). Understated by default, only picking up contrast on
/// hover, so it doesn't compete with the transcript for attention.
private struct PanelCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .background(.primary.opacity(isHovering ? 0.16 : 0.08), in: Circle())
                // Bigger than the visible glyph/background: this is the
                // panel's only close affordance (no titlebar), so a hit
                // target as small as the 18×18 circle itself makes it easy
                // to miss and instead hit the draggable background next to it.
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("隐藏悬浮窗")
        .accessibilityLabel("隐藏悬浮窗")
    }
}
