import OmniVoiceCore
import SwiftData
import SwiftUI

/// Lets the menu bar's recent-transcript rows open History on one
/// transcript — the window may not exist yet when the row is clicked, so the
/// request waits here until `SessionListView` picks it up.
@MainActor
final class HistoryNavigationState: ObservableObject {
    static let shared = HistoryNavigationState()

    @Published var requestedSessionID: UUID?
}

/// The history window's sidebar — every past (and the current, if running)
/// recording, searchable, newest first.
struct SessionListView: View {
    @Query(sort: \RecordingSessionRecord.startedAt, order: .reverse)
    private var sessions: [RecordingSessionRecord]
    @State private var searchText = ""
    /// SwiftData's own environment context — already wired into the
    /// environment by `.modelContainer` in `OmniVoiceApp.swift`, so this view
    /// deletes/renames directly through it instead of standing up its own
    /// `SessionStore`/`ModelContainer`.
    @Environment(\.modelContext) private var modelContext
    /// Tells which record (if any) is being recorded right now.
    @EnvironmentObject private var recordingSession: RecordingSession
    /// Drives `List(selection:)` below, so `.onDeleteCommand` (the ⌫ key) has
    /// something to act on — `NavigationLink(value:)` and `List(selection:)`
    /// share the same `UUID` values, so picking a row for navigation and
    /// picking it for deletion are the same selection.
    @State private var selection: Set<UUID> = []
    /// Non-nil while a delete confirmation is on screen — set from the
    /// context menu, ⌫, or the toolbar menu, all funneled through the same
    /// `.confirmationDialog` so there's exactly one delete path to keep in
    /// sync with `RecordingSessionRecord`'s cascade-delete relationship.
    @State private var pendingRequest: DeletionRequest?
    /// Non-nil while the rename alert is on screen.
    @State private var renamingSession: RecordingSessionRecord?
    @State private var renameText: String = ""
    @ObservedObject private var navigation = HistoryNavigationState.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(groupedSessions) { group in
                    Section(group.title) {
                        ForEach(group.sessions) { session in
                            row(for: session)
                                .tag(session.id)
                                .contextMenu { contextMenu(for: session) }
                        }
                    }
                }
            }
            .frame(minWidth: 340)
            .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 520)
            .onDeleteCommand { requestDeletion(of: selectedSessions) }
            // Housekeeping sits at the foot of the list, like Finder's and
            // Mail's sidebars, leaving the title bar to the window controls.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !sessions.isEmpty { sidebarFooter }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search transcripts or translations")
            .navigationTitle("History")
        } detail: {
            // Detail is driven straight from the selection: a `NavigationLink`
            // inside a multi-selection `List` doesn't reliably fire on the
            // first click.
            let visibleSelection = selectedSessions
            if visibleSelection.count == 1, let session = visibleSelection.first {
                SessionDetailView(session: session)
                    .id(session.id)
            } else if visibleSelection.count > 1 {
                ContentUnavailableView(
                    "\(visibleSelection.count) transcripts selected",
                    systemImage: "checkmark.circle",
                    description: Text("Press ⌫ or use the Manage menu at the bottom of the sidebar to delete them in bulk")
                )
            } else {
                ContentUnavailableView(
                    "Select a transcript",
                    systemImage: "text.bubble",
                    description: Text("Select a transcript in the list to view its details")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 460)
        .onAppear(perform: showRequestedSession)
        .onChange(of: navigation.requestedSessionID) { showRequestedSession() }
        // One dialog for every delete flow — stacking several
        // `.confirmationDialog`s on one view can leave some unpresentable.
        .confirmationDialog(
            pendingRequest.map(title(for:)) ?? "",
            isPresented: Binding(get: { pendingRequest != nil }, set: { if !$0 { pendingRequest = nil } }),
            titleVisibility: .visible,
            presenting: pendingRequest
        ) { request in
            Button("Delete", role: .destructive) { performDeletion(targets(for: request)) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(message(for: request))
        }
        .alert(
            "Rename Transcript",
            isPresented: Binding(get: { renamingSession != nil }, set: { if !$0 { renamingSession = nil } })
        ) {
            TextField("Transcript title", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingSession = nil }
        }
    }

    /// The transcript count and the bulk-delete menu, under the list.
    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Text("\(sessions.count) transcripts")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Menu {
                Button("Delete \(selectedDeletable.count) Selected…", role: .destructive) {
                    requestDeletion(of: selectedSessions)
                }
                .disabled(selectedDeletable.isEmpty)
                Divider()
                Button("Clean Up Empty Transcripts…") { pendingRequest = .empty }
                    .disabled(!sessions.contains(where: isEmptyAndDeletable))
                Button("Delete Transcripts Older Than 30 Days…") { pendingRequest = .olderThan(days: 30) }
                    .disabled(!sessions.contains { isStale($0, olderThanDays: 30) })
                Button("Delete Transcripts Older Than 90 Days…") { pendingRequest = .olderThan(days: 90) }
                    .disabled(!sessions.contains { isStale($0, olderThanDays: 90) })
            } label: {
                Text("Manage")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// What a confirmation dialog is asking to delete. Bulk cases resolve
    /// their targets when shown/confirmed, so counts reflect current data.
    private enum DeletionRequest: Equatable {
        case sessions([RecordingSessionRecord])
        /// Records with no utterances — leftovers from before empty
        /// recordings stopped being saved.
        case empty
        case olderThan(days: Int)
    }

    private func targets(for request: DeletionRequest) -> [RecordingSessionRecord] {
        switch request {
        case .sessions(let sessions): return sessions
        case .empty: return sessions.filter(isEmptyAndDeletable)
        case .olderThan(let days): return sessions.filter { isStale($0, olderThanDays: days) }
        }
    }

    private func title(for request: DeletionRequest) -> String {
        switch request {
        case .sessions(let sessions): return String(localized: "Delete \(sessions.count) transcripts?")
        case .empty: return String(localized: "Clean up \(targets(for: request).count) empty transcripts?")
        case .olderThan(let days): return String(localized: "Delete transcripts older than \(days) days?")
        }
    }

    private func message(for request: DeletionRequest) -> String {
        switch request {
        case .sessions: return String(localized: "This can't be undone. A transcript being transcribed won't be deleted.")
        case .empty: return String(localized: "These transcripts have no content. This can't be undone.")
        case .olderThan(let days):
            return String(localized: "\(targets(for: request).count) transcripts started more than \(days) days ago will be deleted. This can\'t be undone.")
        }
    }

    private func isEmptyAndDeletable(_ session: RecordingSessionRecord) -> Bool {
        session.utterances.isEmpty && isDeletable(session)
    }

    /// Started more than `days` days ago and not the live session.
    private func isStale(_ session: RecordingSessionRecord, olderThanDays days: Int) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
        return session.startedAt < cutoff && isDeletable(session)
    }

    /// Selects the transcript the menu bar asked for, clearing a search that
    /// would hide it.
    private func showRequestedSession() {
        guard let id = navigation.requestedSessionID else { return }
        navigation.requestedSessionID = nil
        searchText = ""
        selection = [id]
    }

    /// Selected *and currently visible*: a selection made before typing a
    /// search must not let ⌫ delete rows the filter is now hiding.
    private var selectedSessions: [RecordingSessionRecord] {
        filteredSessions.filter { selection.contains($0.id) }
    }

    private var selectedDeletable: [RecordingSessionRecord] {
        selectedSessions.filter(isDeletable)
    }

    @ViewBuilder
    private func contextMenu(for session: RecordingSessionRecord) -> some View {
        Button("Rename…") { beginRename(session) }
        // Right-clicking a row inside a multi-selection acts on the whole
        // selection, like Finder; otherwise just that row.
        let targets = selection.contains(session.id) ? selectedSessions : [session]
        let deletable = targets.filter(isDeletable)
        if !deletable.isEmpty {
            Button(
                deletable.count > 1
                    ? String(localized: "Delete \(deletable.count) Selected…")
                    : String(localized: "Delete Transcript…"),
                role: .destructive
            ) { requestDeletion(of: targets) }
        }
    }

    /// Only the record being recorded right now is protected — not every
    /// `endedAt == nil` record, since a crash or force-quit leaves those
    /// behind permanently and they'd otherwise be undeletable.
    private func isLive(_ session: RecordingSessionRecord) -> Bool {
        session.id == recordingSession.liveSessionID
    }

    private func isDeletable(_ session: RecordingSessionRecord) -> Bool {
        !isLive(session)
    }

    /// Never includes the live session:
    /// `RecordingSession` holds a live reference to that model object, so
    /// deleting it would make its next append/end mutate a deleted model.
    private func requestDeletion(of targets: [RecordingSessionRecord]) {
        let deletable = targets.filter(isDeletable)
        guard !deletable.isEmpty else { return }
        pendingRequest = .sessions(deletable)
    }

    private func performDeletion(_ targets: [RecordingSessionRecord]) {
        defer { pendingRequest = nil }
        let deletable = targets.filter(isDeletable)
        guard !deletable.isEmpty else { return }
        let ids = Set(deletable.map(\.id))
        // Cascade rule on `utterances` removes the child rows.
        for session in deletable { modelContext.delete(session) }
        try? modelContext.save()
        selection.subtract(ids)
    }

    private struct SessionGroup: Identifiable {
        /// Position, not `title` — a non-monotonic `startedAt` (clock change,
        /// future timestamp) could produce two groups with the same title.
        let id: Int
        let title: String
        var sessions: [RecordingSessionRecord]
    }

    /// Newest-first sessions bucketed into 今天 / 昨天 / 本周 / 本月 / "yyyy年M月".
    private var groupedSessions: [SessionGroup] {
        var groups: [SessionGroup] = []
        for session in filteredSessions {
            let title = Self.groupTitle(for: session.startedAt)
            if let last = groups.indices.last, groups[last].title == title {
                groups[last].sessions.append(session)
            } else {
                groups.append(SessionGroup(id: groups.count, title: title, sessions: [session]))
            }
        }
        return groups
    }

    private static func groupTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDate(date, equalTo: .now, toGranularity: .weekOfYear) { return String(localized: "This Week") }
        if calendar.isDate(date, equalTo: .now, toGranularity: .month) { return String(localized: "This Month") }
        return yearMonthFormatter.string(from: date)
    }

    /// The app's UI language, so month/weekday names match the localized
    /// date formats (which fall back to English when the system language is
    /// neither English nor 简体中文) instead of following `Locale.current`.
    private static let uiLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    private static let yearMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = uiLocale
        formatter.dateFormat = String(localized: "MMMM yyyy")
        return formatter
    }()

    private var filteredSessions: [RecordingSessionRecord] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(searchText)
                || session.displayTitle().localizedCaseInsensitiveContains(searchText)
                || session.utterances.contains {
                    $0.sourceText.localizedCaseInsensitiveContains(searchText)
                        || $0.translationText.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    private func beginRename(_ session: RecordingSessionRecord) {
        // Full first sentence, not the truncated list label — saving a
        // pre-filled "…" would permanently cut the title.
        renameText = session.displayTitle(maxLength: nil)
        renamingSession = session
    }

    private func commitRename() {
        defer { renamingSession = nil }
        guard let session = renamingSession else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty/whitespace-only rename silently keeps the existing title
        // instead of leaving a session with no title at all.
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        try? modelContext.save()
    }

    /// Card-style row: title + a smart relative timestamp on top, a tag line
    /// (duration, language pair, utterance count) below — replaces the old
    /// bare "N 条记录" caption with the metadata the proposal's history
    /// section (3.3.A) asks for.
    private func row(for session: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isLive(session) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
                Text(session.displayTitle())
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Self.relativeTimeLabel(for: session.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(
                [
                    isLive(session) ? String(localized: "Transcribing") : Self.durationLabel(from: session.startedAt, to: Self.endDate(of: session)),
                    String(localized: "Sentences: \(session.utterances.count)"),
                    Self.compactLanguagePair(for: session),
                ].joined(separator: " · ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.vertical, 2)
    }

    /// Cached formatters for `relativeTimeLabel(for:)` below — allocating a
    /// fresh `DateFormatter` on every row render is a real (if minor) scroll
    /// perf cost at list scale, matching the `static let` pattern
    /// `SessionExporter.dateFormatter` already uses elsewhere.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = uiLocale
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = uiLocale
        formatter.dateFormat = "EEE"
        return formatter
    }()
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = uiLocale
        formatter.dateFormat = String(localized: "MMM d, HH:mm")
        return formatter
    }()
    private static let yearMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = uiLocale
        formatter.dateFormat = String(localized: "MMM d, yyyy, HH:mm")
        return formatter
    }()

    /// "14:30" (today/yesterday, shown under their section header) /
    /// "周三 14:30" (this week) / "9月20日 14:30" (this year) / "2025年9月20日 14:30"
    /// once the year itself is no longer implied.
    private static func relativeTimeLabel(for date: Date) -> String {
        let calendar = Calendar.current
        // The sidebar's 今天/昨天 section headers already name the day, so
        // those rows only need the clock time.
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return timeFormatter.string(from: date)
        }
        // Several recordings on one day are told apart by clock time.
        if calendar.isDate(date, equalTo: .now, toGranularity: .weekOfYear) {
            return "\(weekdayFormatter.string(from: date)) \(timeFormatter.string(from: date))"
        }
        let formatter = calendar.isDate(date, equalTo: .now, toGranularity: .year)
            ? monthDayFormatter
            : yearMonthDayFormatter
        return formatter.string(from: date)
    }

    /// `endedAt`, or — for a record a crash left without one — its last
    /// utterance, so an orphan doesn't show an ever-growing duration.
    private static func endDate(of session: RecordingSessionRecord) -> Date {
        session.endedAt ?? session.utterances.max(by: { $0.createdAt < $1.createdAt })?.createdAt ?? session.startedAt
    }

    /// "38 分钟" once a full minute has elapsed, else "42 秒" — a session
    /// still in progress (`end == nil`) measures up through `.now`.
    private static func durationLabel(from start: Date, to end: Date?) -> String {
        // Floored at 0 so a clock adjustment can't produce "-1 秒".
        let seconds = max(0, (end ?? .now).timeIntervalSince(start))
        if seconds < 60 {
            return String(localized: "\(Int(seconds.rounded())) sec")
        }
        return String(localized: "\(Int((seconds / 60).rounded())) min")
    }

    /// "EN→ZH" (`AUTO→ZH` when the source is auto-detected, i.e. a nil
    /// `sourceLanguageCode`) — full display names don't fit the sidebar row.
    private static func compactLanguagePair(for session: RecordingSessionRecord) -> String {
        func short(_ code: String) -> String {
            code.split(separator: "-").first.map { $0.uppercased() } ?? code
        }
        let source = session.sourceLanguageCode.map(short) ?? "AUTO"
        return "\(source)→\(short(session.targetLanguageCode))"
    }
}
