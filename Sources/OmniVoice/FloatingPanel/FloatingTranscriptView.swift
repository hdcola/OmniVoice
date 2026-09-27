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
            Button {
                Task {
                    if session.isRunning {
                        await session.stop()
                    } else {
                        await session.start()
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    // Only while `isStarting` — a cold `start()` (no
                    // preloaded model yet) does the exact same
                    // possibly-multi-second `loadModel()` work
                    // `preloadButton` guards, just without a warning first.
                    // Without this spinner that stretch had zero visual
                    // feedback beyond the static "启动中…" label — with the
                    // main-actor-blocking bug fixed (see
                    // `InProcessTranscriber.loadModel(modelPath:)`'s doc),
                    // the window itself stays responsive through it, so this
                    // is what actually shows something's happening.
                    if session.isStarting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(session.isRunning ? "停止" : (session.isStarting ? "启动中…" : "开始"))
                }
            }
            .disabled(session.isStopping || session.isStarting || session.isPreloadingModel)

            // Only worth surfacing for a `.model`-kind engine (a `.system`
            // engine's `loadModel()` is a no-op) — see `usesOnDeviceModelEngine`'s
            // doc. Placed next to start/stop rather than in Settings: this
            // is the button meant to be pressed right before hitting "开始",
            // not a one-time configuration choice.
            if session.usesOnDeviceModelEngine {
                preloadButton
            }

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

    /// A one-shot "预加载模型" affordance, separate from the start/stop
    /// button — see `RecordingSession.preloadModel()`'s doc for why that's a
    /// standalone entry point. Collapses to a static "已就绪" label once
    /// loaded (rather than staying a now-redundant, still-clickable button)
    /// since a second tap would just no-op against `preloadModel()`'s own
    /// `isModelLoaded` guard.
    @ViewBuilder
    private var preloadButton: some View {
        if session.isModelLoaded {
            Label("模型已就绪", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Button {
                Task { await session.preloadModel() }
            } label: {
                HStack(spacing: 5) {
                    // A visible spinner while `loadModel()` is in flight —
                    // without this, the button just sat on a static "加载
                    // 中…" label for however many seconds R2T2/T3PO's
                    // weights took to read, which (before
                    // `InProcessTranscriber`/`InProcessTranslator.loadModel(modelPath:)`
                    // stopped blocking the main actor synchronously — see
                    // their doc) used to coincide with the entire window
                    // being genuinely frozen, not just looking idle. Now
                    // that the load runs off the main actor, this spinner
                    // animates the whole time, which is itself confirmation
                    // the window hasn't hung.
                    if session.isPreloadingModel {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(session.isPreloadingModel ? "加载中…" : "预加载模型")
                }
            }
            .disabled(session.isSessionActive || session.isPreloadingModel)
        }
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
        HStack(spacing: 6) {
            // Only shown while actually running: `session.inputLevel` is
            // reset to 0 on `stop()`, but a static muted mic icon sitting
            // here at rest would read as "not picking up sound" rather than
            // "not recording" — gating on `isRunning` avoids that confusion.
            if session.isRunning {
                micLevelIndicator
            }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Live feedback that audio is actually being picked up — without this,
    /// nothing on the panel changed between "转写中…" with the mic silent vs.
    /// the mic capturing normally, so a misconfigured input device (wrong
    /// mic selected, muted, unplugged) looked identical to a working one
    /// until text failed to show up. Scales with `session.inputLevel`
    /// (0...1, see `AudioMixer.onLevel`'s doc) rather than just toggling
    /// on/off, so it reads as a level meter, not just a "recording" light.
    private var micLevelIndicator: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 10))
            .foregroundStyle(.red)
            .scaleEffect(1 + CGFloat(session.inputLevel) * 0.5)
            .animation(.easeOut(duration: 0.1), value: session.inputLevel)
            .accessibilityLabel("正在收音")
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
