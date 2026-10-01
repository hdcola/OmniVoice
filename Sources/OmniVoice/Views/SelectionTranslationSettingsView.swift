import AppKit
import OmniVoiceCore
import SwiftUI

/// Settings' "快捷翻译" tab — shortcuts, engine, the two-language direction
/// rule (see `SelectionLanguageDirection`), and the two permissions the
/// feature depends on.
struct SelectionTranslationSettingsView: View {
    @ObservedObject var controller: SelectionTranslationController
    @ObservedObject var translator: SelectionTranslator
    /// Observed so the HY-MT1.5 option un-greys the moment its weights
    /// finish downloading in the "模型库" tab.
    @ObservedObject var downloadManager: ModelDownloadManager
    @EnvironmentObject private var navigation: SettingsNavigationState
    /// Observed so "跟随转录设置" re-resolves the moment the recording's
    /// translation engine changes in the "语音与引擎" tab.
    @EnvironmentObject private var session: RecordingSession
    @State private var isAccessibilityTrusted = SelectedTextReader.isAccessibilityTrusted
    @State private var hasScreenRecordingPermission = ScreenFreezer.hasPermission

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                permissionsCard
                shortcutsCard
                languageCard
                engineCard
            }
            .padding(20)
        }
        // Neither permission posts a notification this app can observe
        // cheaply, and the user grants them in System Settings while this
        // tab is open — polling once a second is what keeps the rows honest.
        .task {
            while !Task.isCancelled {
                isAccessibilityTrusted = SelectedTextReader.isAccessibilityTrusted
                hasScreenRecordingPermission = ScreenFreezer.hasPermission
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var permissionsCard: some View {
        SettingsCard(title: "权限", icon: "lock.shield") {
            PermissionRow(
                icon: "figure.wave", title: "辅助功能", detail: "读取其他应用中选中的文字；未授权时可复制后在面板里粘贴",
                isGranted: isAccessibilityTrusted,
                open: controller.openAccessibilitySettings
            )
            SettingsDivider()
            PermissionRow(
                icon: "rectangle.dashed.badge.record", title: "屏幕录制", detail: "用于截图翻译；截图只在本机识别，不会上传",
                isGranted: hasScreenRecordingPermission,
                open: {
                    ScreenFreezer.requestPermission()
                    controller.openScreenRecordingSettings()
                }
            )
        }
    }

    private var shortcutsCard: some View {
        SettingsCard(title: "快捷键", icon: "keyboard") {
            ForEach(Array(GlobalShortcutAction.allCases.enumerated()), id: \.element.id) { index, action in
                if index > 0 { SettingsDivider() }
                ShortcutRecorderRow(controller: controller, action: action)
            }
            SettingsDivider()
            SettingsNote(text: "翻译面板里 ⏎ 翻译、⇧⏎ 换行、Esc 关闭。")
        }
    }

    private var languageCard: some View {
        SettingsCard(title: "语言", icon: "globe") {
            SettingsRow(title: "我的语言", subtitle: "选中的文字是这种语言时，译成「外语」") {
                languagePicker("我的语言", selection: $translator.myLanguageCode)
            }
            SettingsDivider()
            SettingsRow(title: "外语", subtitle: "其他语言一律译成「我的语言」") {
                languagePicker("外语", selection: $translator.foreignLanguageCode)
            }
            if let unsupported = unsupportedLanguageNames {
                SettingsDivider()
                SettingsNote(
                    text: "HY-MT1.5 暂时只能译成中文、英语、日语或韩语，译成\(unsupported)时会报错，可改用系统翻译。",
                    tint: .orange
                )
            }
        }
    }

    private var engineCard: some View {
        SettingsCard(title: "翻译引擎", icon: "cpu") {
            SettingsRow(title: "引擎", subtitle: "两种引擎都在本机运行；HY-MT1.5 闲置 5 分钟后自动释放内存") {
                Picker("引擎", selection: $translator.engineID) {
                    Text(followRecordingLabel).tag(SelectionTranslationEngine.followRecording)
                    ForEach(SelectionTranslationEngine.all) { engine in
                        Text(engineLabel(for: engine)).tag(engine.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if session.translationEngineID == "model.t3po",
               translator.engineID == SelectionTranslationEngine.followRecording {
                SettingsDivider()
                SettingsNote(text: "转录使用的 T3PO 专为实时语音设计，不适合整段翻译，快捷翻译会改用\(SelectionTranslationEngine.displayName(for: translator.effectiveEngineID))。")
            }
            if translator.effectiveEngineID == SelectionTranslationEngine.hymt15, !translator.isModelEngineAvailable {
                SettingsDivider()
                SettingsRow(title: "HY-MT1.5 模型尚未下载") {
                    Button("前往模型库") { navigation.openModelLibrary() }
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

    private func languagePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(LanguageCatalog.common) { option in
                Text(option.displayName).tag(option.code)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var unsupportedLanguageNames: String? {
        guard translator.effectiveEngineID == SelectionTranslationEngine.hymt15 else { return nil }
        let names = [translator.myLanguageCode, translator.foreignLanguageCode]
            .filter { !ModelLanguageMapping.isNativelyTranslatableByLocalModel(code: $0) }
            .compactMap { code in LanguageCatalog.common.first { $0.code == code }?.displayName }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }
}
