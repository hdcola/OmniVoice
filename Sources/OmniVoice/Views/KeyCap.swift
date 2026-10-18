import AppKit
import SwiftUI

/// One key drawn as a small rounded key cap ("⏎", "esc", "⌥A"), for the
/// keyboard hints under the translation panel and the dictation bubble —
/// a key set apart from its label reads at a glance, where "⏎ 翻译 · ⇧⏎ 换行"
/// written out as one sentence did not.
struct KeyCap: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}

/// A key cap followed by what the key does.
struct KeyHint: Identifiable {
    let key: String
    let action: String

    var id: String { key }
}

/// A row of `KeyHint`s, wrapping only between hints, never inside one.
struct KeyHintRow: View {
    let hints: [KeyHint]

    var body: some View {
        // `ViewThatFits` keeps the hints on one line when they fit and stacks
        // the overflow below otherwise, instead of a long label breaking mid-hint.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { hintViews(hints) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { hintViews(Array(hints.prefix(2))) }
                HStack(spacing: 10) { hintViews(Array(hints.dropFirst(2))) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func hintViews(_ hints: [KeyHint]) -> some View {
        ForEach(hints) { hint in
            HStack(spacing: 4) {
                KeyCap(hint.key)
                Text(hint.action)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// One copy event: every value is distinct, so a repeated copy with the same
/// message still counts as a change.
struct CopyConfirmation: Equatable {
    let id = UUID()
    let message: String
}

/// A short "已复制" capsule that fades out on its own — before this, every
/// copy button in the app gave no sign that anything had happened. Set
/// a new `CopyConfirmation` to show it; it clears itself after `duration`.
private struct CopyConfirmationModifier: ViewModifier {
    @Binding var confirmation: CopyConfirmation?
    let alignment: Alignment
    private static let duration: Duration = .seconds(1.5)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if let confirmation {
                    Label(confirmation.message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .labelStyle(CopyConfirmationLabelStyle())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .padding(10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .allowsHitTesting(false)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(.easeOut(duration: 0.2), value: confirmation)
            // Keyed on the confirmation, which is distinct per copy, so copying
            // again restarts the timer even when the message is the same.
            .task(id: confirmation) {
                guard confirmation != nil else { return }
                try? await Task.sleep(for: Self.duration)
                guard !Task.isCancelled else { return }
                confirmation = nil
            }
    }
}

private struct CopyConfirmationLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(.green)
            configuration.title
        }
    }
}

extension View {
    /// Shows `confirmation` briefly as a capsule; see `CopyConfirmationModifier`.
    func copyConfirmation(_ confirmation: Binding<CopyConfirmation?>, alignment: Alignment = .bottom) -> some View {
        modifier(CopyConfirmationModifier(confirmation: confirmation, alignment: alignment))
    }
}
