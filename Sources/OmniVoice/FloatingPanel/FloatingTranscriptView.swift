import AppKit
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
    /// Whether the control bar/status bar are shown — proposal 3.1.A
    /// ("沉浸字幕模式与自动隐藏"): true while the mouse is over the panel or
    /// has been for less than `Self.autoHideDelay` since it left, false
    /// once that delay elapses, so a full-screen slide/video behind the
    /// panel isn't permanently competing with idle chrome for attention.
    @State private var isControlsVisible = true
    @State private var isLanguagePopoverPresented = false
    @State private var autoHideTask: Task<Void, Never>?
    /// A popover from the control bar is open (see `PanelPopoverOpenKey`),
    /// and whether the pointer is over the panel itself — together they
    /// decide when the controls may fade out.
    @State private var isPopoverOpen = false
    @State private var isPointerInside = false
    private static let autoHideDelay: Duration = .seconds(2)

    var body: some View {
        VStack(spacing: 0) {
            // Always kept in the view hierarchy (never structurally
            // inserted/removed based on `isControlsVisible`) and faded via
            // `.opacity` instead — a structural insert/remove here shrinks
            // `TranscriptListView`'s container height without changing its
            // content height, which `.onScrollGeometryChange` misreads as
            // "the user scrolled away" and unpins auto-scroll just from a
            // mouse hover. `.allowsHitTesting(false)` while hidden keeps an
            // invisible control bar/status bar from intercepting hover/clicks
            // meant for the transcript beneath them.
            controlBar
                .opacity(isControlsVisible ? 1 : 0)
                .allowsHitTesting(isControlsVisible)
            Divider()
                .opacity(isControlsVisible ? 1 : 0)
            // `.equatable()`: `TranscriptListView` takes `lines`/`isRunning`
            // as plain values rather than observing `session` itself — see
            // its own doc for why, and why that's the point of pulling it
            // out of this view in the first place.
            TranscriptListView(
                lines: session.lines,
                isRunning: session.isRunning,
                displayMode: session.panelDisplayMode,
                fontScale: session.panelFontScale
            )
            .equatable()
            // Not faded with the controls: a missing permission is the one
            // thing on the panel the user has to act on. Inserted only when
            // the permission flag flips, never on hover (see above).
            ForEach(permissionIssues) { issue in
                permissionBanner(issue)
            }
            statusBar
                .opacity(isControlsVisible ? 1 : 0)
                .allowsHitTesting(isControlsVisible)
        }
        .animation(.easeInOut(duration: 0.2), value: isControlsVisible)
        // Applied to the whole content stack, not the background below —
        // `session.panelContentOpacity`/`panelBackgroundOpacity` are
        // deliberately independent (see the former's doc): fading the
        // transcript/controls must never also fade the background material
        // (or vice versa), which is exactly what a single window-level
        // `NSWindow.alphaValue` couldn't do.
        .opacity(session.panelContentOpacity)
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .opacity(session.panelBackgroundOpacity)
        )
        .onHover { isHovering in
            isPointerInside = isHovering
            autoHideTask?.cancel()
            if isHovering {
                isControlsVisible = true
            } else {
                scheduleAutoHide()
            }
        }
        .onPreferenceChange(PanelPopoverOpenKey.self) { isPopoverOpen = $0 }
        .onChange(of: isPopoverOpen) {
            if isPopoverOpen {
                autoHideTask?.cancel()
                isControlsVisible = true
            } else if !isPointerInside {
                // The pointer left while the popover was up (into it, or
                // away): no hover event will follow, so restart the timer.
                scheduleAutoHide()
            }
        }
        .onAppear { rebuildConfiguration() }
        .onChange(of: session.sourceLanguageCode) { rebuildConfiguration() }
        .onChange(of: session.targetLanguageCode) { rebuildConfiguration() }
        .translationTask(translationConfiguration) { translationSession in
            for await request in session.translationBridgeStream() {
                // An empty-text request is a boundary-only "sentinel" (see
                // `TranslationBridgeRequest.text`'s doc) — nothing to
                // translate, so skip the round-trip and resolve it
                // immediately. Consuming this stream strictly in order (one
                // `await` fully finishing before the next iteration even
                // starts) is exactly what lets `SystemTranslationProvider`
                // rely on a sentinel to preserve ordering without its own
                // counting/flag bookkeeping.
                if request.text.isEmpty {
                    session.resolveTranslationBridgeResult("", isFinal: request.isFinal)
                    continue
                }
                let result = try? await translationSession.translate(request.text)
                session.resolveTranslationBridgeResult(result?.targetText ?? "", isFinal: request.isFinal)
            }
        }
    }

    /// Fades the controls out after `autoHideDelay`, unless a popover is
    /// open by then.
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(for: Self.autoHideDelay)
            guard !Task.isCancelled, !isPopoverOpen else { return }
            isControlsVisible = false
        }
    }

    // MARK: - Control bar

    /// Five controls: start/stop (with the timer and mic level folded in),
    /// the language pair, display options, copy and close. Everything that
    /// changes less often than once per recording lives one click deeper,
    /// so the bar fits the panel's minimum width without fallback layouts.
    ///
    /// Menus and popovers rather than text fields throughout: this panel is
    /// a non-activating, never-key `NSPanel` (see
    /// `FloatingTranscriptPanel.canBecomeKey`), and a `TextField` can't take
    /// keyboard input without a key window, while a menu or popover still
    /// works from a plain mouse click.
    private var controlBar: some View {
        HStack(spacing: 8) {
            transcriptionButton
            languageChip
                .layoutPriority(-1)
            Spacer(minLength: 0)
            displayOptionsMenu
            CopyGlyphButton(help: "Copy All", text: fullTranscriptText)
                .disabled(session.lines.allSatisfy(\.displaySource.isEmpty))
            PanelCloseButton(action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Start/stop as one capsule: a red dot when idle, a stop square plus the
    /// elapsed time and a live input level while transcribing, a spinner
    /// while starting. The timer and level used to be separate controls in
    /// the bar and the status bar; next to the button they answer "is it
    /// listening, and does it hear me" in one place.
    private var transcriptionButton: some View {
        Button {
            Task {
                if session.isRunning {
                    await session.stop()
                } else {
                    await session.start()
                }
            }
        } label: {
            HStack(spacing: 6) {
                recordGlyph
                    .frame(width: 16, height: 16)
                Text(transcriptionButtonTitle)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                if session.isRunning {
                    InputLevelBars(level: session.inputLevel)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .frame(height: 26)
            .background(Color.primary.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Same rule as before: no start while a preload is in flight, no
        // double start/stop while one is already under way.
        .disabled(session.isStopping || session.isStarting || session.isPreloadingModel)
        .accessibilityLabel(session.isRunning ? String(localized: "Stop Transcription") : String(localized: "Start Transcription"))
        .accessibilityValue(session.isRunning ? session.elapsedTimeString : "")
    }

    private var transcriptionButtonTitle: String {
        if session.isRunning { return session.elapsedTimeString }
        if session.isStarting { return String(localized: "Starting…") }
        return String(localized: "Start")
    }

    @ViewBuilder
    private var recordGlyph: some View {
        if session.isStarting {
            ProgressView()
                .controlSize(.mini)
        } else {
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.5)
                if session.isRunning {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                }
            }
        }
    }

    /// "英语 → 简体中文" — the source and target pickers, the ⇄ swap and
    /// why a swap is blocked, all behind one chip. They used to take three
    /// controls (and a popover of their own for the blocked-swap reason) in
    /// the bar.
    private var languageChip: some View {
        Button {
            isLanguagePopoverPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(sourceLanguageName)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(LanguageCatalog.localizedName(for: session.targetLanguageCode))
                if TargetLanguagePicker.showsLanguageWarning(
                    translationEngineID: session.translationEngineID,
                    targetLanguageCode: session.targetLanguageCode
                ) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                Color.primary.opacity(isLanguagePopoverPresented ? 0.16 : 0.1),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Language")
        .accessibilityValue("\(sourceLanguageName) → \(LanguageCatalog.localizedName(for: session.targetLanguageCode))")
        .preference(key: PanelPopoverOpenKey.self, value: isLanguagePopoverPresented)
        .popover(isPresented: $isLanguagePopoverPresented, arrowEdge: .bottom) {
            languagePopover
        }
    }

    private var sourceLanguageName: String {
        session.sourceLanguageCode.map(LanguageCatalog.localizedName(for:)) ?? String(localized: "Auto-detect")
    }

    private var languagePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Source language")
                        .foregroundStyle(.secondary)
                    // Disabled for the whole start→stop lifecycle
                    // (isSessionActive, not just isRunning): it's only read
                    // once, at the top of `start()`, to configure the ASR
                    // engine for that recording (`SpeechAnalyzer`'s locale
                    // can't change mid-session).
                    SourceLanguagePicker(
                        sourceLanguageCode: $session.sourceLanguageCode,
                        transcriptionEngineKind: session.transcriptionEngineKind,
                        transcriptionEngineID: session.transcriptionEngineID,
                        transcriptionVariantID: session.currentTranscriptionModelVariant?.id,
                        allowsAuto: session.languages.transcriptionDirection == .listenForeign
                    )
                    .labelsHidden()
                    .disabled(session.isSessionActive)
                    .fixedSize()
                }
                GridRow {
                    Text("Target language")
                        .foregroundStyle(.secondary)
                    // Target stays editable while running: unlike source, it
                    // isn't baked into a provider at `start()` — the
                    // `.translationTask` above rebuilds
                    // `translationConfiguration` on every change, so
                    // switching it mid-recording retargets the next
                    // translated segment.
                    TargetLanguagePicker(
                        targetLanguageCode: $session.targetLanguageCode,
                        translationEngineID: session.translationEngineID,
                        onSwitchToSystemTranslation: { session.translationEngineID = "system.translation" },
                        isSessionActive: session.isSessionActive
                    )
                    .labelsHidden()
                    .fixedSize()
                }
            }
            // Swaps source and target (听外语 ⇄ 说我的语言). Not while a
            // recording runs (the source is fixed at `start()`). "自动" survives
            // a swap — it comes back when swapping back. The reason it's
            // blocked is written right under it: a tooltip never shows in
            // this panel, which is never key.
            Button {
                session.swapTranscriptionDirection()
            } label: {
                Label("Swap source and target languages", systemImage: "arrow.left.arrow.right")
            }
            .disabled(!session.canSwapTranscriptionDirection)
            if let reason = session.swapBlockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    /// Display mode (双语对照 / 仅译文 / 仅原文) and font size, set rarely
    /// enough to live in one icon menu at every panel width.
    private var displayOptionsMenu: some View {
        Menu {
            displayModePicker
            fontScalePicker
        } label: {
            Image(systemName: "textformat.size")
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        // `.button` + `.plain` rather than `.borderlessButton`: the latter
        // is drawn by AppKit and ignores the label's `.secondary` style, so
        // the icon rendered brighter than the neighboring copy button.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Display options")
        .accessibilityLabel("Display options")
    }

    private var displayModePicker: some View {
        Picker("Display mode", selection: $session.panelDisplayMode) {
            ForEach(PanelDisplayMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
    }

    private var fontScalePicker: some View {
        Picker("Font size", selection: $session.panelFontScale) {
            ForEach(PanelFontScale.allCases, id: \.self) { scale in
                Text(scale.displayName).tag(scale)
            }
        }
    }

    /// Every closed/in-progress transcript line as plain bilingual text
    /// (source line, translation line below it) — same shape as
    /// `SessionDetailView`'s "复制全文", just sourced from the live
    /// in-memory `session.lines` instead of a persisted `RecordingSessionRecord`.
    private func fullTranscriptText() -> String {
        session.lines
            .filter { !$0.displaySource.isEmpty }
            .map { line in
                line.displayTranslation.isEmpty
                    ? line.displaySource
                    : "\(line.displaySource)\n\(line.displayTranslation)"
            }
            .joined(separator: "\n\n")
    }

    // MARK: - Problems and status

    private enum PermissionIssue: String, Identifiable {
        case microphone
        case screenRecording

        var id: String { rawValue }

        var message: String {
            switch self {
            case .microphone: return String(localized: "Grant microphone access in System Settings")
            case .screenRecording: return String(localized: "Grant screen recording access in System Settings")
            }
        }

        var systemImage: String {
            switch self {
            case .microphone: return "mic.slash"
            case .screenRecording: return "display"
            }
        }

        var settingsURL: URL {
            switch self {
            case .microphone: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .screenRecording: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    private var permissionIssues: [PermissionIssue] {
        var issues: [PermissionIssue] = []
        if session.microphonePermissionNeeded { issues.append(.microphone) }
        if session.screenRecordingPermissionNeeded { issues.append(.screenRecording) }
        return issues
    }

    /// One missing permission, with a one-tap deeplink straight to the
    /// relevant System Settings privacy pane (proposal 3.4.C).
    private func permissionBanner(_ issue: PermissionIssue) -> some View {
        HStack(spacing: 8) {
            Image(systemName: issue.systemImage)
                .foregroundStyle(.orange)
            Text(issue.message)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Open System Settings") {
                NSWorkspace.shared.open(issue.settingsURL)
            }
            .controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    /// Status text that adds something to what the start/stop capsule says
    /// (an engine loading, a start that failed, a model not downloaded),
    /// plus the model preload/release control. Routine text — not started,
    /// transcribing, stopped — is left out (`isStatusMessageRoutine`).
    private var statusBar: some View {
        HStack(spacing: 6) {
            if !session.isStatusMessageRoutine {
                Text(session.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(session.statusMessage)
            }
            Spacer(minLength: 0)
            // `.layoutPriority(1)`: a long status message truncates before
            // the actionable control here gets squeezed out.
            modelStatusControl
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Model preload/loaded/release affordance in the status bar's
    /// bottom-right corner — out of the way of the controls used on every
    /// recording, still visible without digging for it. Only worth
    /// surfacing for a `.model`-kind engine at all — a `.system` engine's
    /// `loadModel()` is a no-op, so there's nothing to preload or release
    /// (see `usesOnDeviceModelEngine`'s doc).
    @ViewBuilder
    private var modelStatusControl: some View {
        if session.usesOnDeviceModelEngine {
            if session.hasLoadedModels {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    // A translation-only launch preload leaves the recognizer
                    // unloaded (`start()` loads it); still releasable here.
                    Text(session.isModelLoaded ? String(localized: "Model ready") : String(localized: "Translation model ready"))
                    // The escape hatch for reclaiming memory sooner than an
                    // engine switch or app quit. Disabled (not just a no-op)
                    // while a recording is active: a button that silently
                    // does nothing reads as broken.
                    Button {
                        session.unloadModels()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(session.isSessionActive)
                    .help("Unload model")
                }
                .font(.caption)
            } else {
                Button {
                    Task { await session.preloadModel() }
                } label: {
                    HStack(spacing: 5) {
                        // Animates the whole time `loadModel()` runs off the
                        // main actor — itself confirmation the window hasn't hung.
                        if session.isPreloadingModel {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(session.isPreloadingModel ? String(localized: "Loading…") : String(localized: "Preload Model"))
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(session.isSessionActive || session.isPreloadingModel)
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

/// Four small bars that rise with the microphone level — next to the timer
/// in the start/stop capsule. Without it a misconfigured input device (wrong
/// mic, muted, unplugged) looked identical to a working one until text
/// failed to show up. Scales with `level` (0...1, see `AudioMixer.onLevel`)
/// rather than toggling on/off, so it reads as a meter.
private struct InputLevelBars: View {
    let level: Float
    private static let weights: [CGFloat] = [0.55, 1, 0.75, 0.9]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.green)
                    .frame(width: 2, height: 3 + CGFloat(level) * 9 * Self.weights[index])
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityLabel("Microphone is receiving audio")
    }
}

/// A copy icon that turns into a green check for a moment after a click —
/// the panel's only copy feedback, since it never becomes key and a toast
/// would sit over the transcript.
private struct CopyGlyphButton: View {
    let help: LocalizedStringKey
    var size: CGFloat = 13
    let text: () -> String
    @State private var didCopy = false

    var body: some View {
        Button {
            Clipboard.copy(text())
            didCopy = true
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: size))
                .foregroundStyle(didCopy ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

/// The scrollable transcript itself, pulled out of `FloatingTranscriptView`
/// so that view's very-high-frequency, unrelated `@Published` changes (chiefly
/// `session.inputLevel`, ticking ~10-15×/sec while recording — see
/// `InputLevelBars`' doc) don't force a full re-diff of what can be
/// hundreds of transcript rows on every single tick. Takes `lines`/`isRunning`
/// as plain values instead of observing `session` directly, and the call site
/// applies `.equatable()` — together, that lets SwiftUI skip this view's
/// `body` entirely on a re-render that didn't actually change either value.
///
/// `Equatable` is hand-written, not synthesized: `isPinnedToBottom` is
/// `@State`, and `State<Bool>` itself isn't `Equatable`, so automatic
/// synthesis can't see past it anyway — which is the right outcome here,
/// since whether the view is pinned isn't part of "did the *content*
/// change", the question `.equatable()` is actually asking.
private struct TranscriptListView: View, Equatable {
    let lines: [TranscriptLine]
    let isRunning: Bool
    let displayMode: PanelDisplayMode
    let fontScale: PanelFontScale

    static func == (lhs: TranscriptListView, rhs: TranscriptListView) -> Bool {
        lhs.lines == rhs.lines && lhs.isRunning == rhs.isRunning
            && lhs.displayMode == rhs.displayMode && lhs.fontScale == rhs.fontScale
    }

    /// Whether this view should keep pinning itself to the bottom as new
    /// content arrives. Driven by `.onScrollGeometryChange` (true whenever
    /// the scroll position is at/near the bottom, false the moment the user
    /// scrolls up to read earlier lines) rather than a manual gesture
    /// handler — that's the only reliable way to distinguish "the user
    /// scrolled up on purpose" from "this view's own `scrollTo` call just
    /// moved the position", since both look identical to a plain drag
    /// handler.
    @State private var isPinnedToBottom = true
    /// True for the duration of `jumpToLatestButton`'s animated `scrollTo`.
    /// Without this, `.onScrollGeometryChange` sees several intermediate
    /// frames of that 0.2s animation where the geometry has moved (so
    /// `contentSize` is unchanged) but hasn't reached the bottom tolerance
    /// yet — indistinguishable, by that check alone, from a genuine user
    /// drag away from the bottom — and would flip `isPinnedToBottom` back
    /// to `false` mid-animation, missing any content that arrives in that
    /// window. Cleared the moment the animation actually lands at the
    /// bottom (`isAtBottom == true` below) — normally, not on a timer — but
    /// `jumpToLatestButton` also clears it unconditionally ~350ms after
    /// starting the scroll, as a fallback: if the animation gets
    /// interrupted (a hard scroll-wheel/trackpad swipe mid-flight) or never
    /// quite lands within `bottomProximityTolerance`, `isAtBottom` would
    /// never fire and this would otherwise get stuck `true` forever,
    /// permanently disabling the real "user scrolled away" detection this
    /// flag exists to protect from a false positive.
    @State private var isProgrammaticScrollInFlight = false

    /// Id of the zero-height row appended after the real transcript lines —
    /// `scrollTo(_:anchor:)` targets this instead of the last line's own id
    /// so it always lands at the true bottom of the content, not just the
    /// last line's top edge (which would leave a multi-line-wrapped last
    /// entry's tail still off-screen).
    private static let bottomAnchorID = "transcriptList.bottomAnchor"
    /// How close to the bottom (in points) still counts as "at the bottom"
    /// for `.onScrollGeometryChange` below — a plain `>=` against the exact
    /// bottom offset would read as "scrolled away" from sub-pixel rounding
    /// alone, immediately unpinning on every single append.
    private static let bottomProximityTolerance: CGFloat = 24

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Not `lines.isEmpty`: `start()` seeds `lines` with one
                    // placeholder row before any real content ever arrives
                    // (see `RecordingSession.start()`), so a session that
                    // failed to start, or one that was stopped before anyone
                    // said anything, still has a non-empty `lines` with
                    // nothing displayable in it — `lines.isEmpty` alone
                    // would leave the panel looking blank instead of showing
                    // this.
                    if lines.allSatisfy(\.displaySource.isEmpty) {
                        // Says what to do next instead of a bare "waiting":
                        // listening once started, how to start otherwise.
                        Text(isRunning ? String(localized: "Listening…") : String(localized: "Click Start to begin transcription"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        if !line.displaySource.isEmpty {
                            TranscriptLineRow(line: line, displayMode: displayMode, fontScale: fontScale)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Tracks whether the user is (still) looking at the bottom of
            // the transcript. Compares the *whole* geometry (not just a
            // derived `isAtBottom` bool) so it can tell apart two cases that
            // both momentarily read as "not at the bottom": the user
            // actually dragging away, vs. new content simply having grown
            // `contentSize` out from under a `contentOffset` that hasn't
            // caught up yet (true on every single append while pinned,
            // since `scrollTo` below only fires *after* this same content
            // change and needs its own layout pass to land) — the plain
            // "isAtBottom ? true : false" version of this used to treat
            // that second case as "the user scrolled away", permanently
            // unpinning on the very next line/delta after any pinned
            // append, without the user touching the scroll view at all.
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
                let isAtBottom = new.contentOffset.y + new.containerSize.height
                    >= new.contentSize.height - Self.bottomProximityTolerance
                if isAtBottom {
                    isPinnedToBottom = true
                    isProgrammaticScrollInFlight = false
                } else if !isProgrammaticScrollInFlight && new.contentSize.height <= old.contentSize.height + 0.5 {
                    // Content didn't grow, yet we're no longer at the
                    // bottom — the only way that happens is a real scroll
                    // away from it. (Skipped while a programmatic scroll's
                    // own animation is still landing — see
                    // `isProgrammaticScrollInFlight`'s doc.)
                    isPinnedToBottom = false
                }
                // Else: content grew and the offset just hasn't been moved
                // to follow it yet — leave `isPinnedToBottom` as it was;
                // `.onChange(of: lines)` below will `scrollTo` and this
                // callback fires again reporting `isAtBottom == true`.
            }
            // Re-pins on every content change (a new line, or the current
            // line growing) — not animated: this fires on essentially every
            // ASR delta while pinned, and an animation per delta would just
            // queue up stutter instead of reading as a smooth follow.
            .onChange(of: lines) { _, _ in
                guard isPinnedToBottom else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            // A fresh recording starts with `lines` reset back to one empty
            // placeholder row (see `RecordingSession.start()`) — re-pin so
            // it doesn't inherit "scrolled up" from whatever the user was
            // doing while reading the *previous* recording's transcript.
            .onChange(of: isRunning) { _, running in
                if running { isPinnedToBottom = true }
            }
            .overlay(alignment: .bottom) {
                if !isPinnedToBottom {
                    jumpToLatestButton(proxy: proxy)
                }
            }
        }
    }

    /// Shown only once the user has scrolled away from the bottom (see
    /// `isPinnedToBottom`) — lets them jump back to the latest line and
    /// resume auto-scrolling in one tap, rather than having to drag back
    /// down manually (which, for a still-scrolling transcript, means
    /// chasing a moving target).
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            isPinnedToBottom = true
            isProgrammaticScrollInFlight = true
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            // Fallback clear — see `isProgrammaticScrollInFlight`'s doc for
            // why this can't just rely on `isAtBottom` firing.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                isProgrammaticScrollInFlight = false
            }
        } label: {
            Label("Latest", systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(.bottom, 8)
    }
}

/// One transcript row — source line, translation line below it, and a
/// hover-triggered copy button (proposal 3.1.D) that copies just this line's
/// source+translation, distinct from `FloatingTranscriptView`'s own
/// panel-wide "复制全文" button. `.textSelection(.enabled)` on top of that
/// lets the user drag-select/copy a partial phrase directly, same as
/// `SessionDetailView`'s history rows.
private struct TranscriptLineRow: View {
    let line: TranscriptLine
    let displayMode: PanelDisplayMode
    let fontScale: PanelFontScale
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                if displayMode != .translationOnly {
                    sourceView
                }
                if displayMode != .sourceOnly {
                    if !line.displayTranslation.isEmpty {
                        translationView
                    } else if displayMode == .translationOnly {
                        // `.translationOnly` otherwise renders a completely
                        // empty row for a line whose translation hasn't
                        // committed yet — the source text, dimmed/italicized,
                        // stands in as a temporary placeholder so there's at
                        // least some indication speech was detected, instead
                        // of the row looking blank until the translation lands.
                        Text(line.displaySource)
                            .font(.system(size: CGFloat(fontScale.translationFontSize)).italic())
                            .foregroundStyle(.primary.opacity(0.7))
                    }
                }
            }
            .textSelection(.enabled)

            if isHovering {
                CopyGlyphButton(help: "Copy this sentence", size: 11, text: lineText)
            }
        }
        .onHover { isHovering = $0 }
    }

    private func lineText() -> String {
        line.displayTranslation.isEmpty
            ? line.displaySource
            : "\(line.displaySource)\n\(line.displayTranslation)"
    }

    @ViewBuilder
    private var sourceView: some View {
        if line.sourceTentative.isEmpty {
            Text(line.source)
                .font(.system(size: CGFloat(fontScale.sourceFontSize), weight: .medium))
        } else if line.source.isEmpty {
            Text(line.sourceTentative)
                .font(.system(size: CGFloat(fontScale.sourceFontSize), weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
        } else {
            (Text(line.source)
                .font(.system(size: CGFloat(fontScale.sourceFontSize), weight: .medium))
            + Text(line.sourceTentative)
                .font(.system(size: CGFloat(fontScale.sourceFontSize), weight: .medium))
                .foregroundStyle(.primary.opacity(0.7)))
        }
    }

    /// Full-strength `.primary` for committed text, not `.secondary`: the
    /// translation is what the reader actually follows, and gray on the
    /// panel's translucent background was hard to read. The preview stays
    /// distinguishable by its italics and a lighter `.primary` opacity.
    @ViewBuilder
    private var translationView: some View {
        if line.translationPreview.isEmpty {
            Text(line.translation)
                .font(.system(size: CGFloat(fontScale.translationFontSize)))
                .foregroundStyle(.primary)
        } else if line.translation.isEmpty {
            Text(line.translationPreview)
                .font(.system(size: CGFloat(fontScale.translationFontSize)).italic())
                .foregroundStyle(.primary.opacity(0.7))
        } else {
            (Text(line.translation)
                .font(.system(size: CGFloat(fontScale.translationFontSize)))
                .foregroundStyle(.primary)
            + Text(line.translationPreview)
                .font(.system(size: CGFloat(fontScale.translationFontSize)).italic())
                .foregroundStyle(.primary.opacity(0.7)))
        }
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
        .help("Hide Caption Panel")
        .accessibilityLabel("Hide Caption Panel")
    }
}
