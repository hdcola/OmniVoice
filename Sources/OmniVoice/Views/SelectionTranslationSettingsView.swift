import AppKit
import OmniVoiceCore
import SwiftUI

/// The "快捷翻译" cards of Settings' "通用" tab — shortcuts, the two-language
/// direction rule (see `SelectionLanguageDirection`; the languages are set in
/// the "语言" card) and engine. Permissions
/// live in `PermissionsSettingsCard`.
struct SelectionTranslationSettingsView: View {
    @ObservedObject var controller: SelectionTranslationController
    @ObservedObject var translator: SelectionTranslator
    /// Observed so the HY-MT1.5 option un-greys the moment its weights
    /// finish downloading in the "模型库" tab.
    @ObservedObject var downloadManager: ModelDownloadManager
    @EnvironmentObject private var navigation: SettingsNavigationState
    /// Observed so "跟随转录设置" re-resolves the moment the recording's
    /// translation engine changes in the "通用" tab.
    @EnvironmentObject private var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            shortcutsCard
            engineCard
        }
    }

    private var shortcutsCard: some View {
        SettingsCard(title: "划词与截图快捷键", icon: "keyboard") {
            ForEach(Array(GlobalShortcutAction.allCases.enumerated()), id: \.element.id) { index, action in
                if index > 0 { SettingsDivider() }
                ShortcutRecorderRow(controller: controller, action: action)
            }
            SettingsDivider()
            SettingsRow(
                title: "连按两次 ⌘C 翻译",
                subtitle: "在其他应用里选中文字后快速按两下 ⌘C，直接翻译刚复制的内容；需要「输入监控」权限"
            ) {
                Toggle("连按两次 ⌘C 翻译", isOn: $controller.isDoubleCopyEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsNote(text: "翻译面板里 ⏎ 翻译、⇧⏎ 换行、Esc 关闭。")
        }
    }

    private var engineCard: some View {
        SettingsCard(title: "快捷翻译引擎", icon: "cpu") {
            SettingsRow(title: "引擎", subtitle: "两种引擎都在本机运行；HY-MT1.5 闲置 5 分钟后自动释放内存") {
                Picker("快捷翻译引擎", selection: $translator.engineID) {
                    Text(followRecordingLabel).tag(SelectionTranslationEngine.followRecording)
                    ForEach(SelectionTranslationEngine.all) { engine in
                        Text(engineLabel(for: engine)).tag(engine.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("快捷翻译引擎")
                .fixedSize()
            }
            if session.translationEngineID == "model.t3po",
               translator.engineID == SelectionTranslationEngine.followRecording {
                SettingsDivider()
                SettingsNote(text: "转录使用的 T3PO 专为实时语音设计，不适合整段翻译，快捷翻译会改用\(SelectionTranslationEngine.displayName(for: translator.effectiveEngineID))。")
            }
            // 我的语言 / 外语 are set in the "语言" card (shared with the
            // recording and voice input); only this engine's caveat lives here.
            if let unsupported = unsupportedLanguageNames {
                SettingsDivider()
                SettingsNote(
                    text: "HY-MT1.5 暂时只能译成中文、英语、日语或韩语，译成\(unsupported)时会报错，可改用系统翻译。",
                    tint: .orange
                )
            }
            if translator.effectiveEngineID == SelectionTranslationEngine.hymt15, !translator.isModelEngineAvailable {
                SettingsDivider()
                SettingsRow(title: "HY-MT1.5 模型尚未下载") {
                    PillButton(title: "前往模型库") { navigation.openModelLibrary() }
                }
            }
        }
    }

    private var followRecordingLabel: String {
        "跟随转录设置（当前：\(SelectionTranslationEngine.displayName(for: translator.effectiveEngineID))）"
    }

    private func engineLabel(for engine: EngineDescriptor) -> String {
        engine.id == SelectionTranslationEngine.hymt15 && !translator.isModelEngineAvailable
            ? "\(engine.displayName)（未下载）" : engine.displayName
    }

    private var unsupportedLanguageNames: String? {
        guard translator.effectiveEngineID == SelectionTranslationEngine.hymt15 else { return nil }
        let names = [translator.myLanguageCode, translator.foreignLanguageCode]
            .filter { !ModelLanguageMapping.isNativelyTranslatableByLocalModel(code: $0) }
            .map(LanguageCatalog.displayName(for:))
        // 我的语言 and 外语 can both be the same unsupported language.
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? nil : unique.joined(separator: "、")
    }
}
