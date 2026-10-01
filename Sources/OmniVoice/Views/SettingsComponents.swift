import SwiftUI

// Building blocks for the card-style Settings tabs: each group is a rounded
// card, each row a title + one-line subtitle on the left and its control on
// the right. Inspired by SnapTra Translator's settings
// (https://github.com/yelog/SnapTraTranslator).

/// A rounded card holding one group of rows, with its title (and icon) as
/// the first line inside the card. Rows are separated by `SettingsDivider`s
/// that the caller places between them.
struct SettingsCard<Content: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                    }
                    Text(title)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 2)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                // A faint tint over the window in both modes (the light
                // window is plain white, so a white card would vanish).
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.08), lineWidth: 0.5)
        )
    }
}

/// Pill-style tab switcher shown at the top of the Settings window.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element.id) { index, tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == tab ? Color.primary : .secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(selection == tab ? Color.primary.opacity(0.14) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.15), value: selection)
    }
}

/// A shortcut drawn as one keycap per space-separated key ("⌥ A" → "⌥" "A";
/// "⌥ Space" keeps "Space" on one keycap).
struct KeycapRow: View {
    let text: String

    private var keys: [String] {
        text.split(separator: " ").map(String.init)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: 16)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
                    )
            }
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .opacity(0.5)
            .padding(.horizontal, 14)
    }
}

/// One row: title (+ optional subtitle) on the left, `trailing` control on
/// the right. A row's own `.disabled` greys the whole row.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// `.red` for an error message standing in for the subtitle.
    var subtitleTint: Color = .secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A free-form note inside a card (warnings, "go to the model library"
/// nudges) — same horizontal inset as `SettingsRow`.
struct SettingsNote: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }
}

/// Small coloured capsule: "已授权", "未下载", "已就绪"…
struct StatusPill: View {
    enum Tone {
        case good, warning, neutral

        var color: Color {
            switch self {
            case .good: return .green
            case .warning: return .orange
            case .neutral: return .secondary
            }
        }
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(tone.color.opacity(0.12)))
    }
}

/// A permission as a card row: icon, name, one-line purpose, and either a
/// "已授权" pill or a "去授权" button.
struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let isGranted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isGranted {
                StatusPill(text: "已授权", tone: .good)
            } else {
                PillButton(title: "去授权", action: open)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Small accent capsule button; `tint: .red` for destructive actions.
/// `isWorking` swaps the title for a spinner plus `workingTitle`.
struct PillButton: View {
    let title: String
    var tint: Color = .accentColor
    var isWorking = false
    var workingTitle = ""
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Text(isWorking ? workingTitle : title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.15)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}
