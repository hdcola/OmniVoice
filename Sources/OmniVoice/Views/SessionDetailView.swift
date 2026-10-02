import AppKit
import OmniVoiceCore
import SwiftUI

/// Read-only view of one past recording's full aligned source/translation
/// transcript, plus Markdown export and clipboard copy shortcuts.
struct SessionDetailView: View {
    let session: RecordingSessionRecord
    @State private var exportDocument: TextFileDocument?
    @State private var isExporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(session.utterances.sorted(by: { $0.index < $1.index })) { utterance in
                    HStack(alignment: .top, spacing: 8) {
                        // "[04:20]" — proposal §3.3.C: a small relative
                        // timestamp, `utterance.createdAt` minus
                        // `session.startedAt`, so each line can be placed in
                        // the recording's timeline without cross-referencing
                        // the session's overall start time.
                        Text(Self.relativeTimestampLabel(for: utterance, in: session))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(utterance.sourceText)
                                .font(.body)
                            if !utterance.translationText.isEmpty {
                                Text(utterance.translationText)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    // Lets the user select/copy a specific line directly out
                    // of the transcript, not just via the toolbar's
                    // whole-session copy buttons below.
                    .textSelection(.enabled)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(session.displayTitle())
        .toolbar {
            ToolbarItem {
                Button("复制全文") { copyToClipboard(Self.plainText(for: session)) }
            }
            ToolbarItem {
                Button("仅复制译文") { copyToClipboard(Self.translationOnlyText(for: session)) }
            }
            ToolbarItem {
                Button("导出…") {
                    exportDocument = TextFileDocument(text: SessionExporter.markdown(for: session))
                    isExporting = true
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: session.title
        ) { _ in }
    }

    /// "mm:ss" since `session.startedAt`, or "hh:mm:ss" past an hour —
    /// proposal §3.3.C's per-line relative timestamp prefix.
    private static func relativeTimestampLabel(for utterance: UtteranceRecord, in session: RecordingSessionRecord) -> String {
        let elapsed = max(0, Int(utterance.createdAt.timeIntervalSince(session.startedAt)))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "[%02d:%02d:%02d]", hours, minutes, seconds)
        }
        return String(format: "[%02d:%02d]", minutes, seconds)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Full bilingual transcript as plain, readable text (source line,
    /// translation line below it) — deliberately not `SessionExporter
    /// .markdown(for:)`'s Markdown syntax (`**bold**`/`> blockquote`), which
    /// reads as literal asterisks/quote marks once pasted into a chat
    /// message or plain-text doc rather than a Markdown renderer.
    private static func plainText(for session: RecordingSessionRecord) -> String {
        session.utterances.sorted(by: { $0.index < $1.index })
            .map { utterance in
                utterance.translationText.isEmpty
                    ? utterance.sourceText
                    : "\(utterance.sourceText)\n\(utterance.translationText)"
            }
            .joined(separator: "\n\n")
    }

    /// Only the translation lines, one per utterance, skipping any utterance
    /// with nothing translated yet — for pasting just the target-language
    /// text (the proposal's "仅复制译文", 3.3.C) without wading through the
    /// bilingual pairing.
    private static func translationOnlyText(for session: RecordingSessionRecord) -> String {
        session.utterances.sorted(by: { $0.index < $1.index })
            .map(\.translationText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
