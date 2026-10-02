import SwiftUI
import OmniVoiceCore

/// The "语音输入" card of Settings' "通用" tab. Permissions live in
/// `PermissionsSettingsCard`.
struct DictationSettingsView: View {
    @ObservedObject var controller: DictationController

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
            SettingsNote(text: "识别引擎、语言和麦克风跟随「实时转录」的设置：选了本地模型且已加载（可开启「启动时加载模型」），就直接复用它，否则用系统语音识别；录制字幕期间也用系统识别。按 Esc 可取消；输入时会借用剪贴板，随后自动恢复。")
        }
    }
}
