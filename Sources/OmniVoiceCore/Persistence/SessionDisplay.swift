import Foundation

extension RecordingSessionRecord {
    /// The title as created by `RecordingSession.defaultTitle()` for a given
    /// start time — used to tell an untouched default title from a rename.
    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// What the history list shows: a user-chosen title as-is, otherwise the
    /// first utterance's text (trimmed, capped at `maxLength` characters),
    /// otherwise the stored default title when nothing was transcribed.
    public func displayTitle(maxLength: Int = 30) -> String {
        let isDefault = title == Self.defaultTitle(for: startedAt)
        guard isDefault else { return title }
        let first = utterances.min(by: { $0.index < $1.index })?.sourceText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first, !first.isEmpty else { return title }
        let oneLine = first.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > maxLength ? String(oneLine.prefix(maxLength)) + "…" : oneLine
    }
}
