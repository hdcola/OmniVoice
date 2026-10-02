import OmniVoiceCore
import SwiftData
import SwiftUI

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
    /// Drives `List(selection:)` below, so `.onDeleteCommand` (the ⌫ key) has
    /// something to act on — `NavigationLink(value:)` and `List(selection:)`
    /// share the same `UUID` values, so picking a row for navigation and
    /// picking it for deletion are the same selection.
    @State private var selection: Set<UUID> = []
    /// Non-nil while a delete confirmation is on screen — set from the swipe
    /// action, the context menu, or ⌫, all funneled through the same
    /// `.confirmationDialog` so there's exactly one delete path to keep in
    /// sync with `RecordingSessionRecord`'s cascade-delete relationship.
    @State private var pendingDeletion: [RecordingSessionRecord] = []
    /// Non-empty while the "clean up old records" confirmation is on screen.
    @State private var pendingCleanupDays: Int?
    /// Non-nil while the rename alert is on screen.
    @State private var renamingSession: RecordingSessionRecord?
    @State private var renameText: String = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(groupedSessions, id: \.title) { group in
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
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("删除所选 \(selectedDeletable.count) 条…", role: .destructive) {
                            requestDeletion(of: selectedSessions)
                        }
                        .disabled(selectedDeletable.isEmpty)
                        Divider()
                        Button("删除 30 天前的记录…") { pendingCleanupDays = 30 }
                        Button("删除 90 天前的记录…") { pendingCleanupDays = 90 }
                    } label: {
                        Label("管理", systemImage: "trash")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索转录或翻译内容")
            .navigationTitle("历史记录")
        } detail: {
            // Detail is driven straight from the selection: a `NavigationLink`
            // inside a multi-selection `List` doesn't reliably fire on the
            // first click.
            if selection.count == 1, let id = selection.first,
                let session = sessions.first(where: { $0.id == id })
            {
                SessionDetailView(session: session)
                    .id(session.id)
            } else if selection.count > 1 {
                ContentUnavailableView(
                    "已选择 \(selection.count) 条记录",
                    systemImage: "checkmark.circle",
                    description: Text("按 ⌫ 或使用工具栏“管理”菜单批量删除")
                )
            } else {
                ContentUnavailableView(
                    "选择一条转录记录",
                    systemImage: "text.bubble",
                    description: Text("在左侧列表中选择一条转录记录查看详情")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 460)
        .confirmationDialog(
            "删除 \(pendingDeletion.count) 条转录记录？",
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { performDeletion(pendingDeletion) }
            Button("取消", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("删除后无法恢复。录制中的记录不会被删除。")
        }
        .confirmationDialog(
            "删除 \(pendingCleanupDays ?? 0) 天前的记录？",
            isPresented: Binding(get: { pendingCleanupDays != nil }, set: { if !$0 { pendingCleanupDays = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let days = pendingCleanupDays {
                    let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
                    performDeletion(sessions.filter { $0.startedAt < cutoff })
                }
                pendingCleanupDays = nil
            }
            Button("取消", role: .cancel) { pendingCleanupDays = nil }
        } message: {
            Text("将删除开始于 \(pendingCleanupDays ?? 0) 天前的所有转录记录，无法恢复。")
        }
        .alert(
            "重命名转录记录",
            isPresented: Binding(get: { renamingSession != nil }, set: { if !$0 { renamingSession = nil } })
        ) {
            TextField("转录记录标题", text: $renameText)
            Button("保存") { commitRename() }
            Button("取消", role: .cancel) { renamingSession = nil }
        }
    }

    private var selectedSessions: [RecordingSessionRecord] {
        sessions.filter { selection.contains($0.id) }
    }

    private var selectedDeletable: [RecordingSessionRecord] {
        selectedSessions.filter { $0.endedAt != nil }
    }

    @ViewBuilder
    private func contextMenu(for session: RecordingSessionRecord) -> some View {
        Button("重命名…") { beginRename(session) }
        // Right-clicking a row inside a multi-selection acts on the whole
        // selection, like Finder; otherwise just that row.
        let targets = selection.contains(session.id) ? selectedSessions : [session]
        let deletable = targets.filter { $0.endedAt != nil }
        if !deletable.isEmpty {
            Button(
                deletable.count > 1 ? "删除所选 \(deletable.count) 条…" : "删除转录记录…",
                role: .destructive
            ) { requestDeletion(of: targets) }
        }
    }

    /// Never includes the still-in-progress session (`endedAt == nil`):
    /// `RecordingSession` holds a live reference to that model object, so
    /// deleting it would make its next append/end mutate a deleted model.
    private func requestDeletion(of targets: [RecordingSessionRecord]) {
        let deletable = targets.filter { $0.endedAt != nil }
        guard !deletable.isEmpty else { return }
        pendingDeletion = deletable
    }

    private func performDeletion(_ targets: [RecordingSessionRecord]) {
        defer { pendingDeletion = [] }
        let deletable = targets.filter { $0.endedAt != nil }
        guard !deletable.isEmpty else { return }
        let ids = Set(deletable.map(\.id))
        // Cascade rule on `utterances` removes the child rows.
        for session in deletable { modelContext.delete(session) }
        try? modelContext.save()
        selection.subtract(ids)
    }

    private struct SessionGroup {
        let title: String
        let sessions: [RecordingSessionRecord]
    }

    /// Newest-first sessions bucketed into 今天 / 昨天 / 本周 / 本月 / "yyyy年M月".
    private var groupedSessions: [SessionGroup] {
        var groups: [SessionGroup] = []
        for session in filteredSessions {
            let title = Self.groupTitle(for: session.startedAt)
            if let last = groups.last, last.title == title {
                groups[groups.count - 1] = SessionGroup(title: title, sessions: last.sessions + [session])
            } else {
                groups.append(SessionGroup(title: title, sessions: [session]))
            }
        }
        return groups
    }

    private static func groupTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .weekOfYear) { return "本周" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .month) { return "本月" }
        return yearMonthFormatter.string(from: date)
    }

    private static let yearMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    private var filteredSessions: [RecordingSessionRecord] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { session in
            session.displayTitle().localizedCaseInsensitiveContains(searchText)
                || session.title.localizedCaseInsensitiveContains(searchText)
                || session.utterances.contains {
                    $0.sourceText.localizedCaseInsensitiveContains(searchText)
                        || $0.translationText.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    private func beginRename(_ session: RecordingSessionRecord) {
        renameText = session.displayTitle()
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
                if session.endedAt == nil {
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
                    session.endedAt == nil ? "录制中" : Self.durationLabel(from: session.startedAt, to: session.endedAt),
                    "\(session.utterances.count) 句",
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
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()
    private static let yearMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    /// "14:30" (today/yesterday, shown under their section header) / "9月20日" (this year, no year) / a full
    /// dated string once the year itself is no longer implied.
    private static func relativeTimeLabel(for date: Date) -> String {
        let calendar = Calendar.current
        // The sidebar's 今天/昨天 section headers already name the day, so
        // those rows only need the clock time.
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return timeFormatter.string(from: date)
        }
        let formatter = calendar.isDate(date, equalTo: .now, toGranularity: .year)
            ? monthDayFormatter
            : yearMonthDayFormatter
        return formatter.string(from: date)
    }

    /// "38 分钟" once a full minute has elapsed, else "42 秒" — a session
    /// still in progress (`endedAt == nil`) measures up through `.now`.
    private static func durationLabel(from start: Date, to end: Date?) -> String {
        let seconds = (end ?? .now).timeIntervalSince(start)
        if seconds < 60 {
            return "\(Int(seconds.rounded())) 秒"
        }
        return "\(Int((seconds / 60).rounded())) 分钟"
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
