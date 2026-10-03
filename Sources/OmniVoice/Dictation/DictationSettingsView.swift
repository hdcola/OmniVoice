import SwiftUI
import OmniVoiceCore

/// The "语音输入" card of Settings' "通用" tab. Permissions live in
/// `PermissionsSettingsCard`.
struct DictationSettingsView: View {
    @ObservedObject var controller: DictationController
    @EnvironmentObject private var session: RecordingSession

    var body: some View {
        SettingsCard(title: "语音输入", icon: "waveform.badge.mic") {
            SettingsRow(
                title: "启用语音输入",
                subtitle: "在任何应用里按住触发键说话，松开后文字自动输入到光标处；需要「输入监控」「辅助功能」和麦克风权限"
            ) {
                Toggle("启用语音输入", isOn: $controller.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow(title: "触发键", subtitle: "单独按下不会输入字符；和别的键一起按时不会触发") {
                Picker("触发键", selection: $controller.triggerKey) {
                    ForEach(DictationTriggerKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("触发键")
                .fixedSize()
            }
            .disabled(!controller.isEnabled || controller.dictation.isActive)
            SettingsDivider()
            SettingsRow(title: "触发方式") {
                Picker("触发方式", selection: $controller.mode) {
                    Text("按住说话").tag(DictationTriggerMachine.Mode.hold)
                    Text("按一下开始，再按一下结束").tag(DictationTriggerMachine.Mode.toggle)
                }
                .labelsHidden()
                .accessibilityLabel("触发方式")
                .fixedSize()
            }
            .disabled(!controller.isEnabled || controller.dictation.isActive)
            SettingsDivider()
            SettingsRow(
                title: "听写语言",
                subtitle: "按哪种语言识别；自动检测只在本地识别模型已加载时可用"
            ) {
                Picker("听写语言", selection: dictationLanguageSelection) {
                    Text("我的语言（\(languageName(session.languages.myLanguageCode))）").tag(DictationLanguageChoice.mine)
                    Text("外语（\(languageName(session.languages.foreignLanguageCode))）").tag(DictationLanguageChoice.foreign)
                    Text(session.transcriptionEngineKind == .model ? "自动检测" : "自动检测（需本地模型）")
                        .tag(DictationLanguageChoice.auto)
                        .disabled(session.transcriptionEngineKind != .model)
                }
                .labelsHidden()
                .accessibilityLabel("听写语言")
                .fixedSize()
            }
            .disabled(!controller.isEnabled || controller.dictation.isActive)
            SettingsDivider()
            SettingsRow(
                title: "单次最长时长",
                subtitle: "到时自动结束并输入已识别的内容，防止忘记结束时麦克风一直开着；说长段内容可以调长"
            ) {
                Picker("单次最长时长", selection: $controller.maxDuration) {
                    ForEach(DictationMaxDuration.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("单次最长时长")
                .fixedSize()
            }
            .disabled(!controller.isEnabled)
            if let warmup = controller.warmupMessage {
                SettingsDivider()
                SettingsNote(text: warmup)
            }
            SettingsDivider()
            SettingsNote(text: "识别引擎和麦克风跟随「实时转录」的设置：选了本地模型且已加载（可开启「启动时加载模型」），就直接复用它，否则用系统语音识别；录制字幕期间也用系统识别。按 Esc 可取消；「按一下开始」时，再按 Return 可结束并自动回车发送；输入时会借用剪贴板，随后自动恢复。")
        }
    }

    /// 自动检测 only works with a local model; elsewhere voice input uses
    /// 我的语言 (see `RecordingSession.dictationLanguageCode`), so show that —
    /// the stored choice is kept for when a local model is selected again.
    private var dictationLanguageSelection: Binding<DictationLanguageChoice> {
        Binding(
            get: {
                let choice = session.languages.dictationLanguage
                return choice == .auto && session.transcriptionEngineKind != .model ? .mine : choice
            },
            set: { session.languages.dictationLanguage = $0 }
        )
    }

    private func languageName(_ code: String) -> String {
        LanguageCatalog.displayName(for: code)
    }
}
