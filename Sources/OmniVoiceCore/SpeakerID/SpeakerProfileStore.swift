import Foundation

/// A remembered voice: a name and an averaged embedding.
public struct SpeakerProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var embedding: [Float]
    public var updatedAt: Date
}

/// Remembered voices, kept in their own JSON file outside the SwiftData
/// store so schema changes never touch them.
public struct SpeakerProfileStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = SpeakerProfileStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OmniVoice/SpeakerProfiles.json")
    }

    public func load() -> [SpeakerProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SpeakerProfile].self, from: data)) ?? []
    }

    public func save(_ profiles: [SpeakerProfile]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
