import Foundation

/// Online speaker clustering (pure Swift, engine-independent, unit-tested).
///
/// Each row's embedding is compared by cosine similarity with every known
/// speaker's running centroid: above `threshold` it joins the closest one
/// (and updates that centroid), otherwise it starts a new speaker. `seed`
/// adds remembered voices up front so they are recognized immediately.
public struct SpeakerClusterer: Sendable {
    /// Higher splits one person into two more easily; lower merges two people more easily.
    public var threshold: Float
    /// Cap on speakers; beyond it new voices join the closest speaker instead of fragmenting.
    public var maxSpeakers: Int
    /// Lower threshold for remembered voices: the same person scores lower
    /// across transcriptions and rooms, and a remembered voice was confirmed
    /// by the user, so it gets more slack.
    public var seedThreshold: Float

    private var sums: [[Float]] = []
    /// The first `seededCount` speakers are remembered voices.
    private var seededCount = 0
    /// Best similarity to a remembered voice in the last `assign` (nil without
    /// remembered voices); logged for tuning.
    public private(set) var lastBestSeedSimilarity: Float?

    public init(threshold: Float = 0.6, maxSpeakers: Int = 12) {
        self.threshold = threshold
        self.maxSpeakers = maxSpeakers
        self.seedThreshold = Self.seedThreshold(for: threshold)
    }

    /// Remembered-voice threshold: `threshold` − 0.15, at least 0.3.
    public static func seedThreshold(for threshold: Float) -> Float { max(threshold - 0.15, 0.3) }

    public var speakerCount: Int { sums.count }

    public mutating func reset() { sums.removeAll(); seededCount = 0; lastBestSeedSimilarity = nil }

    /// Adds a known speaker (a remembered voice) and returns its index. A larger
    /// `weight` keeps it from drifting toward this transcription's audio.
    @discardableResult
    public mutating func seed(_ embedding: [Float], weight: Float = 3) -> Int {
        let e = Self.normalized(embedding)
        sums.append(e.map { $0 * weight })
        seededCount = sums.count
        return sums.count - 1
    }

    /// The normalized centroid of speaker `index`.
    public func centroid(at index: Int) -> [Float]? {
        guard sums.indices.contains(index) else { return nil }
        return Self.normalized(sums[index])
    }

    /// The zero-based speaker index for this embedding (need not be normalized).
    public mutating func assign(_ embedding: [Float]) -> Int {
        let e = Self.normalized(embedding)
        guard !e.isEmpty else { return 0 }
        // Remembered voices first, with the lower threshold.
        var bestSeed = -1
        var bestSeedSim: Float = -2
        for i in 0..<min(seededCount, sums.count) {
            let sim = Self.dot(e, Self.normalized(sums[i]))
            if sim > bestSeedSim { bestSeedSim = sim; bestSeed = i }
        }
        lastBestSeedSimilarity = bestSeed >= 0 ? bestSeedSim : nil
        if bestSeed >= 0, bestSeedSim >= seedThreshold {
            for k in e.indices { sums[bestSeed][k] += e[k] }
            return bestSeed
        }
        var best = -1
        var bestSim: Float = -2
        for (i, sum) in sums.enumerated() {
            let sim = Self.dot(e, Self.normalized(sum))
            if sim > bestSim { bestSim = sim; best = i }
        }
        if best >= 0, bestSim >= threshold || sums.count >= maxSpeakers {
            for k in e.indices { sums[best][k] += e[k] }
            return best
        }
        sums.append(e)
        return sums.count - 1
    }

    /// 0 → “A”, 25 → “Z”, 26 → “AA”, …
    public static func letter(for index: Int) -> String {
        var n = index
        var s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = dot(v, v).squareRoot()
        guard norm > 0, norm.isFinite else { return [] }
        return v.map { $0 / norm }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }
}
