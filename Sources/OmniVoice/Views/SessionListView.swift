import OmniVoiceCore
import SwiftData
import SwiftUI

/// The history window's sidebar — every past (and the current, if running)
/// recording, searchable, newest first.
struct SessionListView: View {
    @Query(sort: \RecordingSessionRecord.startedAt, order: .reverse)
    private var sessions: [RecordingSessionRecord]
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            List(filteredSessions) { session in
                NavigationLink(value: session.id) {
                    VStack(alignment: .leading) {
                        Text(session.title)
                        Text("\(session.utterances.count) 条记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
}
