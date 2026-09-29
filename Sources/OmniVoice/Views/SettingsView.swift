import AppKit
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
/// The mic/system-audio toggle lives on the menu bar instead of here — it's
/// adjusted often enough to want quicker access, while this window is
/// reserved for the ones that aren't (which engine, eventually which model
/// variant). Language uses the same `SourceLanguagePicker`/
/// `TargetLanguagePicker` the floating panel does — not a free-text field —
/// so the two can't ever offer different language options.
struct SettingsView: View {
    @EnvironmentObject private var session: RecordingSession
    @Environment(\.openWindow) private var openWindow
    /// Observed directly (not just reached through `session`) so
    /// `isEngineAvailable(_:)`/a downloaded variant's row live-update the
    /// moment "模型管理" (`ModelManagementView`) downloads or deletes
    /// something — `RecordingSession` no longer triggers downloads itself
    /// (see `resolveModelPath`'s doc) and doesn't re-publish on every
    /// download tick, only on `statusMessage` changes. Passed in explicitly
    /// (not defaulted to `.shared`) and expected to be the exact same
    /// instance `session` (injected separately, via `.environmentObject`,
    /// since `SettingsView()` is constructed before that's available) was
    /// itself given — see `RecordingSession.init`'s own injectable
    /// `modelDownloadManager` parameter. Hardcoding `.shared` here instead
    /// would silently observe the wrong manager for any `RecordingSession`
    /// constructed with a non-`shared` one (a test, an eventual SwiftUI
    /// preview).
    @ObservedObject private var downloadManager: ModelDownloadManager

    init(modelDownloadManager: ModelDownloadManager) {
        self.downloadManager = modelDownloadManager
    }

    var body: some View {
        Form {
            Section("识别引擎 (ASR)") {
                HStack {
                    Picker("引擎", selection: $session.transcriptionEngineID) {
                        // Task 1.3 (引擎列表展示全部候选) — every catalog
                        // engine is always listed, downloaded or not; an
                        // undownloaded `.model` engine is labeled rather
                        // than filtered out entirely (see `engineLabel(for:)`),
                        // so it stays discoverable instead of silently
                        // "vanishing" until something's downloaded for it.
                        ForEach(ProviderCatalog.transcriptionEngines) { engine in
                            Text(engineLabel(for: engine)).tag(engine.id)
                        }
                    }
                    .disabled(isBusy)
                    .onChange(of: session.transcriptionEngineID) { _, newValue in
                        routeToModelManagementIfUndownloaded(engineID: newValue)
                    }
                    // Deliberately *not* disabled — opening a window doesn't
                    // touch engine/model selection, so there's no race with
                    // an in-flight preload/recording to guard against.
                    // `.disabled` must be applied to this button directly
                    // (not to some shared ancestor covering both it and the
                    // `Picker` above, then overridden here with
                    // `.disabled(false)`): SwiftUI's `isEnabled` environment
                    // value only ever goes *more* disabled going down the
                    // view tree, so a descendant can never re-enable itself
                    // once an ancestor already set it to `false`.
                    modelManagementButton
                }
                modelVariantPicker(
                    for: session.transcriptionEngineID,
                    selection: Binding(
                        get: { session.currentTranscriptionModelVariant?.id },
                        set: { session.transcriptionModelVariantID = $0 }
                    )
                )
                .disabled(isBusy)
            }

            Section("翻译引擎") {
                HStack {
                    Picker("引擎", selection: $session.translationEngineID) {
                        // Same reasoning as the ASR engine `Picker` above.
                        ForEach(ProviderCatalog.translationEngines) { engine in
                            Text(engineLabel(for: engine)).tag(engine.id)
                        }
                    }
                    .disabled(isBusy)
                    .onChange(of: session.translationEngineID) { _, newValue in
                        routeToModelManagementIfUndownloaded(engineID: newValue)
                    }
                    modelManagementButton
                }
                modelVariantPicker(
                    for: session.translationEngineID,
                    selection: Binding(
                        get: { session.currentTranslationModelVariant?.id },
                        set: { session.translationModelVariantID = $0 }
                    )
                )
                .disabled(isBusy)
                // T3PO is the only engine with a WAIT/TRANS decision to bias
                // (see `TranslationCommitEagerness`'s doc), so it gets its
                // own picker; every other (one-shot) engine instead exposes
                // the actual character threshold it reads
                // (`TranslationConfig.earlyTranslateThreshold`'s doc) as a
                // plain, directly user-configurable number — showing both
                // controls at once, or the wrong one for the selected
                // engine, would just be confusing. Deliberately *not*
                // `.disabled(isBusy)` in either branch — safe to change
                // mid-recording, same as `targetLanguageCode`'s picker.
                if session.translationEngineID == "model.t3po" {
                    Picker("翻译提交策略", selection: $session.translationCommitEagerness) {
                        ForEach(TranslationCommitEagerness.allCases, id: \.self) { eagerness in
                            Text(eagerness.displayName).tag(eagerness)
                        }
                    }
                } else if session.transcriptionEngineKind != .system {
                    // Task 1.4 (清理无效参数干扰) — See
                    // `TranslationConfig.earlyTranslateThreshold`'s doc for
                    // why this Stepper is a genuine no-op under the system
                    // ASR engine: `SystemTranscriptionProvider` never reports
                    // committed text via `.appended` mid-utterance — a
                    // finalized result *is* its segment boundary — so
                    // `translationProvider.feed(_:)` only ever runs once per
                    // segment, with the whole utterance already, immediately
                    // followed by `flush()` in the same call. There's
                    // nothing "early" left to translate by then. Rather than
                    // show it disabled with an explanatory caption (the old
                    // behavior), it's hidden outright — a control that's
                    // always a no-op for the current configuration
                    // shouldn't be on screen at all.
                    Stepper(
                        "长句提前翻译阈值：\(session.translationEarlyTranslateThreshold) 字",
                        value: $session.translationEarlyTranslateThreshold, in: 20...1000, step: 10
                    )
                }
            }

            Section("语言") {
                SourceLanguagePicker(
                    sourceLanguageCode: $session.sourceLanguageCode,
                    transcriptionEngineKind: session.transcriptionEngineKind
                )
                TargetLanguagePicker(
                    targetLanguageCode: $session.targetLanguageCode,
                    translationEngineID: session.translationEngineID,
                    onSwitchToSystemTranslation: { session.translationEngineID = "system.translation" }
                )
            }
            .disabled(isBusy)

            // Deliberately outside the `.disabled(isBusy)` sections above —
            // these only ever touch `FloatingTranscriptView`'s own SwiftUI
            // opacity (see `panelBackgroundOpacity`/`panelContentOpacity`'s
            // docs), never anything `start()` reads once at setup time, so
            // there's no race to guard against; adjusting either while
            // recording (to see through the panel at whatever's behind it,
            // without losing legibility) is exactly when they're most
            // useful. Two separate sliders, not one — a single shared value
            // (an earlier version of this had exactly that, driving
            // `NSWindow.alphaValue`) faded the transcript text right along
            // with the background, so a panel transparent enough to not
            // block the view behind it also made the text hard to read.
            Section("悬浮窗") {
                opacitySlider(
                    "背景透明度", value: $session.panelBackgroundOpacity, range: 0.1...1.0
                )
                // "内容透明度", not "文字透明度" — `panelContentOpacity`
                // fades the whole panel content stack (buttons/pickers/
                // dividers/status bar too), not just the transcript text.
                opacitySlider(
                    "内容透明度", value: $session.panelContentOpacity, range: 0.4...1.0
                )
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// `isPreloadingModel` alongside `isSessionActive`: switching engines
    /// mid-preload would race `preloadModel()`'s in-flight `loadModel()`
    /// calls against `discardLoadedModelsIfStale()` unloading the very
    /// providers it's still awaiting. Applied to each control individually
    /// (not to a `Section`/the whole `Form`) specifically so
    /// `modelManagementButton` can go undisabled sitting right next to a
    /// disabled `Picker` — see that property's doc.
    private var isBusy: Bool {
        session.isSessionActive || session.isPreloadingModel
    }

    /// Next to each engine `Picker` (not buried at the bottom of the form) —
    /// downloading/deleting a `.model`-kind engine's weights always happens
    /// in "模型管理" (`ModelManagementView`) now, never inline here, so this
    /// is the whole form's only way back to it.
    private var modelManagementButton: some View {
        Button("模型管理…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "modelManagement")
        }
    }

    /// Task 1.3 (引擎列表展示全部候选) — every catalog engine is now always
    /// listed by the `Picker`s above regardless of download state (no more
    /// `isEngineAvailable`-style filtering); this only labels the
    /// undownloaded ones so they still read as "go get this" rather than
    /// "ready to use".
    private func hasDownloadedVariant(_ engine: EngineDescriptor) -> Bool {
        guard engine.kind == .model else { return true }
        return ProviderCatalog.modelVariants(forEngineID: engine.id)
            .contains { downloadManager.isDownloaded($0) }
    }

    private func engineLabel(for engine: EngineDescriptor) -> String {
        hasDownloadedVariant(engine) ? engine.displayName : "\(engine.displayName)（未下载 · 点击配置）"
    }

    /// Selecting an undownloaded `.model` engine has nowhere else to go —
    /// there's nothing to actually switch to yet — so this opens "模型管理"
    /// for the user instead of silently leaving the `Picker` pointed at an
    /// engine with no weights behind it. Deliberately doesn't *revert* the
    /// selection: the user's pick is kept (so it's still there when they come
    /// back downloaded), and `RecordingSession.fallBackToSystemEngineIfModelUnavailable()`
    /// is what actually guards `start()`/`preloadModel()` against running it
    /// unavailable, not this UI-level nudge.
    private func routeToModelManagementIfUndownloaded(engineID: String) {
        guard let engine = (ProviderCatalog.transcriptionEngines + ProviderCatalog.translationEngines)
            .first(where: { $0.id == engineID }), !hasDownloadedVariant(engine)
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "modelManagement")
    }

    /// Lists *downloaded* variants, same reasoning as `isEngineAvailable(_:)`
    /// above — plus the currently-selected one even if it isn't downloaded
    /// (deleted via Model Management, or a stale/synced selection), again to
    /// avoid a blank `Picker` selection; marked "（未下载）" for the same
    /// reason `engineLabel(for:)` marks its engine-level equivalent. An
    /// engine is only ever listed above once at least one of its variants is
    /// downloaded, so in the common case this `Picker` is never actually
    /// empty.
    @ViewBuilder
    private func modelVariantPicker(for engineID: String, selection: Binding<String?>) -> some View {
        let variants = ProviderCatalog.modelVariants(forEngineID: engineID)
        let selectedID = selection.wrappedValue
        let shown = variants.filter { downloadManager.isDownloaded($0) || $0.id == selectedID }
        if !shown.isEmpty {
            Picker("模型", selection: selection) {
                ForEach(shown) { variant in
                    Text(variantLabel(for: variant)).tag(Optional(variant.id))
                }
            }
        }
    }

    private func opacitySlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: range)
            // `.rounded()`, not a bare `Int(...)` truncation — a `Slider`'s
            // underlying `Double` can land a hair under a "clean" percentage
            // from binary floating-point rounding (e.g. 0.29999999999999994
            // for what's visually 0.3), which truncation reads as 29% —
            // jittery/off-by-one against where the thumb actually looks.
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func variantLabel(for variant: ModelVariant) -> String {
        downloadManager.isDownloaded(variant)
            ? "\(variant.displayName) · 约 \(variant.approximateSizeMB) MB"
            : "\(variant.displayName)（未下载）"
    }
}
