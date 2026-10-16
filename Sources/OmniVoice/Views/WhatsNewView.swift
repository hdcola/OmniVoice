import OmniVoiceCore
import SwiftUI

/// Namespaced like `PersistedOnboardingKey`: a UI-module concern the core
/// session doesn't need to know about.
enum PersistedWhatsNewKey {
    /// The highest `WhatsNewCatalog` revision the user has been shown (or
    /// that a first run made moot). Missing for users who updated from a
    /// version without this screen.
    static let lastSeenRevision = "org.hdcola.omnivoice.lastSeenWhatsNewRevision"

    static var lastSeen: Int? {
        UserDefaults.standard.object(forKey: lastSeenRevision) as? Int
    }

    static func markSeen(_ revision: Int = WhatsNewCatalog.latestRevision) {
        UserDefaults.standard.set(revision, forKey: lastSeenRevision)
    }
}

/// Shown once after an update that added something worth opting into — see
/// `WhatsNewCatalog`. Closing the window by any means counts as seen
/// (`AppDelegate.windowWillClose(_:)`).
struct WhatsNewView: View {
    let entries: [WhatsNewEntry]
    @ObservedObject var selectionController: SelectionTranslationController
    @ObservedObject var dictationController: DictationController
    let onDismiss: () -> Void
    let onRerunOnboarding: () -> Void
    @State private var hasInputMonitoring = DoubleCopyMonitor.hasPermission

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What's new in OmniVoice")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Highlights from this update")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        entryCard(entry)
                    }
                }
                .padding(16)
            }
            Divider().opacity(0.5)
            HStack {
                Spacer()
                PrimaryPillButton(title: String(localized: "Got It"), action: onDismiss)
                    .keyboardShortcut(.defaultAction)
                // A button takes one shortcut, so Esc rides on an invisible one.
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // Fixed height: a hosting controller would otherwise size the window
        // to the (collapsed) scroll view.
        .frame(width: 460, height: 440)
        // The user grants Input Monitoring in System Settings while this
        // window is open — poll like the permission rows do.
        .task {
            while !Task.isCancelled {
                hasInputMonitoring = DoubleCopyMonitor.hasPermission
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func entryCard(_ entry: WhatsNewEntry) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    actionControl(for: entry)
                }
                ForEach(entry.bullets, id: \.self) { bullet in
                    Text(bullet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func actionControl(for entry: WhatsNewEntry) -> some View {
        switch entry.action {
        case .enableDoubleCopyTranslate:
            if !selectionController.isDoubleCopyEnabled {
                PillButton(title: entry.actionTitle ?? String(localized: "Turn On")) {
                    selectionController.isDoubleCopyEnabled = true
                }
            } else if hasInputMonitoring {
                StatusPill(text: String(localized: "On"), tone: .good)
            } else {
                // Switched on, but without the permission it hears nothing.
                PillButton(title: String(localized: "Input Monitoring permission needed"), tint: .orange) {
                    selectionController.openInputMonitoringSettings()
                }
            }
        case .enableDictation:
            if !dictationController.isEnabled {
                PillButton(title: entry.actionTitle ?? String(localized: "Turn On")) {
                    dictationController.isEnabled = true
                }
            } else if hasInputMonitoring {
                StatusPill(text: String(localized: "On"), tone: .good)
            } else {
                // Same as ⌘C ⌘C: the trigger key is never heard without it.
                PillButton(title: String(localized: "Input Monitoring permission needed"), tint: .orange) {
                    selectionController.openInputMonitoringSettings()
                }
            }
        case .rerunOnboarding:
            PillButton(title: entry.actionTitle ?? String(localized: "Re-run")) {
                onDismiss()
                onRerunOnboarding()
            }
        case nil:
            EmptyView()
        }
    }
}
