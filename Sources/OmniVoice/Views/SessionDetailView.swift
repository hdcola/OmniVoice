import OmniVoiceCore
import SwiftUI

/// Read-only view of one past recording's full aligned source/translation
/// transcript, plus a Markdown export.
struct SessionDetailView: View {
    let session: RecordingSessionRecord
    @State private var exportDocument: TextFileDocument?
    @State private var isExporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(session.utterances.sorted(by: { $0.index < $1.index })) { utterance in
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
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(session.title)
        .toolbar {
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
}
