import SwiftUI

/// "快捷键" — the last section of Settings' "通用" tab, and the one place
/// every key that starts something is set: the global shortcuts (划词翻译,
/// 截图翻译, 开始/停止转录), double ⌘C and the 语音输入 trigger key. They used to be spread
/// over the 快捷翻译 and 语音输入 tabs.
struct ShortcutsSettingsSection: View {
    @ObservedObject var selectionController: SelectionTranslationController
    @ObservedObject var dictationController: DictationController

    var body: some View {
        Section(String(localized: "Shortcuts")) {
            ForEach(GlobalShortcutAction.allCases) { action in
                ShortcutRecorderRow(controller: selectionController, action: action)
            }
            SettingsFormRow(
                title: "Translate on double ⌘C",
                subtitle: "After selecting text in another app, press ⌘C twice quickly to translate what you just copied; requires the “Input Monitoring” permission"
            ) {
                Toggle("Translate on double ⌘C", isOn: $selectionController.isDoubleCopyEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            dictationTriggerKeyRow
        }
    }

    private var dictationTriggerKeyRow: some View {
        SettingsFormRow(
            title: String(localized: "Dictation trigger key"),
            subtitle: dictationController.isEnabled
                ? String(localized: "Pressing it alone types nothing; it does not trigger when pressed together with another key.")
                : String(localized: "Turn on dictation in the Dictation tab first.")
        ) {
            Picker("Dictation trigger key", selection: $dictationController.triggerKey) {
                ForEach(DictationTriggerKey.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Dictation trigger key")
            .fixedSize()
            .disabled(
                !dictationController.isEnabled || dictationController.dictation.isActive
                    || dictationController.isPolishing || dictationController.review != nil
            )
        }
    }
}
