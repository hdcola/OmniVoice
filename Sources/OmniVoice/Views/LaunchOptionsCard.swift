import SwiftUI

/// "启动" rows shared by Settings ("通用", rows of a grouped `Form`) and the
/// first-launch window (inside a card, see `LaunchOptionsCard`): login item
/// toggle plus what to load into memory at launch. Takes bindings rather
/// than owning state, since Settings applies each change immediately while
/// onboarding only applies them when the user finishes.
struct LaunchOptionsRows: View {
    @Binding var launchAtLogin: Bool
    @Binding var preloadMode: LaunchPreloadMode
    /// The login item was added but macOS still wants the user's approval.
    var needsLoginApproval = false
    var loginError: String?
    /// False when both engines are system ones, so there's nothing to load.
    var preloadAvailable = true
    var memoryNote: String?
    /// False when the translator is a system engine — "仅翻译模型" would
    /// then load nothing, so it's left out of the choices.
    var translationOnlyAvailable = true
    var onOpenLoginItems: () -> Void = {}
    /// The first-run wizard splits the two rows over two steps.
    var showsLoginRow = true
    var showsPreloadRow = true
    /// Card rows (onboarding) instead of `Form` rows (Settings).
    var inCard = false

    var body: some View {
        if showsLoginRow { loginRow }
        if inCard && showsLoginRow && showsPreloadRow { SettingsDivider() }
        if showsPreloadRow { preloadRow }
    }

    @ViewBuilder
    private func row<Control: View>(
        _ title: String, subtitle: String, subtitleTint: Color = .secondary, @ViewBuilder control: () -> Control
    ) -> some View {
        if inCard {
            SettingsRow(title: title, subtitle: subtitle, subtitleTint: subtitleTint, trailing: control)
        } else {
            SettingsFormRow(title: title, subtitle: subtitle, subtitleTint: subtitleTint, control: control)
        }
    }

    private var loginRow: some View {
        row("Launch at login", subtitle: loginSubtitle, subtitleTint: loginError == nil ? .secondary : .red) {
            HStack(spacing: 8) {
                if needsLoginApproval {
                    if inCard {
                        PillButton(title: "Allow", action: onOpenLoginItems)
                    } else {
                        Button("Allow", action: onOpenLoginItems)
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private var preloadRow: some View {
        row(
            "Load models at launch",
            subtitle: preloadAvailable
                ? (memoryNote ?? String(localized: "Load into memory ahead of time so the first translation or transcription doesn't wait"))
                : String(localized: "The current engines are built into macOS; there is nothing to load")
        ) {
            Picker("Load models at launch", selection: $preloadMode) {
                ForEach(LaunchPreloadMode.allCases.filter {
                    $0 != .translationOnly || translationOnlyAvailable || preloadMode == .translationOnly
                }) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Load models at launch")
            .fixedSize()
            .disabled(!preloadAvailable)
        }
    }

    private var loginSubtitle: String {
        if let loginError { return String(localized: "Setup failed: \(loginError)") }
        if needsLoginApproval { return String(localized: "Needs approval in System Settings → Login Items") }
        return String(localized: "Runs automatically in the menu bar after you log in to macOS")
    }
}

/// `LaunchOptionsRows` in a titled card, for the first-launch window.
struct LaunchOptionsCard: View {
    var title = "Launch"
    @Binding var launchAtLogin: Bool
    @Binding var preloadMode: LaunchPreloadMode
    var needsLoginApproval = false
    var loginError: String?
    var translationOnlyAvailable = true
    var onOpenLoginItems: () -> Void = {}
    var showsLoginRow = true
    var showsPreloadRow = true

    var body: some View {
        SettingsCard(title: title, icon: "power") {
            LaunchOptionsRows(
                launchAtLogin: $launchAtLogin,
                preloadMode: $preloadMode,
                needsLoginApproval: needsLoginApproval,
                loginError: loginError,
                translationOnlyAvailable: translationOnlyAvailable,
                onOpenLoginItems: onOpenLoginItems,
                showsLoginRow: showsLoginRow,
                showsPreloadRow: showsPreloadRow,
                inCard: true
            )
        }
    }
}
