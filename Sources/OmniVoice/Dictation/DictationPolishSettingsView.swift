import OmniVoiceCore
import SwiftUI

/// The 润色识别结果 rows of the 语音输入 tab, one `Form` section of their own.
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
        SettingsFormRow(
            title: String(localized: "Polish recognized text"),
            subtitle: controller.polish.isEnabled && !configured
                ? String(localized: "Setup is incomplete: fill in the service, model and API Key below, otherwise the original text is typed.")
                : String(localized: "Before typing, the text is handed to the LLM you configured to add punctuation, remove filler words and tidy lists; the recognized text is sent to that service. If it fails, times out or the result looks unreliable, the original is typed; pressing Esc while polishing also types the original. Polishing happens before translation.")
        ) {
            Toggle("Polish recognized text", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .disabled(!controller.isEnabled)
        .alert("Text will be sent to the service you configured", isPresented: $showingPrivacyNotice) {
            Button("Turn On") {
                controller.polish.hasAcknowledgedPrivacy = true
                controller.polish.isEnabled = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("When on, the text recognized by each dictation (not window titles or anything else) is sent to the OpenAI-compatible service configured below for polishing. With a local Ollama it never leaves this Mac.")
        }

        if controller.polish.isEnabled {
            SettingsFormRow(title: String(localized: "Service")) {
                Picker("Service", selection: presetBinding) {
                    ForEach(PolishPreset.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Polish service")
                .fixedSize()
            }
            SettingsFormRow(
                title: "Base URL",
                subtitle: controller.polish.usesInsecureRemoteEndpoint
                    ? String(localized: "Warning: this is an unencrypted http address and the recognized text will be sent in plain text; only use http for this Mac (localhost).")
                    : String(localized: "OpenAI-compatible API; requests go to {Base URL}/chat/completions")
            ) {
                TextField("https://…/v1", text: $controller.polish.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityLabel("Base URL")
            }
            SettingsFormRow(title: String(localized: "Model")) {
                TextField("Model name", text: $controller.polish.model)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityLabel("Polish model")
            }
            SettingsFormRow(
                title: "API Key",
                subtitle: keySubtitle,
                subtitleTint: controller.polishKeyRejected ? .red : .secondary
            ) {
                HStack {
                    SecureField(hasKey ? String(localized: "Saved") : String(localized: "Paste, then press Return"), text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .accessibilityLabel("API Key")
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .disabled(keyDraft.isEmpty)
                    if hasKey {
                        Button("Clear") { controller.setPolishAPIKey(nil) }
                    }
                }
            }
            SettingsFormRow(title: String(localized: "Polish style")) {
                Picker("Polish style", selection: $controller.polish.style) {
                    ForEach(PolishStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Polish style")
                .fixedSize()
            }
            SettingsFormRow(
                title: String(localized: "Extra instructions"),
                subtitle: String(localized: "Up to \(PolishSettings.maxExtraLength) characters; affects style only, e.g. “address me formally”")
            ) {
                TextField("Optional", text: extraBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityLabel("Extra instructions")
            }
            SettingsFormRow(title: String(localized: "Timeout"), subtitle: String(localized: "The original text is typed after this time.")) {
                Stepper(
                    "\(controller.polish.timeoutSeconds) s",
                    value: $controller.polish.timeoutSeconds, in: PolishSettings.timeoutRange, step: 1
                )
                .fixedSize()
            }
            SettingsFormRow(title: String(localized: "Test connection"), subtitle: testResult) {
                Button(testing ? String(localized: "Testing…") : String(localized: "Test")) { runTest() }
                    .disabled(testing || !configured)
            }
        }
    }

    private var keySubtitle: String {
        if controller.polishKeyRejected { return String(localized: "The service rejected this Key (401/403); please check it.") }
        if controller.polish.isLocalEndpoint { return String(localized: "A local service (such as Ollama) does not need a Key; the Key is stored in the Keychain.") }
        return String(localized: "Stored in the Keychain; the full value is not shown.")
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
                testResult = String(format: String(localized: "Connected in %.1f s"), elapsed)
            case .failure(let error):
                testResult = String(localized: "Failed: \(error.message)")
            }
        }
    }
}
