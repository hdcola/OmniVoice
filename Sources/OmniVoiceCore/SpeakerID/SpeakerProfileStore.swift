import Foundation

/// One embedding saved by a single “remember”.
public struct SpeakerSample: Codable, Sendable, Equatable {
    /// Normalized embedding.
    public var embedding: [Float]
    /// Seconds of voiced audio behind it (0 for voices saved before samples existed).
    public var seconds: Double
    public var date: Date

    public init(embedding: [Float], seconds: Double, date: Date = .now) {
        self.embedding = embedding
        self.seconds = seconds
        self.date = date
    }

    /// Weight when combining: longer is more reliable; unknown length counts as 5 s.
    var weight: Double { seconds > 0 ? seconds : 5 }
}

/// A remembered voice: a name and an embedding.
public struct SpeakerProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// The embedding used for recognition: the dominant voice among `samples`.
    public var embedding: [Float]
    public var updatedAt: Date
    /// One sample per “remember”, so Settings can point out a sample that
    /// doesn't match the others. Absent in voices saved by earlier versions.
    public var samples: [SpeakerSample]?
    /// Other voices the user confirmed are a different person.
    public var distinctFrom: [UUID]?

    public var allSamples: [SpeakerSample] {
        samples ?? [SpeakerSample(embedding: embedding, seconds: 0, date: updatedAt)]
    }

    /// Recomputes `embedding` from `samples`, keeping only the dominant voice.
    public mutating func refreshEmbedding(sameVoice: Float) {
        let all = allSamples
        guard !all.isEmpty else { return }
        let e = SpeakerVoice.dominant(all, sameVoice: sameVoice).embedding
        if !e.isEmpty { embedding = e }
    }
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
