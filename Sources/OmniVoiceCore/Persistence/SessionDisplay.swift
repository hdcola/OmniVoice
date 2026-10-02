import Foundation

extension RecordingSessionRecord {
    /// Allocating a `DateFormatter` is expensive and `displayTitle()` runs
    /// per row on every render/search keystroke, so one is shared.
    /// `DateFormatter.string(from:)` is thread-safe.
    private nonisolated(unsafe) static let defaultTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// The title `RecordingSession` gives a new session for a given start
    /// time — also used to tell an untouched default title from a rename.
    public static func defaultTitle(for date: Date) -> String {
        defaultTitleFormatter.string(from: date)
    }

    /// What the history list shows: a user-chosen title as-is, otherwise the
    /// first utterance's text (trimmed, capped at `maxLength` characters),
    /// otherwise the stored default title when nothing was transcribed.
    public func displayTitle(maxLength: Int = 30) -> String {
        let isDefault = title == Self.defaultTitle(for: startedAt)
        guard isDefault else { return title }
        // First *non-empty* utterance — a leading VAD blip with no text
        // shouldn't hide what was actually said afterwards.
        let first = utterances
            .sorted(by: { $0.index < $1.index })
            .lazy
            .map { $0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let first else { return title }
        let oneLine = first.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > maxLength ? String(oneLine.prefix(maxLength)) + "…" : oneLine
    }
}
