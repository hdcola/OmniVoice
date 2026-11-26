import Foundation

/// Small embedding helpers for speaker identification (pure Swift, unit-tested).
public enum SpeakerVoice {
    /// Cosine similarity of two embeddings (normalized first).
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        SpeakerClusterer.dot(SpeakerClusterer.normalized(a), SpeakerClusterer.normalized(b))
    }

    /// The dominant voice in a set of embeddings.
    ///
    /// Each sample in turn is taken as a center; the samples at least `sameVoice`
    /// similar to it are summed by duration, and the group with the most audio
    /// wins. Returns that group's weighted mean (normalized) and which samples it
    /// used, so a few rows from somebody else are left out.
    public static func dominant(_ samples: [SpeakerSample], sameVoice: Float) -> (embedding: [Float], included: [Int]) {
        let vs = samples.map { SpeakerClusterer.normalized($0.embedding) }
        var best: [Int] = []
        var bestWeight = -1.0
        for i in vs.indices where !vs[i].isEmpty {
            let group = vs.indices.filter { !vs[$0].isEmpty && ($0 == i || SpeakerClusterer.dot(vs[i], vs[$0]) >= sameVoice) }
            let w = group.reduce(0.0) { $0 + samples[$1].weight }
            if w > bestWeight { bestWeight = w; best = group }
        }
        guard let dim = best.first.map({ vs[$0].count }) else { return ([], []) }
        var sum = [Float](repeating: 0, count: dim)
        for i in best {
            let w = Float(samples[i].weight)
            for k in 0..<min(dim, vs[i].count) { sum[k] += vs[i][k] * w }
        }
        return (SpeakerClusterer.normalized(sum), best)
    }
}

/// Something worth tidying up among remembered voices.
public struct SpeakerProfileIssue: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The samples of one name don't agree: `samples` are the ones unlike the
        /// dominant voice, `similarities` their similarity to it.
        case mixed(profile: UUID, samples: [Int], similarities: [Float])
        /// Two names sound alike. `likelySame`: probably one person; otherwise
        /// close enough to be confused during a transcription.
        case similar(UUID, UUID, similarity: Float, likelySame: Bool)
    }

    public let kind: Kind
    public var id: String {
        switch kind {
        case .mixed(let p, let s, _): return "mixed-\(p)-\(s)"
        case .similar(let a, let b, _, _): return "similar-\(a)-\(b)"
        }
    }

    /// Finds all issues. Above `threshold` two voices are probably the same
    /// person; above the remembered-voice threshold (threshold − 0.15) they can
    /// be confused.
    public static func find(in profiles: [SpeakerProfile], threshold: Float) -> [SpeakerProfileIssue] {
        let same = SpeakerClusterer.seedThreshold(for: threshold)
        var issues: [SpeakerProfileIssue] = []
        for p in profiles {
            let all = p.allSamples
            guard all.count > 1 else { continue }
            let main = SpeakerVoice.dominant(all, sameVoice: same)
            let outliers = all.indices.filter { !main.included.contains($0) }
            if !outliers.isEmpty {
                let sims = outliers.map { SpeakerVoice.similarity(all[$0].embedding, main.embedding) }
                issues.append(.init(kind: .mixed(profile: p.id, samples: outliers, similarities: sims)))
            }
        }
        for i in profiles.indices {
            for j in profiles.indices where j > i {
                let a = profiles[i], b = profiles[j]
                if (a.distinctFrom ?? []).contains(b.id) || (b.distinctFrom ?? []).contains(a.id) { continue }
                let sim = SpeakerVoice.similarity(a.embedding, b.embedding)
                if sim >= same {
                    issues.append(.init(kind: .similar(a.id, b.id, similarity: sim, likelySame: sim >= threshold)))
                }
            }
        }
        return issues
    }
}
