import AppKit
import OmniVoiceCore
import SwiftUI

/// Settings' "选词翻译" tab — shortcuts, engine, the two-language direction
/// rule (see `SelectionLanguageDirection`), and the two permissions the
/// feature depends on.
struct SelectionTranslationSettingsView: View {
    @ObservedObject var controller: SelectionTranslationController
    @ObservedObject var translator: SelectionTranslator
    /// Observed so the HY-MT1.5 option un-greys the moment its weights
    /// finish downloading in the "模型库管理" tab.
    @ObservedObject var downloadManager: ModelDownloadManager
    @EnvironmentObject private var navigation: SettingsNavigationState
    /// Observed so "跟随录音设置" re-resolves the moment the recording's
    /// translation engine changes in the "语音与引擎" tab.
    @EnvironmentObject private var session: RecordingSession
    @State private var isAccessibilityTrusted = SelectedTextReader.isAccessibilityTrusted
    @State private var hasScreenRecordingPermission = ScreenFreezer.hasPermission

    var body: some View {
        Form {
            Section("快捷键") {
                ForEach(GlobalShortcutAction.allCases) { action in
                    ShortcutRecorderRow(controller: controller, action: action)
                }
                Text("在任意应用中选中文字后按「翻译选中文字」，或按「截图翻译」框选屏幕上的文字。面板里 ⏎ 翻译、⇧⏎ 换行、Esc 关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("翻译引擎") {
                Picker("引擎", selection: $translator.engineID) {
                    Text(followRecordingLabel).tag(SelectionTranslationEngine.followRecording)
                    ForEach(SelectionTranslationEngine.all) { engine in
                        Text(engineLabel(for: engine)).tag(engine.id)
                    }
                }
                if session.translationEngineID == "model.t3po",
                   translator.engineID == SelectionTranslationEngine.followRecording {
                    Text("录音使用的 T3PO 专为实时语音设计，不适合整段翻译，选词翻译会改用\(SelectionTranslationEngine.displayName(for: translator.effectiveEngineID))。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if translator.effectiveEngineID == SelectionTranslationEngine.hymt15, !translator.isModelEngineAvailable {
                    HStack {
                        Text("HY-MT1.5 模型尚未下载。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("前往模型库管理") { navigation.openModelLibrary() }
                            .font(.caption)
                    }
                }
                Text("两种引擎都在本机运行：系统翻译支持的语言更多；HY-MT1.5 首次使用时加载模型，闲置 5 分钟后自动释放内存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("语言") {
                languagePicker("我的语言", selection: $translator.myLanguageCode)
                languagePicker("外语", selection: $translator.foreignLanguageCode)
                Text("选中的文字是「我的语言」时译成「外语」，其他语言一律译成「我的语言」。也可以在面板顶部临时换一个目标语言。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let unsupported = unsupportedLanguageNames {
                    Text("HY-MT1.5 暂时只能译成中文、英语、日语或韩语，译成\(unsupported)时会报错，可改用系统翻译。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("权限") {
                permissionRow(
                    "辅助功能", granted: isAccessibilityTrusted,
                    detail: "用于读取其他应用中选中的文字；未授权时可以复制后在面板里粘贴。",
                    open: controller.openAccessibilitySettings
                )
                permissionRow(
                    "屏幕录制", granted: hasScreenRecordingPermission,
                    detail: "用于截图翻译；截图只在本机识别，不会上传。",
                    open: {
                        ScreenFreezer.requestPermission()
                        controller.openScreenRecordingSettings()
                    }
                )
            }
        }
        // Grouped (unlike the other tabs' plain `Form`s) so its four
        // sections scroll inside `SettingsView`'s fixed 560×480 frame
        // instead of being clipped.
        .formStyle(.grouped)
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

    private var followRecordingLabel: String {
        "跟随录音设置（当前：\(SelectionTranslationEngine.displayName(for: translator.effectiveEngineID))）"
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
    }

    private var unsupportedLanguageNames: String? {
        guard translator.effectiveEngineID == SelectionTranslationEngine.hymt15 else { return nil }
        let names = [translator.myLanguageCode, translator.foreignLanguageCode]
            .filter { !ModelLanguageMapping.isNativelyTranslatableByLocalModel(code: $0) }
            .compactMap { code in LanguageCatalog.common.first { $0.code == code }?.displayName }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String, open: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("去授权", action: open)
            }
        }
    }
}
