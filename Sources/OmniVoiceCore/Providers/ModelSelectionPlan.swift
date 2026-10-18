import Foundation

/// What the first-run wizard (and its re-run) is about to set up: one
/// recognition model and one translation model, each either a downloadable
/// variant or `nil` for the system engine. Pure value type so the memory
/// total, disk need and compatibility notes can be unit-tested without UI.
public struct ModelSelectionPlan: Equatable, Sendable {
    public var transcription: ModelVariant?
    public var translation: ModelVariant?

    public init(transcription: ModelVariant?, translation: ModelVariant?) {
        self.transcription = transcription
        self.translation = translation
    }

    public var localVariants: [ModelVariant] { [transcription, translation].compactMap { $0 } }

    /// Sum of the selected models' peak memory (system engines count 0).
    public var memoryMB: Int { localVariants.reduce(0) { $0 + $1.estimatedMemoryMB } }

    /// Whether any part of `memoryMB` is derived rather than measured.
    public var isMemoryEstimated: Bool { localVariants.contains { $0.isMemoryEstimated || $0.memoryMB == nil } }

    /// Download size of what isn't on disk yet.
    public func downloadMB(isDownloaded: (ModelVariant) -> Bool) -> Int {
        localVariants.filter { !isDownloaded($0) }.reduce(0) { $0 + $1.approximateSizeMB }
    }

    public enum MemoryPressure: Equatable, Sendable {
        case comfortable
        /// At least half of the Mac's memory.
        case tight
        /// At least 70% of it.
        case overcommitted
    }

    public func pressure(physicalMemoryMB: Int) -> MemoryPressure {
        guard physicalMemoryMB > 0 else { return .comfortable }
        let share = Double(memoryMB) / Double(physicalMemoryMB)
        if share >= 0.7 { return .overcommitted }
        if share >= 0.5 { return .tight }
        return .comfortable
    }

    public enum Note: Equatable, Sendable {
        /// T3PO previews word by word from the recognizer's append-only
        /// stream; sherpa-onnx has none, so translation waits for the
        /// segment to close.
        case translationWaitsForSentenceEnd
        /// The recognition model only knows these languages.
        case limitedLanguages([String])
    }

    public var notes: [Note] {
        var notes: [Note] = []
        if transcription?.engineID == "model.sherpa", translation?.engineID == "model.t3po" {
            notes.append(.translationWaitsForSentenceEnd)
        }
        if let codes = transcription?.sourceLanguageCodes {
            notes.append(.limitedLanguages(codes))
        }
        return notes
    }

    /// Whether "启动时加载模型" should default to loading: only when a local
    /// model is selected.
    public var hasLocalModel: Bool { !localVariants.isEmpty }

    /// Preselection by Mac memory: the large pair (R2T2 + T3PO, about 14 GB)
    /// only where it leaves room, the light pair (Paraformer bilingual +
    /// HY-MT1.5) otherwise.
    public static func recommended(physicalMemoryMB: Int) -> ModelSelectionPlan {
        let ids = physicalMemoryMB >= 24 * 1024
            ? ("r2t2-q8_0", "t3po-q5_k_m")
            : ("sherpa-paraformer-bilingual-zh-en", "hymt15-1.8b-q4_k_m")
        return ModelSelectionPlan(
            transcription: ProviderCatalog.variant(forID: ids.0), translation: ProviderCatalog.variant(forID: ids.1)
        )
    }
}

/// "540 MB" / "1.5 GB" — one spelling of a memory or download size for the
/// model cards and the wizard's totals.
public enum MemoryFormat {
    public static func text(mb: Int) -> String {
        mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000) : "\(mb) MB"
    }
}
