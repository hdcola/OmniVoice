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
    /// Source languages (`LanguageCatalog` codes) this variant can recognize,
    /// for a model that covers only a few; nil means no restriction of its own.
    public let sourceLanguageCodes: [String]?
    /// Measured peak memory in MB, for a model well under 1GB where
    /// `recommendedMemoryGB` (whole GB, rounded up) would overstate it. The
    /// model card shows this when set.
    public let memoryMB: Int?

    public init(
        id: String, engineID: String, displayName: String, quantization: String,
        approximateSizeMB: Int, downloadURL: URL? = nil, sha256: String? = nil,
        summary: String = "", recommendedMemoryGB: Int = 0, files: [ModelFile] = [],
        sourceLanguageCodes: [String]? = nil, memoryMB: Int? = nil
    ) {
        self.memoryMB = memoryMB
        self.files = files
        self.sourceLanguageCodes = sourceLanguageCodes
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
            id: "model.r2t2", displayName: String(localized: "audio.cpp local engine"), kind: .model,
            badge: String(localized: "Recommended · Automatic language detection"),
            summary: String(localized: "Runs large local models (currently R2T2) with streaming live transcription, punctuation prediction and automatic detection of mixed languages.")
        ),
        EngineDescriptor(
            id: "model.sherpa", displayName: String(localized: "sherpa-onnx local engine"), kind: .model,
            badge: String(localized: "Lightweight · Low latency"),
            summary: String(localized: "Small streaming models with very low latency and little memory use; pick the one for your languages. Text appears as you speak, without punctuation; Dictation’s “Polish recognized text” can tidy it up.")
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
    /// sherpa-onnx streaming models on Hugging Face (`csukuangfj/…`), pinned to
    /// a revision. Sizes and hashes match the files' LFS metadata; `memoryMB` is
    /// the measured peak RSS (load + a short clip, Apple silicon); only the
    /// files the loader needs are listed (int8 where one exists). The first
    /// entry is the engine's default.
    private static let sherpaVariants: [ModelVariant] = [
        sherpaVariant(
            id: "sherpa-paraformer-bilingual-zh-en", name: "Paraformer Bilingual (zh-en)", quantization: "INT8", sizeMB: 227,
            repo: "sherpa-onnx-streaming-paraformer-bilingual-zh-en",
            revision: "8e40c43232a1c5c66c82111efc5820d3accca11b",
            files: [
                ("encoder.int8.onnx", 165_462_184, "81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a"),
                ("decoder.int8.onnx", 71_664_561, "f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f"),
                ("tokens.txt", 75_756, "59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6"),
            ],
            sourceLanguageCodes: ["zh-CN", "en-US"],
            memoryMB: 540,
            summary: String(localized: "Chinese (Mandarin and dialects) and English, about 240MB. Strong on accented and regional Chinese.")
        ),
        sherpaVariant(
            id: "sherpa-zipformer-bilingual-zh-en", name: "Zipformer Bilingual (zh-en)", quantization: "FP32", sizeMB: 341,
            repo: "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20",
            revision: "98590b7ed6443e77b714204da2757d75e1a642f4",
            files: [
                ("encoder-epoch-99-avg-1.onnx", 330_083_505, "709f0ed53a734b7942f170127e7547b566cb29c4afc5e67719f314c3d63ccb10"),
                ("decoder-epoch-99-avg-1.onnx", 13_876_452, "2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d"),
                ("joiner-epoch-99-avg-1.onnx", 12_833_618, "5f2adc585dd1bec6421c8bb8660d2a73fc8b9ceb24491ef51399ba2a2f0fc31b"),
                ("tokens.txt", 56_317, "a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3"),
            ],
            sourceLanguageCodes: ["zh-CN", "en-US"],
            memoryMB: 930,
            summary: String(localized: "Chinese and English with code-switching, real-time streaming. About 360MB; English comes out in capitals without punctuation, which Dictation’s “Polish recognized text” can clean up.")
        ),
        sherpaVariant(
            id: "sherpa-zipformer-zh-2025", name: "Zipformer Chinese (2025)", quantization: "INT8", sizeMB: 160,
            repo: "sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30",
            revision: "ad658fa0201659a09ea3c176129a191c77ecae8f",
            files: [
                ("encoder.int8.onnx", 161_141_793, "5ac51e27981bb4dab01bb9be4958453ba50c3b61c063ddda0eab23fd3671aa4f"),
                ("decoder.onnx", 5_165_083, "06522ad63cec0fdf6809f4e1db9bb4f7d710c34582e3b35db62ac60eccafac7e"),
                ("joiner.int8.onnx", 1_033_416, "b34584dc6f561089e1d747fedebb3765f2caa72c927ef54d7ca55e5ae40a814b"),
                ("tokens.txt", 20_628, "6193c7ea1c96d0d9a1e9652789b40d13a8a913b434a5451e93158f5a09fd6652"),
            ],
            sourceLanguageCodes: ["zh-CN"],
            memoryMB: 590,
            summary: String(localized: "Newer (2025) Chinese-only streaming model, about 170MB. Mandarin only: English words are not recognized.")
        ),
        sherpaVariant(
            id: "sherpa-zipformer-ctc-zh-2025", name: "Zipformer CTC Chinese (2025)", quantization: "INT8", sizeMB: 155,
            repo: "sherpa-onnx-streaming-zipformer-ctc-zh-int8-2025-06-30",
            revision: "f29132af655b91f258800df19c5b5d9b9281a5cd",
            files: [
                ("model.int8.onnx", 162_290_887, "24ffdc19ba9aaed5a6a9beaede1e087745217d82425cf4041bca0c696661801e"),
                ("tokens.txt", 20_628, "6193c7ea1c96d0d9a1e9652789b40d13a8a913b434a5451e93158f5a09fd6652"),
            ],
            sourceLanguageCodes: ["zh-CN"],
            memoryMB: 470,
            summary: String(localized: "CTC version of the 2025 Chinese model, about 160MB, a single model file. Mandarin only: English words are not recognized.")
        ),
        sherpaVariant(
            id: "sherpa-zipformer-small-ctc-zh", name: "Zipformer CTC Chinese (small)", quantization: "INT8", sizeMB: 26,
            repo: "sherpa-onnx-streaming-zipformer-small-ctc-zh-int8-2025-04-01",
            revision: "a5f60fe00dcfbaf68fcc1c6b5cf53061e144d6da",
            files: [
                ("model.int8.onnx", 26_342_340, "68c9c943840f7d9cf3e8a4970ba50f404feb5277f611fa82b7e72267786fa84a"),
                ("tokens.txt", 13_366, "6fed8c6c248516f38e7faa19404b57413e8ce259f1cbc1fa4aebc86eac32fdfd"),
            ],
            sourceLanguageCodes: ["zh-CN"],
            memoryMB: 170,
            summary: String(localized: "The smallest Chinese streaming model here, about 26MB, for low-end Macs. Mandarin only.")
        ),
        sherpaVariant(
            id: "sherpa-zipformer-multi-zh-hans", name: "Zipformer Chinese (multi-dataset)", quantization: "INT8", sizeMB: 73,
            repo: "sherpa-onnx-streaming-zipformer-multi-zh-hans-int8-2023-12-13",
            revision: "115a233a980d0a38536c8320e5c54f2fd2aa5416",
            files: [
                ("encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx", 70_104_213, "d6380c74c75aaf37a739061a9197440fc5ca3f73ee339e588268eff2e9d3bf84"),
                ("decoder-epoch-20-avg-1-chunk-16-left-128.onnx", 5_165_084, "93f0df50c2834fe225bbabd664d59fc2488b15736fbc6acaabddec3188dea9b4"),
                ("joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx", 1_033_417, "7fa442b8b35b1ab217dbceadb57a7da5388ee445c6c722eab576a57071e0dcea"),
                ("tokens.txt", 18_626, "6722bd1585f46f84456b29c3550a343a3cc375b971645773c02ed8e0b4e2405c"),
            ],
            sourceLanguageCodes: ["zh-CN"],
            memoryMB: 350,
            summary: String(localized: "Chinese streaming model trained on several datasets, about 76MB. Mandarin only.")
        ),
        sherpaVariant(
            id: "sherpa-zipformer-zh-14m", name: "Zipformer Chinese (14M)", quantization: "INT8", sizeMB: 25,
            repo: "sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23",
            revision: "204ad334e2e683fd295359930cc16fc0432a23ac",
            files: [
                ("encoder-epoch-99-avg-1.int8.onnx", 21_621_684, "1c556ea57cec304e55ec4b72e52c1cc098bb01476ed7d90f3de939fe126487b1"),
                ("decoder-epoch-99-avg-1.int8.onnx", 1_888_682, "22f123bb8cba9b38974b3df18a3f45e7081f4985ebb2e075d9f21f618c468bbf"),
                ("joiner-epoch-99-avg-1.int8.onnx", 1_795_562, "a7cf9d82757bdcf786059454495a9ca95e4bd7347f72473fc08d794475c36169"),
                ("tokens.txt", 48_697, "8b294db9045d6e5f94647f4c1eec1af4da143a75053c399611444b378ff966ac"),
            ],
            sourceLanguageCodes: ["zh-CN"],
            memoryMB: 140,
            summary: String(localized: "Ultra-light 14M-parameter Chinese model, about 25MB, lowest memory use. Mandarin only.")
        ),
        sherpaVariant(
            id: "sherpa-paraformer-trilingual-zh-yue-en", name: "Paraformer Trilingual (zh-yue-en)", quantization: "INT8", sizeMB: 228,
            repo: "sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en",
            revision: "86931b152d37c908528b44d30b431c24a19770da",
            files: [
                ("encoder.int8.onnx", 166_362_800, "6047a644b41b236d9d8e89e3b94ef39d1b7037daab028131b722ca52e10b0357"),
                ("decoder.int8.onnx", 72_062_549, "545427acf508452b7d89969be082c8128c681e3432ff43aef09f6159f4b61a7e"),
                ("tokens.txt", 81_289, "45b31504211675dd52aa88f998a6f6161703a2834e86760c1cda645a22538085"),
            ],
            sourceLanguageCodes: ["zh-CN", "yue-CN", "en-US"],
            memoryMB: 550,
            summary: String(localized: "Mandarin, Cantonese and English, about 240MB. The only streaming model here that recognizes Cantonese.")
        ),
        sherpaVariant(
            id: "sherpa-zipformer-multilingual-8", name: "Zipformer Multilingual (8 languages)", quantization: "INT8", sizeMB: 324,
            repo: "sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10",
            revision: "c6726c1147387ad2a11148b33973135d92a55e6c",
            files: [
                ("encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx", 296_583_597, "f9001ed7a9e46d0294438c1a30cd7c72d1cc4bdd4e7880edbcda36f67081e32e"),
                ("decoder-epoch-75-avg-11-chunk-16-left-128.onnx", 33_837_085, "7ebc63f34b21c8efb4a41a5a2eee7fe1448829ce0230ecc5369e67fc14d90d48"),
                ("joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx", 8_257_421, "db88e3172323551abaa99b91b18fb422a27ea4a834fd0db10389f9478816f917"),
                ("tokens.txt", 195_244, "784f24950f6bcce1b0021035632dd60fd4617ecd8ca0581ab57d7b39d77ba5ab"),
            ],
            sourceLanguageCodes: ["zh-CN", "en-US", "ja-JP", "ru-RU", "ar-SA", "vi-VN", "th-TH"],
            memoryMB: 800,
            summary: String(localized: "Arabic, English, Indonesian, Japanese, Russian, Thai, Vietnamese and Chinese in one model, about 340MB.")
        ),
    ]

    private static func sherpaVariant(
        id: String, name: String, quantization: String, sizeMB: Int, repo: String, revision: String,
        files: [(name: String, size: Int64, sha256: String)], sourceLanguageCodes: [String], memoryMB: Int,
        summary: String
    ) -> ModelVariant {
        let base = "https://huggingface.co/csukuangfj/\(repo)/resolve/\(revision)"
        return ModelVariant(
            id: id, engineID: "model.sherpa", displayName: name, quantization: quantization,
            approximateSizeMB: sizeMB, summary: summary, recommendedMemoryGB: 1,
            files: files.map {
                ModelFile(name: $0.name, url: URL(string: "\(base)/\($0.name)")!, sizeBytes: $0.size, sha256: $0.sha256)
            },
            sourceLanguageCodes: sourceLanguageCodes, memoryMB: memoryMB
        )
    }

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
    ] + sherpaVariants + [
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

    /// The variant `selectedID` names for `engineID`, or the engine's first
    /// catalog entry when unset or stale — the same fallback the session uses.
    public static func resolvedVariant(forEngineID engineID: String, selectedID: String?) -> ModelVariant? {
        let variants = modelVariants(forEngineID: engineID)
        return variants.first { $0.id == selectedID } ?? variants.first
    }

    /// Whether `code` can't be the recognizer's source with this engine (and,
    /// for a local engine, the selected `variantID`). `nil` is "auto":
    /// unsupported by the system engine (it needs a fixed language), fine for
    /// a local model. A local variant that lists `sourceLanguageCodes` (the
    /// sherpa models cover only a few languages) rules out everything else,
    /// custom locales included; the system engine leaves codes outside
    /// `LanguageCatalog` to the system to accept or reject.
    public static func isUnsupportedSource(_ code: String?, engineID: String, variantID: String? = nil) -> Bool {
        if transcriptionEngines.first(where: { $0.id == engineID })?.kind == .system {
            guard let code else { return true }
            return LanguageCatalog.common.first { $0.code == code }?.supportsSystemASRSource == false
        }
        guard let code,
              let allowed = resolvedVariant(forEngineID: engineID, selectedID: variantID)?.sourceLanguageCodes
        else { return false }
        return !allowed.contains(code)
    }

    /// The `LanguageCatalog` entries this engine/variant can recognize as a source.
    public static func sourceLanguageOptions(forEngineID engineID: String, variantID: String? = nil) -> [LanguageOption] {
        LanguageCatalog.common.filter { !isUnsupportedSource($0.code, engineID: engineID, variantID: variantID) }
    }

    /// Whether the engine's models list their own recognizable languages, as
    /// opposed to following the catalog (local R2T2) or the system.
    public static func hasRestrictedSources(engineID: String) -> Bool {
        modelVariants(forEngineID: engineID).contains { $0.sourceLanguageCodes != nil }
    }

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
