import SwiftUI

/// "启动" card shared by Settings ("通用") and the first-launch window: login
/// item toggle plus what to load into memory at launch. Takes bindings rather
/// than owning state, since Settings applies each change immediately while
/// onboarding only applies them when the user finishes.
struct LaunchOptionsCard: View {
    var title = "启动"
    @Binding var launchAtLogin: Bool
    @Binding var preloadMode: LaunchPreloadMode
    /// The login item was added but macOS still wants the user's approval.
    var needsLoginApproval = false
    var loginError: String?
    /// False when both engines are system ones, so there's nothing to load.
    var preloadAvailable = true
    var memoryNote: String?
    var onOpenLoginItems: () -> Void = {}

    var body: some View {
        SettingsCard(title: title, icon: "power") {
            SettingsRow(
                title: "开机时自动启动",
                subtitle: loginSubtitle,
                subtitleTint: loginError == nil ? .secondary : .red
            ) {
                HStack(spacing: 8) {
                    if needsLoginApproval {
                        PillButton(title: "去允许", action: onOpenLoginItems)
                    }
                    Toggle("开机时自动启动", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "启动时加载模型",
                subtitle: preloadAvailable
                    ? (memoryNote ?? "提前载入内存，首次翻译/转录无需等待")
                    : "当前引擎均为系统内置，无需加载"
            ) {
                Picker("启动时加载模型", selection: $preloadMode) {
                    ForEach(LaunchPreloadMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("启动时加载模型")
                .fixedSize()
                .disabled(!preloadAvailable)
            }
        }
    }

    private var loginSubtitle: String {
        if let loginError { return "设置失败：\(loginError)" }
        if needsLoginApproval { return "需要在「系统设置 → 登录项」中允许" }
        return "登录 macOS 后自动在菜单栏运行"
    }
}
