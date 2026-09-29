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
    @State private var selectedID: UUID?
    /// Non-nil while a delete confirmation is on screen — set from the swipe
    /// action, the context menu, or ⌫, all funneled through the same
    /// `.confirmationDialog` so there's exactly one delete path to keep in
    /// sync with `RecordingSessionRecord`'s cascade-delete relationship.
    @State private var pendingDeletion: RecordingSessionRecord?
    /// Non-nil while the rename alert is on screen.
    @State private var renamingSession: RecordingSessionRecord?
    @State private var renameText: String = ""

    var body: some View {
        NavigationSplitView {
            List(filteredSessions, selection: $selectedID) { session in
                NavigationLink(value: session.id) {
                    row(for: session)
                }
                .swipeActions(edge: .trailing) {
                    // Never offered for the still-in-progress session
                    // (`endedAt == nil`, the one `RecordingSession` is
                    // actively appending to/ending) — see `pendingDeletion`'s
                    // delete handler below for why deleting it is unsafe.
                    if session.endedAt != nil {
                        Button(role: .destructive) {
                            pendingDeletion = session
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .contextMenu {
                    Button("重命名…") { beginRename(session) }
                    if session.endedAt != nil {
                        Button("删除会话…", role: .destructive) { pendingDeletion = session }
                    }
                }
            }
            .onDeleteCommand {
                guard let selectedID,
                    let session = sessions.first(where: { $0.id == selectedID }),
                    session.endedAt != nil
                else { return }
                pendingDeletion = session
            }
            .searchable(text: $searchText, prompt: "搜索转录或翻译内容")
            .navigationTitle("历史记录")
            .navigationDestination(for: UUID.self) { id in
                if let session = sessions.first(where: { $0.id == id }) {
                    SessionDetailView(session: session)
                }
            }
        } detail: {
            ContentUnavailableView(
                "选择一个会话",
                systemImage: "text.bubble",
                description: Text("在左侧列表中选择一次录制查看详情")
            )
        }
        .frame(minWidth: 720, minHeight: 460)
        .confirmationDialog(
            "删除会话？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let session = pendingDeletion, session.endedAt != nil {
                    // `RecordingSessionRecord`'s `@Relationship(deleteRule:
                    // .cascade, ...)` already cascades to every one of its
                    // `UtteranceRecord`s — no separate cleanup needed here.
                    //
                    // Never the still-in-progress session (`endedAt == nil`,
                    // guarded above defensively even though every path that
                    // sets `pendingDeletion` already excludes it): this
                    // view's `modelContext` and `RecordingSession`'s
                    // `SessionStore` share the same `ModelContainer.mainContext`,
                    // so deleting that session's model object here would
                    // delete the very object `RecordingSession` still holds a
                    // live reference to — the next `appendUtterance`/`endSession`
                    // call would then mutate/save a deleted SwiftData model.
                    modelContext.delete(session)
                    try? modelContext.save()
                    // Resetting stale selection after a delete — leaving
                    // `selectedID` pointing at the now-deleted session's
                    // UUID left the detail pane blank instead of resetting to
                    // the "选择一个会话" placeholder, and a subsequent ⌫ did
                    // nothing since `selectedID` no longer resolved to any
                    // session.
                    if selectedID == session.id {
                        selectedID = nil
                    }
                }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("删除后无法恢复。")
        }
        .alert(
            "重命名会话",
            isPresented: Binding(get: { renamingSession != nil }, set: { if !$0 { renamingSession = nil } })
        ) {
            TextField("会话标题", text: $renameText)
            Button("保存") { commitRename() }
            Button("取消", role: .cancel) { renamingSession = nil }
        }
    }

    private var filteredSessions: [RecordingSessionRecord] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(searchText)
                || session.utterances.contains {
                    $0.sourceText.localizedCaseInsensitiveContains(searchText)
                        || $0.translationText.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    private func beginRename(_ session: RecordingSessionRecord) {
        renameText = session.title
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title)
                    .font(.headline)
                Spacer()
                Text(Self.relativeTimeLabel(for: session.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Label(Self.durationLabel(from: session.startedAt, to: session.endedAt), systemImage: "clock")
                Label(Self.languagePairLabel(for: session), systemImage: "globe")
                Label("\(session.utterances.count) 句", systemImage: "text.bubble")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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

    /// "今天 14:30" / "昨天 09:15" / "9月20日" (this year, no year) / a full
    /// dated string once the year itself is no longer implied.
    private static func relativeTimeLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天 \(timeFormatter.string(from: date))"
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 \(timeFormatter.string(from: date))"
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

    /// "英语 ➔ 简体中文" — looks both codes up through the same
    /// `LanguageCatalog.common` the floating panel/Settings pickers use, so
    /// the label always matches what the user actually picked from those
    /// menus. `sourceLanguageCode == nil` means "自动" (auto-detect, only
    /// ever offered for a `.model`-kind ASR engine — see `RecordingSession
    /// .sourceLanguageCode`'s doc).
    private static func languagePairLabel(for session: RecordingSessionRecord) -> String {
        // Only an actually-nil `sourceLanguageCode` means "自动" (auto-
        // detect) — a non-nil code that just isn't in `LanguageCatalog.common`
        // (an unrecognized/custom code) should fall back to showing the raw
        // code itself, same as `targetLabel` below already does, not be
        // mistaken for "auto-detect".
        let sourceLabel: String
        if let code = session.sourceLanguageCode {
            sourceLabel = LanguageCatalog.common.first { $0.code == code }?.displayName ?? code
        } else {
            sourceLabel = "自动"
        }
        let targetLabel = LanguageCatalog.common.first { $0.code == session.targetLanguageCode }?.displayName
            ?? session.targetLanguageCode
        return "\(sourceLabel) ➔ \(targetLabel)"
    }
}
