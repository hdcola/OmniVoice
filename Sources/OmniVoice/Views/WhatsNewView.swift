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
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OmniVoice 有新变化")
                            .font(.system(size: 20, weight: .semibold))
                        Text("这次更新里值得你看一眼的内容")
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
                PrimaryPillButton(title: "知道了", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // Fixed height: a hosting controller would otherwise size the window
        // to the (collapsed) scroll view.
        .frame(width: 460, height: 440)
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
            if selectionController.isDoubleCopyEnabled {
                StatusPill(text: "已开启", tone: .good)
            } else {
                PillButton(title: entry.actionTitle ?? "开启") {
                    selectionController.isDoubleCopyEnabled = true
                }
            }
        case nil:
            EmptyView()
        }
    }
}
