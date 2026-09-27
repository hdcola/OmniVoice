import Foundation

/// Renders a session's utterances to a plain-text format a user can save or
/// share. Markdown for now (readable as-is, diffable, easy to extend) — an
/// SRT-subtitle exporter is an obvious later addition (utterances already
/// have `createdAt`, just missing a per-row duration) once that's asked for.
public enum SessionExporter {
    public static func markdown(for session: RecordingSessionRecord) -> String {
        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("*\(Self.dateFormatter.string(from: session.startedAt))*")
        lines.append("")
        for utterance in session.utterances.sorted(by: { $0.index < $1.index }) {
            lines.append("**\(utterance.sourceText)**")
            if !utterance.translationText.isEmpty {
                lines.append("> \(utterance.translationText)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
