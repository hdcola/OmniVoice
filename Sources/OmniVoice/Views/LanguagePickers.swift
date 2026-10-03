import OmniVoiceCore
import SwiftUI

/// True while a popover anchored in the floating panel's control bar is
/// open. A popover is its own window, so the pointer moving into it counts
/// as leaving the panel — the panel reads this to keep its auto-hiding
/// controls (the popover's anchor) on screen meanwhile.
struct PanelPopoverOpenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Shared quick-pick source-language `Picker`, used by both the floating
/// panel and Settings so their behavior can't drift apart — see
/// `RecordingSession.sourceLanguageCode`'s doc for why "自动" only takes
/// effect for a `.model`-kind engine, and `LanguageCatalog`'s doc for the
/// source/target support asymmetry a couple of its options have.
struct SourceLanguagePicker: View {
    @Binding var sourceLanguageCode: String?
    let transcriptionEngineKind: EngineKind?
    /// False while speaking in the user's own language — there is no
    /// "自动" for that side (see `LanguagePreferences.sourceLanguageCode`).
    var allowsAuto: Bool = true
    @State private var isAutoExplanationPresented = false

    /// The system ASR engine can't recognize a handful of `LanguageCatalog`
    /// entries at all (`supportsSystemASRSource == false`) — offering them
    /// here while `.system` is selected would be a guaranteed-to-fail trap,
    /// since picking one and hitting start throws every time.
    private var options: [LanguageOption] {
        transcriptionEngineKind == .system
            ? LanguageCatalog.common.filter(\.supportsSystemASRSource)
            : LanguageCatalog.common
    }

    /// Task 1.2 (源语言自动检测显性化) — "自动" stays in the list even under
    /// the system ASR engine instead of disappearing (the old behavior,
    /// wrapped in `if transcriptionEngineKind == .model`), just disabled and
    /// suffixed so the user can see the feature exists rather than
    /// concluding OmniVoice has no auto-detect at all.
    private var isAutoAvailable: Bool { transcriptionEngineKind == .model && allowsAuto }
    private var autoLabel: String {
        if isAutoAvailable { return "✨ 自动检测语种 (Auto)" }
        return allowsAuto ? "✨ 自动检测（需本地 R2T2 引擎）" : "✨ 自动检测（仅听外语时可用）"
    }

    var body: some View {
        HStack(spacing: 4) {
            Picker("源语言", selection: $sourceLanguageCode) {
                Text(autoLabel)
                    .tag(String?.none)
                    // Kept in the list (not filtered out) so the feature
                    // stays discoverable under the system engine — see
                    // `isAutoAvailable`'s doc — but disabled per-item rather
                    // than disabling the whole `Picker`, since every other
                    // option here is still perfectly selectable.
                    .disabled(!isAutoAvailable)
                ForEach(options) { option in
                    Text(option.displayName).tag(Optional(option.code))
                }
                // Only ever matches a value persisted by an older build
                // (before free-text entry was removed in favor of this
                // picker) — kept so that value still displays instead of
                // looking blank/broken.
                if let custom = sourceLanguageCode,
                   !options.contains(where: { $0.code == custom }) {
                    Text("\(custom)（自定义）").tag(Optional(custom))
                }
            }
            // A disabled `Picker` can't be reasoned about via its own tap —
            // this small "?" sits next to it so the explanation is reachable
            // even while the picker itself is fully system-driven (auto
            // isn't selectable, so there's no "select and see" path).
            if allowsAuto && transcriptionEngineKind != .model {
                Button {
                    isAutoExplanationPresented = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("为什么“自动检测”不可用")
                .popover(isPresented: $isAutoExplanationPresented) {
                    Text("macOS 系统语音识别引擎要求指定固定语种。如需自动识别混合语种，请在设置中切换为 R2T2 本地模型。")
                        .font(.callout)
                        .frame(width: 260)
                        .padding()
                }
            }
        }
        .preference(key: PanelPopoverOpenKey.self, value: isAutoExplanationPresented)
    }
}

/// Shared quick-pick target-language `Picker` — see `SourceLanguagePicker`'s
/// doc. Unlike source, target has no "自动" case (`RecordingSession.targetLanguageCode`
/// is never optional) and isn't gated by engine kind — but a `.model`-kind
/// translation engine (T3PO/HY-MT1.5) silently falls back to Chinese for any
/// target `ModelLanguageMapping` doesn't recognize (see that type's doc), so
/// this view instead renders a grouped list plus a warning glyph (whose
/// popover has the details), both driven by `translationEngineID` — Task 1.1
/// (语言防静默错译). Built for the floating panel's single-row control bar.
struct TargetLanguagePicker: View {
    @Binding var targetLanguageCode: String
    /// `nil` keeps this view's old, ungated behavior (no grouping, no
    /// warning) — every call site should pass a real engine ID; this
    /// only exists so a hypothetical future caller with nothing to gate by
    /// doesn't have to fabricate one.
    var translationEngineID: String?
    /// Invoked when the user taps "一键将翻译引擎切换为「系统翻译」"
    /// in the warning popover below. Review Round 1 Must-Fix 1 — this
    /// closure ultimately sets `session.translationEngineID`, whose `didSet`
    /// unconditionally calls `discardLoadedModelsIfStale()`, tearing down
    /// the live `translationProvider` an active recording is still feeding.
    /// `isSessionActive` below is what stops that button from firing mid-
    /// recording in the first place — this callback is the escape hatch a
    /// non-UI caller (there isn't one today) would still need to guard
    /// itself; every real call site instead relies on the `.disabled(_:)`
    /// applied at the button below.
    var onSwitchToSystemTranslation: (() -> Void)?
    /// Review Round 1 Must-Fix 1 (悬浮窗中允许在录制中切换引擎) — disables the
    /// warning card's "一键切换" button while a recording is running/
    /// starting/stopping, same invariant every other engine-selection
    /// control in the app already observes (`RecordingSession.isSessionActive`'s
    /// doc: "each provider's session is set up fresh from these values at
    /// the top of `start()`, so changing them during that setup would
    /// either race the read or silently not apply to the run in progress").
    var isSessionActive: Bool = false
    @State private var isWarningPresented = false

    private var isLocalModelEngine: Bool {
        translationEngineID == "model.t3po" || translationEngineID == "model.hymt15"
    }

    private var isCurrentTargetNativelySupported: Bool {
        ModelLanguageMapping.isNativelyTranslatableByLocalModel(code: targetLanguageCode)
    }

    private var showsWarning: Bool { isLocalModelEngine && !isCurrentTargetNativelySupported }

    private var nativeOptions: [LanguageOption] {
        LanguageCatalog.common.filter { ModelLanguageMapping.isNativelyTranslatableByLocalModel(code: $0.code) }
    }

    private var otherOptions: [LanguageOption] {
        LanguageCatalog.common.filter { !ModelLanguageMapping.isNativelyTranslatableByLocalModel(code: $0.code) }
    }

    var body: some View {
        HStack(spacing: 4) {
            picker
            if showsWarning {
                warningButton
            }
        }
        .preference(key: PanelPopoverOpenKey.self, value: isWarningPresented)
    }

    private var picker: some View {
        Picker("目标语言", selection: $targetLanguageCode) {
            if isLocalModelEngine {
                Section("★ 原生流式推荐 (T3PO 完美支持)") {
                    ForEach(nativeOptions) { option in
                        Text(option.displayName).tag(option.code)
                    }
                }
                Section("⚠️ 其他语言（需系统翻译引擎支持）") {
                    ForEach(otherOptions) { option in
                        Text(option.displayName).tag(option.code)
                    }
                }
            } else {
                ForEach(LanguageCatalog.common) { option in
                    Text(option.displayName).tag(option.code)
                }
            }
            if !LanguageCatalog.common.contains(where: { $0.code == targetLanguageCode }) {
                Text("\(targetLanguageCode)（自定义）").tag(targetLanguageCode)
            }
        }
    }

    /// Task 1.1's warning — shown the moment a `.model`-kind translation
    /// engine is paired with a target `ModelLanguageMapping` silently
    /// downgrades to Chinese for (see that type's doc). A single glyph that
    /// fits the panel's one-row control bar, with the details and the switch
    /// action in a `.popover`. UI warning only, deliberately not a hard block
    /// — the mapping's own fallback logic is untouched (see
    /// `ModelLanguageMapping.t3poTargetLanguage(forCode:)`'s doc), so the
    /// user can still proceed and get Chinese output if that's what they want.
    private var warningButton: some View {
        Button {
            isWarningPresented = true
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .help("语言支持提示")
        .popover(isPresented: $isWarningPresented) {
            warningContent
                .frame(width: 260)
                .padding()
        }
    }

    private var warningContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("语言支持提示", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text(
                "当前选中的本地模型针对中、英、日、韩进行了专门训练。翻译至「\(targetDisplayName)」可能会静默回退为中文。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let onSwitchToSystemTranslation {
                Button(switchButtonTitle) {
                    // Belt-and-suspenders alongside `.disabled(isSessionActive)`
                    // below — see this property's doc.
                    guard !isSessionActive else { return }
                    onSwitchToSystemTranslation()
                }
                .disabled(isSessionActive)
                .font(.caption)
            }
        }
    }

    private var switchButtonTitle: String {
        isSessionActive
            ? "一键将翻译引擎切换为「系统翻译」（转录结束后生效）"
            : "一键将翻译引擎切换为「系统翻译」"
    }

    private var targetDisplayName: String {
        LanguageCatalog.displayName(for: targetLanguageCode)
    }
}
