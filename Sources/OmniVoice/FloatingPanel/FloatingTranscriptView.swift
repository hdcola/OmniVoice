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
    @State private var autoHideTask: Task<Void, Never>?
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
            Divider()
                .opacity(isControlsVisible ? 1 : 0)
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
            autoHideTask?.cancel()
            if isHovering {
                isControlsVisible = true
            } else {
                autoHideTask = Task {
                    try? await Task.sleep(for: Self.autoHideDelay)
                    guard !Task.isCancelled else { return }
                    isControlsVisible = false
                }
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
        // Copy/close live outside the adaptive part and are always pinned to
        // the trailing edge — an earlier version wrapped the *whole* row in a
        // horizontal `ScrollView`, which sized it to its natural width: at a
        // narrow panel the close button scrolled off-screen, and at a wide
        // one the row stayed left-aligned, leaving a big empty gap to the
        // right of the close button (a `Spacer` inside a scroll view has no
        // width to expand into).
        HStack(spacing: 10) {
            // Picks the first layout that fits the space left after the
            // trailing buttons: everything inline at natural width, then the
            // display-mode/font-scale pickers folded into one menu, and as a
            // last resort language pickers that shrink (truncating their
            // labels) instead of anything being hidden or scrolled away.
            // `.layoutPriority(1)` makes the `HStack` offer this all of the
            // remaining width first, instead of splitting it with the
            // `Spacer` below.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    primaryControls(compressible: false)
                    displayOptionPickers
                }
                HStack(spacing: 10) {
                    primaryControls(compressible: false)
                    displayOptionsMenu
                }
                HStack(spacing: 10) {
                    primaryControls(compressible: true)
                    displayOptionsMenu
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            // "一键复制全文" (proposal 3.1.D / roadmap P1_3) — copies the
            // whole current transcript, not just a single selected line;
            // `TranscriptListView`'s own per-row hover button below handles
            // the single-line case.
            Button {
                copyFullTranscript()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("复制全文")
            .disabled(session.lines.allSatisfy(\.displaySource.isEmpty))

            PanelCloseButton(action: onClose)
        }
        .padding(10)
    }

    /// Start/stop, the source → target language pickers, and the timer.
    /// The language pickers are flexible views that would otherwise stretch
    /// across the whole bar in a wide panel, so they're pinned to their
    /// natural width (the selected language's label) — except with
    /// `compressible`, where they may shrink below it to fit a narrow one.
    @ViewBuilder
    private func primaryControls(compressible: Bool) -> some View {
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
        .fixedSize(horizontal: !compressible, vertical: false)

        Image(systemName: "arrow.right")
            .foregroundStyle(.secondary)
            .font(.caption)

        // Target stays editable while running: unlike source, it isn't
        // baked into a provider at `start()` — the `.translationTask`
        // above rebuilds `translationConfiguration` on every change, so
        // switching it mid-recording actually retargets the next
        // translated segment.
        TargetLanguagePicker(
            targetLanguageCode: $session.targetLanguageCode,
            translationEngineID: session.translationEngineID,
            onSwitchToSystemTranslation: { session.translationEngineID = "system.translation" },
            isSessionActive: session.isSessionActive,
            // Review Round 1 Must-Fix 2 — the compact control bar is a
            // single 30pt-tall row; the full multi-line warning card
            // would blow that out and shove the transcript list down.
            isCompact: true
        )
        .labelsHidden()
        .fixedSize(horizontal: !compressible, vertical: false)

        // 录制计时器（提案 3.1.E）— 只在录制中显示，停止后复位，避免一个
        // 静止的 "00:00:00" 常驻在控制栏里，看起来像是坏掉了。
        if session.isRunning {
            Text(session.elapsedTimeString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// 显示模式切换（提案 3.1.B：双语对照 / 仅译文 / 仅原文）与字号档位
    /// （提案 3.1.C：标准 / 大 / 特大），在控制栏放得下时直接平铺。
    /// `.fixedSize()` instead of a fixed `.frame(width:)` — sizing to the
    /// currently-selected label's actual content is narrower than one sized
    /// for the widest option, but still never clips whichever one is showing.
    @ViewBuilder
    private var displayOptionPickers: some View {
        displayModePicker
            .labelsHidden()
            .fixedSize()
        fontScalePicker
            .labelsHidden()
            .fixedSize()
    }

    /// The same two pickers folded into a single icon menu, for when the
    /// panel is too narrow to show them inline (see `controlBar`). A menu,
    /// like the pickers themselves, still works from a plain mouse click on
    /// this never-key panel.
    private var displayOptionsMenu: some View {
        Menu {
            displayModePicker
            fontScalePicker
        } label: {
            Image(systemName: "textformat.size")
                .foregroundStyle(.secondary)
        }
        // `.button` + `.plain` rather than `.borderlessButton`: the latter
        // is drawn by AppKit and ignores the label's `.secondary` style, so
        // the icon rendered brighter than the neighboring copy button.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("显示选项")
    }

    private var displayModePicker: some View {
        Picker("显示模式", selection: $session.panelDisplayMode) {
            ForEach(PanelDisplayMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
    }

    private var fontScalePicker: some View {
        Picker("字号", selection: $session.panelFontScale) {
            ForEach(PanelFontScale.allCases, id: \.self) { scale in
                Text(scale.displayName).tag(scale)
            }
        }
    }

    /// Copies every closed/in-progress transcript line as plain bilingual
    /// text (source line, translation line below it) — same shape as
    /// `SessionDetailView`'s "复制全文", just sourced from the live
    /// in-memory `session.lines` instead of a persisted `RecordingSessionRecord`.
    private func copyFullTranscript() {
        let text = session.lines
            .filter { !$0.displaySource.isEmpty }
            .map { line in
                line.displayTranslation.isEmpty
                    ? line.displaySource
                    : "\(line.displaySource)\n\(line.displayTranslation)"
            }
            .joined(separator: "\n\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

            // One-tap deeplink straight to the relevant System Settings
            // privacy pane (proposal 3.4.C) — without this, a denied
            // mic/screen-recording permission only ever showed up as prose
            // in `statusMessage`, leaving the user to hunt for the right
            // settings pane themselves.
            if session.microphonePermissionNeeded {
                permissionSettingsButton(
                    urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                    systemImage: "mic.slash",
                    tooltip: "前往系统设置授权麦克风"
                )
            }
            if session.screenRecordingPermissionNeeded {
                permissionSettingsButton(
                    urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                    systemImage: "display",
                    tooltip: "前往系统设置授权屏幕录制"
                )
            }

            Spacer()

            // `.layoutPriority(1)`: without it, a long `statusMessage` (a
            // localized error tacked onto a permission hint, say) could
            // compress this down to nothing at a narrow panel width instead
            // of truncating the `Text` above further — the button/label
            // here is what's actionable, so it should be what keeps its
            // full width, not what gets squeezed out first.
            modelStatusControl
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Model preload/loaded/release affordance — in the status bar's
    /// bottom-right corner rather than a button up in `controlBar` (an
    /// earlier version of this put it there) or behind a right-click
    /// context menu on a label (an earlier version tried that too, for
    /// "释放模型" specifically): a plain, always-visible button beats a
    /// context menu for discoverability, and this corner keeps it out of
    /// the way of the controls used on every single recording (start/stop,
    /// language pickers) while still being visible without digging for it.
    /// Only worth surfacing for a `.model`-kind engine at all — a `.system`
    /// engine's `loadModel()` is a no-op, so there's nothing to preload or
    /// release (see `usesOnDeviceModelEngine`'s doc).
    @ViewBuilder
    private var modelStatusControl: some View {
        if session.usesOnDeviceModelEngine {
            if session.hasLoadedModels {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    // A translation-only launch preload leaves the recognizer
                    // unloaded (`start()` loads it); still releasable here.
                    Text(session.isModelLoaded ? "模型已就绪" : "翻译模型已就绪")
                    // A `.model`-kind engine otherwise only ever unloads on
                    // an engine switch or app quit (see `isModelLoaded`'s
                    // doc) — this is the escape hatch for reclaiming that
                    // memory/VRAM sooner on a memory-constrained machine,
                    // without either. Disabled while running/starting/
                    // stopping (not just relying on `unloadModels()`'s own
                    // no-op guard): a button that silently does nothing
                    // when tapped reads as broken, not as "not applicable
                    // right now".
                    Button {
                        session.unloadModels()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(session.isSessionActive)
                    .help("释放模型")
                }
                .font(.caption)
            } else {
                Button {
                    Task { await session.preloadModel() }
                } label: {
                    HStack(spacing: 5) {
                        // A visible spinner while `loadModel()` is in flight
                        // — without this, the button just sat on a static
                        // "加载中…" label for however many seconds R2T2/T3PO's
                        // weights took to read, which (before
                        // `InProcessTranscriber`/`InProcessTranslator.loadModel(modelPath:)`
                        // stopped blocking the main actor synchronously —
                        // see their doc) used to coincide with the entire
                        // window being genuinely frozen, not just looking
                        // idle. Now that the load runs off the main actor,
                        // this spinner animates the whole time, which is
                        // itself confirmation the window hasn't hung.
                        if session.isPreloadingModel {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(session.isPreloadingModel ? "加载中…" : "预加载模型")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(session.isSessionActive || session.isPreloadingModel)
            }
        }
    }

    /// One button, reused for both the microphone and screen-recording
    /// privacy panes above — `x-apple.systempreferences:` URLs are always
    /// well-formed literals here, so the force-unwrap is safe. Takes a
    /// distinct `systemImage`/`tooltip` per call site: with both permissions
    /// missing at once, two identical gear icons with the same tooltip gave
    /// no way to tell which one addressed which permission.
    private func permissionSettingsButton(urlString: String, systemImage: String, tooltip: String) -> some View {
        Button {
            NSWorkspace.shared.open(URL(string: urlString)!)
        } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
        .help(tooltip)
    }

    /// Live feedback that audio is actually being picked up — without this,
    /// nothing on the panel changed between "转录中…" with the mic silent vs.
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
            .accessibilityLabel("麦克风输入中")
    }

    private func rebuildConfiguration() {
        translationConfiguration = TranslationSession.Configuration(
            source: session.currentSourceLanguage,
            target: session.currentTargetLanguage
        )
    }
}

/// The scrollable transcript itself, pulled out of `FloatingTranscriptView`
/// so that view's very-high-frequency, unrelated `@Published` changes (chiefly
/// `session.inputLevel`, ticking ~10-15×/sec while recording — see
/// `micLevelIndicator`'s doc) don't force a full re-diff of what can be
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
                        Text("等待开始…")
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
            Label("最新内容", systemImage: "arrow.down.circle.fill")
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
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .textSelection(.enabled)

            if isHovering {
                Button {
                    copyLine()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("复制本句")
            }
        }
        .onHover { isHovering = $0 }
    }

    private func copyLine() {
        let text = line.displayTranslation.isEmpty
            ? line.displaySource
            : "\(line.displaySource)\n\(line.displayTranslation)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    @ViewBuilder
    private var translationView: some View {
        if line.translationPreview.isEmpty {
            Text(line.translation)
                .font(.system(size: CGFloat(fontScale.translationFontSize)))
                .foregroundStyle(.secondary)
        } else if line.translation.isEmpty {
            Text(line.translationPreview)
                .font(.system(size: CGFloat(fontScale.translationFontSize)).italic())
                .foregroundStyle(.secondary.opacity(0.75))
        } else {
            (Text(line.translation)
                .font(.system(size: CGFloat(fontScale.translationFontSize)))
                .foregroundStyle(.secondary)
            + Text(line.translationPreview)
                .font(.system(size: CGFloat(fontScale.translationFontSize)).italic())
                .foregroundStyle(.secondary.opacity(0.75)))
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
        .help("隐藏字幕悬浮窗")
        .accessibilityLabel("隐藏字幕悬浮窗")
    }
}
