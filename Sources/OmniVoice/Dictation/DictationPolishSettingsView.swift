import OmniVoiceCore
import SwiftUI

/// The 润色识别结果 rows of the 语音输入 card.
struct DictationPolishSettingsRows: View {
    @ObservedObject var controller: DictationController

    @State private var keyDraft = ""
    @State private var showingPrivacyNotice = false
    @State private var testing = false
    @State private var testResult: String?

    private var hasKey: Bool { controller.polishCredentials.hasAPIKey }
    private var configured: Bool { controller.polish.isConfigured(hasAPIKey: hasKey) }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.polish.isEnabled },
            set: { on in
                if on, !controller.polish.hasAcknowledgedPrivacy {
                    showingPrivacyNotice = true
                } else {
                    controller.polish.isEnabled = on
                }
            }
        )
    }

    var body: some View {
        SettingsRow(
            title: "润色识别结果",
            subtitle: controller.polish.isEnabled && !configured
                ? "还没配置完：请填写下面的服务、模型和 API Key，否则会直接输入原文"
                : "输入前先交给你配置的 LLM 补标点、去口癖、整理列表；识别出的文字会发送到该服务。失败、超时或结果不可靠时输入原文，润色中按 Esc 也输入原文。先润色，再翻译"
        ) {
            Toggle("润色识别结果", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .disabled(!controller.isEnabled)
        .alert("文字会发送到你配置的服务", isPresented: $showingPrivacyNotice) {
            Button("开启") {
                controller.polish.hasAcknowledgedPrivacy = true
                controller.polish.isEnabled = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开启后，每次语音输入识别出的文字（不含窗口标题或其他内容）会发送到下面配置的 OpenAI 兼容服务进行润色。选用本地的 Ollama 则不会离开这台 Mac。")
        }

        if controller.polish.isEnabled {
            SettingsDivider()
            SettingsRow(title: "服务") {
                Picker("服务", selection: presetBinding) {
                    ForEach(PolishPreset.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("润色服务")
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow(
                title: "Base URL",
                subtitle: controller.polish.usesInsecureRemoteEndpoint
                    ? "警告：这是非加密的 http 地址，识别的文字会明文发送；只有本机（localhost）建议用 http"
                    : "OpenAI 兼容接口，请求发到 {Base URL}/chat/completions"
            ) {
                TextField("https://…/v1", text: $controller.polish.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityLabel("Base URL")
            }
            SettingsDivider()
            SettingsRow(title: "模型") {
                TextField("模型名", text: $controller.polish.model)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityLabel("润色模型")
            }
            SettingsDivider()
            SettingsRow(
                title: "API Key",
                subtitle: keySubtitle,
                subtitleTint: controller.polishKeyRejected ? .red : .secondary
            ) {
                HStack {
                    SecureField(hasKey ? "已保存" : "粘贴后回车", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .accessibilityLabel("API Key")
                        .onSubmit(saveKey)
                    Button("保存", action: saveKey)
                        .disabled(keyDraft.isEmpty)
                    if hasKey {
                        Button("清除") { controller.setPolishAPIKey(nil) }
                    }
                }
            }
            SettingsDivider()
            SettingsRow(title: "润色风格") {
                Picker("润色风格", selection: $controller.polish.style) {
                    ForEach(PolishStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("润色风格")
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow(
                title: "额外要求",
                subtitle: "最多 \(PolishSettings.maxExtraLength) 字，只影响风格，例如「称呼用您」"
            ) {
                TextField("可留空", text: extraBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityLabel("额外要求")
            }
            SettingsDivider()
            SettingsRow(title: "超时", subtitle: "超过这个时间就输入原文") {
                Stepper(
                    "\(controller.polish.timeoutSeconds) 秒",
                    value: $controller.polish.timeoutSeconds, in: PolishSettings.timeoutRange, step: 1
                )
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow(title: "测试连接", subtitle: testResult) {
                Button(testing ? "测试中…" : "测试") { runTest() }
                    .disabled(testing || !configured)
            }
        }
    }

    private var keySubtitle: String {
        if controller.polishKeyRejected { return "服务拒绝了这个 Key（401/403），请检查" }
        if controller.polish.isLocalEndpoint { return "本机服务（如 Ollama）不需要 Key；Key 存在钥匙串里" }
        return "存在钥匙串里，不会显示完整内容"
    }

    private var presetBinding: Binding<PolishPreset> {
        Binding(
            get: { controller.polish.preset },
            set: { controller.polish.apply(preset: $0) }
        )
    }

    private var extraBinding: Binding<String> {
        Binding(
            get: { controller.polish.extra },
            set: { controller.polish.extra = String($0.prefix(PolishSettings.maxExtraLength)) }
        )
    }

    private func saveKey() {
        guard !keyDraft.isEmpty else { return }
        controller.setPolishAPIKey(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        keyDraft = ""
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            let result = await controller.testPolishConnection()
            testing = false
            switch result {
            case .success(let elapsed):
                testResult = String(format: "连接成功，用时 %.1f 秒", elapsed)
            case .failure(let error):
                testResult = "失败：\(error.message)"
            }
        }
    }
}
