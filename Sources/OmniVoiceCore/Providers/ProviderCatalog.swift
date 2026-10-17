import Foundation

/// Whether an engine runs entirely on-device via a bundled/downloaded model,
/// or delegates to a macOS system framework. Kept as just these two for now
/// per the MVP scope — a third `.cloud` case (third-party API providers) is
/// the expected next addition once that's in scope, which is exactly why
/// this lives as data (`ProviderCatalog`) rather than a hand-written picker
/// with one `case` per engine.
public enum EngineKind: String, Codable, Sendable {
    case system
    case model
}

/// One selectable ASR or translation engine, as shown in a picker.
public struct EngineDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: EngineKind
    /// Short badge text (Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.2.1's
    /// `[系统原生 · 零内存占用]`/`[推荐 · 支持实时预览]`) — user-facing, shown
    /// next to `displayName` in the richer engine selection cards.
    public let badge: String
    /// One-sentence functional summary (§4.2.1's "macOS 系统级语音识别，即开
    /// 即用，无需额外下载。" line) — what this engine actually does/is for,
    /// not just its name.
    public let summary: String

    public init(id: String, displayName: String, kind: EngineKind, badge: String = "", summary: String = "") {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.badge = badge
        self.summary = summary
    }
}

/// One file of a multi-file model package (e.g. a sherpa-onnx transducer's
/// encoder/decoder/joiner/tokens), downloaded and verified individually.
public struct ModelFile: Hashable, Codable, Sendable {
    public let name: String
    public let url: URL
    public let sizeBytes: Int64
    public let sha256: String

    public init(name: String, url: URL, sizeBytes: Int64, sha256: String) {
        self.name = name
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

/// One downloadable weights file for a `.model`-kind engine — e.g. a
/// specific size/quantization of R2T2 or T3PO. Deliberately data, not an
/// enum case per model: as audio.cpp gains support for more community
/// models, growing this list should never require touching provider code,
/// only this catalog (and, eventually, a real download source).
public struct ModelVariant: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let engineID: String
    public let displayName: String
    public let quantization: String
    public let approximateSizeMB: Int
    /// Hosted on Hugging Face (`resolve/main/...`), same URLs
    /// `Docs/MODEL_ENGINE_SETUP.md`'s manual `curl` recipe uses — fetched by
    /// `ModelDownloadManager` on first use. Nil for a variant not yet
    /// selectable (no known download source).
    public let downloadURL: URL?
    /// SHA-256 of the weights file, verified by `ModelDownloadManager`
    /// against Hugging Face's LFS metadata (`X-Linked-ETag`/the `blobs=true`
    /// API) before a download is considered usable — never derived by
    /// hashing our own download, which would just check the download against
    /// itself.
    public let sha256: String?
    /// User-facing feature summary for the rich model card (Docs/UX-SETTINGS-MODEL-MANAGEMENT.md
    /// §4.3.2's "优势" line) — e.g. what this variant is optimized for, and
    /// how it differs from its siblings.
    public let summary: String
    /// Approximate unified-memory/VRAM footprint once loaded — distinct from
    /// `approximateSizeMB` (the on-disk download size), which is usually
    /// close but not identical. Used by the rich model card's "预计内存占用" line
    /// and the "引擎运行与内存状态" console's resource estimate.
    public let recommendedMemoryGB: Int
    /// Non-empty for a multi-file package: the variant is then a directory
    /// holding exactly these files (`ModelDownloadManager.localURL(for:)` is
    /// that directory) and `downloadURL`/`sha256` stay nil.
    public let files: [ModelFile]

    public init(
        id: String, engineID: String, displayName: String, quantization: String,
        approximateSizeMB: Int, downloadURL: URL? = nil, sha256: String? = nil,
        summary: String = "", recommendedMemoryGB: Int = 0, files: [ModelFile] = []
    ) {
        self.files = files
        self.id = id
        self.engineID = engineID
        self.displayName = displayName
        self.quantization = quantization
        self.approximateSizeMB = approximateSizeMB
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.summary = summary
        self.recommendedMemoryGB = recommendedMemoryGB
    }
}

/// One recommended engine pairing (Docs/UX-SETTINGS-MODEL-MANAGEMENT.md
/// §4.3.1 "一键配置推荐组合") — a named bundle of `ModelVariant`s a user can
/// download in one action instead of hunting for the right ASR/translation
/// pairing themselves.
public struct ModelBundle: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let variantIDs: [String]
    public let recommendedMemoryGB: Int

    public init(id: String, displayName: String, summary: String, variantIDs: [String], recommendedMemoryGB: Int) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.variantIDs = variantIDs
        self.recommendedMemoryGB = recommendedMemoryGB
    }
}

/// The static, built-in list of engines/model variants this build ships
/// knowing about. Intentionally not user-editable (unlike a downloaded
/// model's local file, which does live in user-writable storage) — adding a
/// new community model audio.cpp supports means adding an entry here, not a
/// schema change.
public enum ProviderCatalog {
    public static let transcriptionEngines: [EngineDescriptor] = [
        EngineDescriptor(
            id: "system.speech", displayName: String(localized: "System speech recognition"), kind: .system,
            badge: String(localized: "Built into macOS · Zero memory use"),
            summary: String(localized: "macOS system speech recognition. Ready to use, no extra download.")
        ),
        EngineDescriptor(
            id: "model.r2t2", displayName: String(localized: "R2T2 offline model"), kind: .model,
            badge: String(localized: "Recommended · Automatic language detection"),
            summary: String(localized: "Supports streaming live transcription, punctuation prediction and automatic detection of mixed languages.")
        ),
        EngineDescriptor(
            id: "model.sherpa", displayName: String(localized: "Streaming Zipformer model"), kind: .model,
            badge: String(localized: "Lightweight · Low latency"),
            summary: String(localized: "Small streaming model with very low latency and little memory use. Text appears as you speak, without punctuation; Dictation’s “Polish recognized text” can tidy it up.")
        ),
    ]

    public static let translationEngines: [EngineDescriptor] = [
        EngineDescriptor(
            id: "system.translation", displayName: String(localized: "System translation"), kind: .system,
            badge: String(localized: "Built into macOS · Sentence-by-sentence translation"),
            summary: String(localized: "Built-in macOS translation. Translates by sentence punctuation; no live typewriter preview.")
        ),
        EngineDescriptor(
            id: "model.t3po", displayName: String(localized: "T3PO offline model"), kind: .model,
            badge: String(localized: "Recommended · Live preview"),
            summary: String(localized: "High-performance bilingual translation model with typewriter-style character-by-character streaming preview and automatic correction.")
        ),
        EngineDescriptor(
            id: "model.hymt15", displayName: String(localized: "HY-MT1.5 1.8B model"), kind: .model,
            badge: String(localized: "Lightweight · Low memory"),
            summary: String(localized: "Tencent Hunyuan lightweight translation model. Low memory use, whole-sentence translation (no streaming preview).")
        ),
    ]

    /// Model variants are keyed by `engineID` so a settings UI can filter
    /// "what sizes/quantizations exist for the currently-selected model
    /// engine" without switching on the engine identity itself.
    public static let modelVariants: [ModelVariant] = [
        ModelVariant(
            id: "r2t2-q8_0", engineID: "model.r2t2", displayName: "R2T2 (Q8_0)",
            quantization: "Q8_0", approximateSizeMB: 2363,
            downloadURL: URL(
                string: "https://huggingface.co/davidxifeng/Confucius4-R2T2-gguf/resolve/main/r2t2-q8_0.gguf"
            )!,
            // Verified against the file's HF LFS metadata
            // (`GET /api/models/davidxifeng/Confucius4-R2T2-gguf?blobs=true`),
            // which matches the `resolve/main` response's `X-Linked-ETag`.
            sha256: "19f5ccd624484bcb5d44301437de41560b0ecc40c430e8850dfeefefbe82ccf5",
            summary: String(localized: "Optimized for mixed Chinese-English talks and professional meetings, with automatic language detection and sentence/punctuation completion."),
            recommendedMemoryGB: 3
        ),
        // Smaller/faster R2T2 — a community Q4_K_M quantization (Q4_K with
        // Q6_K MLP-down and Q2_K embeddings, BF16 audio tower) by
        // NairoDorian, the one `audio.cpp`'s own docs/model spec list as
        // `confucius4_r2t2_q4_k_m`. NetEase's official Q4_K_M GGUF is *not*
        // usable here: it's llama.cpp-layout (`qwen3vl` + a separate `clip`
        // mmproj file), while audio.cpp's loader needs one self-contained
        // `audiocpp`-layout file. Not an official NetEase release — a
        // third-party derivative under the same model license. Size/hash
        // from `GET /api/models/Nairod785/Confucius4-R2T2-Q4_K_M-GGUF?blobs=true`.
        ModelVariant(
            id: "r2t2-q4_k_m", engineID: "model.r2t2", displayName: "R2T2 (Q4_K_M)",
            quantization: "Q4_K_M", approximateSizeMB: 1132,
            downloadURL: URL(
                string: "https://huggingface.co/Nairod785/Confucius4-R2T2-Q4_K_M-GGUF/resolve/main/r2t2-q4_k_m.gguf"
            )!,
            sha256: "d740d6636f2ea2f3736800c3c88a6e22ecb6c0f26c567fe22b0572ae9c2c4ec8",
            summary: String(localized: "Community quantization (unofficial release): about half the size of Q8_0, about 1.8GB peak memory at runtime, faster decoding, suited to memory-constrained devices; slightly lower accuracy than Q8_0."),
            recommendedMemoryGB: 2
        ),
        // Same publisher/repo as `r2t2-q8_0`; sha256 verified against HF's
        // LFS metadata (`?blobs=true`) and the `resolve/main`
        // `X-Linked-ETag`.
        ModelVariant(
            id: "r2t2-f16", engineID: "model.r2t2", displayName: "R2T2 (F16)",
            quantization: "F16", approximateSizeMB: 3902,
            downloadURL: URL(
                string: "https://huggingface.co/davidxifeng/Confucius4-R2T2-gguf/resolve/main/r2t2-f16.gguf"
            )!,
            sha256: "d1b531ceaf5640d98352d3a9180238d99d36d393e160afd4692031077e7bae2c",
            summary: String(localized: "Unquantized full-precision version with the highest quality; about 4.7GB peak memory at runtime (Q8_0 is about 3.1GB), suited to devices with plenty of memory."),
            recommendedMemoryGB: 5
        ),
        // sherpa-onnx streaming Zipformer, Chinese + English with code-switching.
        // Pinned HF revision; sizes/hashes match the files' LFS metadata.
        ModelVariant(
            id: "sherpa-zipformer-bilingual-zh-en", engineID: "model.sherpa",
            displayName: "Zipformer Bilingual (zh-en)", quantization: "FP32", approximateSizeMB: 357,
            summary: String(localized: "Chinese and English with code-switching, real-time streaming. About 360MB; English comes out in capitals without punctuation, which Dictation’s “Polish recognized text” can clean up."),
            recommendedMemoryGB: 1,
            files: [
                ModelFile(
                    name: "encoder-epoch-99-avg-1.onnx", url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/98590b7ed6443e77b714204da2757d75e1a642f4/encoder-epoch-99-avg-1.onnx")!,
                    sizeBytes: 330_083_505, sha256: "709f0ed53a734b7942f170127e7547b566cb29c4afc5e67719f314c3d63ccb10"
                ),
                ModelFile(
                    name: "decoder-epoch-99-avg-1.onnx", url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/98590b7ed6443e77b714204da2757d75e1a642f4/decoder-epoch-99-avg-1.onnx")!,
                    sizeBytes: 13_876_452, sha256: "2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d"
                ),
                ModelFile(
                    name: "joiner-epoch-99-avg-1.onnx", url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/98590b7ed6443e77b714204da2757d75e1a642f4/joiner-epoch-99-avg-1.onnx")!,
                    sizeBytes: 12_833_618, sha256: "5f2adc585dd1bec6421c8bb8660d2a73fc8b9ceb24491ef51399ba2a2f0fc31b"
                ),
                ModelFile(
                    name: "tokens.txt", url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/98590b7ed6443e77b714204da2757d75e1a642f4/tokens.txt")!,
                    sizeBytes: 56_317, sha256: "a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3"
                ),
            ]
        ),
        ModelVariant(
            id: "t3po-q5_k_m", engineID: "model.t3po", displayName: "T3PO (Q5_K_M)",
            quantization: "Q5_K_M", approximateSizeMB: 10021,
            downloadURL: URL(
                string:
                    "https://huggingface.co/netease-youdao/Confucius4-T3PO-GGUF/resolve/main/Confucius4-T3PO-Q5_K_M.gguf"
            )!,
            sha256: "019b162a8fdff3edb1e2469445043fc2ebb0de0fbda9ca6454bc86b5898fac35",
            summary: String(localized: "Streaming WAIT/TRANS live character-by-character preview, best for translating between Chinese/Cantonese/English/Japanese/Korean; recommended for devices with 16GB+ unified memory."),
            recommendedMemoryGB: 11
        ),
        // Tencent's HY-MT1.5-1.8B — the low-memory translation option: no
        // smaller quantization exists in R2T2's/T3PO's own repos (see
        // Docs/PROGRESS.md), so this is a separate, much smaller model
        // family instead, at the cost of no live preview (one-shot only —
        // see `HYMT15Translator`'s class doc). Sizes/hashes verified
        // against the file's HF LFS metadata
        // (`GET /api/models/tencent/HY-MT1.5-1.8B-GGUF?blobs=true`).
        ModelVariant(
            id: "hymt15-1.8b-q4_k_m", engineID: "model.hymt15", displayName: "HY-MT1.5 1.8B (Q4_K_M)",
            quantization: "Q4_K_M", approximateSizeMB: 1080,
            downloadURL: URL(
                string: "https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/resolve/main/HY-MT1.5-1.8B-Q4_K_M.gguf"
            )!,
            sha256: "4383ac0c3c8e476de98ff979c2a3f069f8c4fb385e7860cf2d28da896cc477c7",
            summary: String(localized: "One-shot whole-sentence translation with no live typewriter preview and minimal memory use; suited to 8GB devices."),
            recommendedMemoryGB: 2
        ),
        ModelVariant(
            id: "hymt15-1.8b-q8_0", engineID: "model.hymt15", displayName: "HY-MT1.5 1.8B (Q8_0)",
            quantization: "Q8_0", approximateSizeMB: 1820,
            downloadURL: URL(
                string: "https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/resolve/main/HY-MT1.5-1.8B-Q8_0.gguf"
            )!,
            sha256: "6789b06d0902f2f5312c0e1703d56ccbddfcfb6c653d22519b7c720f7db9a98e",
            summary: String(localized: "One-shot whole-sentence translation with no live typewriter preview; slightly higher accuracy than Q4_K_M with still-minimal memory use."),
            recommendedMemoryGB: 3
        ),
    ]

    /// Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.3.1 — the two standard
    /// pairings offered as one-click downloads above the model list, so a
    /// user doesn't have to work out on their own which ASR+translation
    /// combination actually makes sense together.
    public static let bundles: [ModelBundle] = [
        ModelBundle(
            id: "bundle.standard-realtime",
            displayName: String(localized: "Plan A: Standard live bilingual captions (recommended)"),
            summary: String(localized: "R2T2 speech recognition + T3PO live streaming translation. Automatic language detection, character-by-character typewriter display, fully offline and private. Recommended for Macs with 16GB+ unified memory."),
            variantIDs: ["r2t2-q8_0", "t3po-q5_k_m"],
            recommendedMemoryGB: 14
        ),
        ModelBundle(
            id: "bundle.lightweight",
            displayName: String(localized: "Plan B: Lightweight, low-memory"),
            summary: String(localized: "R2T2 speech recognition + HY-MT1.5 translation. Minimal memory use, whole-sentence translation output. Suited to 8GB devices."),
            variantIDs: ["r2t2-q8_0", "hymt15-1.8b-q4_k_m"],
            recommendedMemoryGB: 5
        ),
    ]

    /// Whether the engine reports a pause boundary the app should feed it
    /// (VAD → `notifyUtteranceBoundary()`). System ASR and the sherpa model
    /// close their own segments, so the sentence-pause settings do nothing
    /// for them.
    public static func usesVADBoundary(engineID: String) -> Bool {
        transcriptionEngines.first { $0.id == engineID }?.kind == .model && engineID != "model.sherpa"
    }

    public static func modelVariants(forEngineID engineID: String) -> [ModelVariant] {
        modelVariants.filter { $0.engineID == engineID }
    }

    /// The variant ID a selection should be switched to when the variant it
    /// currently resolves to (`selectedID`, or the engine's first catalog
    /// entry when unset/stale — mirroring `RecordingSession`'s own
    /// resolution) isn't downloaded but a *different* one for the same
    /// engine is: the first downloaded variant in catalog order. `nil` means
    /// leave the selection alone — the resolved variant is downloaded, or
    /// nothing is (that case is the engine-level fallback to `.system`'s
    /// job, and a deliberately-picked not-yet-downloaded variant must keep
    /// its selection).
    public static func replacementVariantID(
        forEngineID engineID: String, selectedID: String?, isDownloaded: (ModelVariant) -> Bool
    ) -> String? {
        let variants = modelVariants(forEngineID: engineID)
        let resolved = variants.first { $0.id == selectedID } ?? variants.first
        guard let resolved, !isDownloaded(resolved) else { return nil }
        return variants.first(where: isDownloaded)?.id
    }

    /// The variant to suggest downloading for `engineID` as a companion
    /// pick — the engine's default (first catalog) variant — or `nil` if
    /// *any* of the engine's variants is already downloaded. Checks the
    /// whole engine, not just the default: someone who deliberately took
    /// R2T2 Q4_K_M (low-memory) or F16 already has the engine and shouldn't
    /// be nudged toward a 2.3GB Q8_0 on top.
    public static func companionSuggestion(
        forEngineID engineID: String, isDownloaded: (ModelVariant) -> Bool
    ) -> ModelVariant? {
        let variants = modelVariants(forEngineID: engineID)
        guard !variants.contains(where: isDownloaded) else { return nil }
        return variants.first
    }

    public static func variant(forID id: String) -> ModelVariant? {
        modelVariants.first { $0.id == id }
    }
}

/// A `ModelBundle`'s download state, resolved strictly against the exact
/// `ModelVariant`s its `variantIDs` name — never every variant belonging to
/// the same `engineID`, and never a variant counted twice. Two bundles can
/// legitimately share a variant (both recommended pairings in
/// `ProviderCatalog.bundles` use `r2t2-q8_0`), so downloading it via one
/// bundle correctly reads as already-done in the other too — this type only
/// *reports* that shared state, it never infers a variant as downloaded from
/// a sibling quantization or its engine ID the way an `engineID`-keyed check
/// would.
public struct ModelBundleStatus: Sendable {
    public let variants: [ModelVariant]
    public let downloadedVariants: [ModelVariant]
    public let remainingVariants: [ModelVariant]

    public var isFullyDownloaded: Bool { remainingVariants.isEmpty }

    /// Total size of only the variants this specific bundle is still
    /// missing — never the whole bundle's size, and never another bundle's
    /// variants, so a "一键下载剩余组件" button's stated size always matches
    /// exactly what tapping it will transfer.
    public var remainingSizeMB: Int { remainingVariants.reduce(0) { $0 + $1.approximateSizeMB } }
}

extension ModelBundle {
    /// - Parameter isDownloaded: typically `ModelDownloadManager.isDownloaded(_:)`,
    ///   injected so this stays testable without a real `ModelDownloadManager`/
    ///   filesystem.
    public func status(isDownloaded: (ModelVariant) -> Bool) -> ModelBundleStatus {
        let variants = variantIDs.compactMap(ProviderCatalog.variant(forID:))
        return ModelBundleStatus(
            variants: variants,
            downloadedVariants: variants.filter(isDownloaded),
            remainingVariants: variants.filter { !isDownloaded($0) }
        )
    }
}
