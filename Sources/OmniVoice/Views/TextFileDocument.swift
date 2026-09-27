import SwiftUI
import UniformTypeIdentifiers

/// Minimal `FileDocument` wrapping a plain-text export — backs
/// `SessionDetailView`'s `.fileExporter`. `SessionExporter` produces the
/// actual Markdown content; this is just the save-dialog plumbing.
struct TextFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
