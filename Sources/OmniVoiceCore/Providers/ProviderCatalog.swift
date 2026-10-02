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

    public init(
        id: String, engineID: String, displayName: String, quantization: String,
        approximateSizeMB: Int, downloadURL: URL? = nil, sha256: String? = nil,
        summary: String = "", recommendedMemoryGB: Int = 0
    ) {
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
            id: "system.speech", displayName: "系统语音识别", kind: .system,
            badge: "系统原生 · 零内存占用",
            summary: "macOS 系统级语音识别，即开即用，无需额外下载。"
        ),
        EngineDescriptor(
            id: "model.r2t2", displayName: "R2T2 离线大模型", kind: .model,
            badge: "推荐 · 支持自动语种检测",
            summary: "支持流式实时转录、标点预测与混合语种自动检测。"
        ),
    ]

    public static let translationEngines: [EngineDescriptor] = [
        EngineDescriptor(
            id: "system.translation", displayName: "系统翻译", kind: .system,
            badge: "系统原生 · 整句翻译",
            summary: "macOS 内置翻译，按句子标点翻译，不支持实时打字机预览。"
        ),
        EngineDescriptor(
            id: "model.t3po", displayName: "T3PO 离线大模型", kind: .model,
            badge: "推荐 · 支持实时预览",
            summary: "高性能双语翻译大模型，支持打字机式逐字流式预览与自动纠错。"
        ),
        EngineDescriptor(
            id: "model.hymt15", displayName: "HY-MT1.5 1.8B 模型", kind: .model,
            badge: "轻量级 · 低内存",
            summary: "腾讯混元轻量翻译模型，内存开销小，整句翻译（无流式预览）。"
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
            summary: "针对中英文混合演讲、专业会议优化，支持多语种自动判别与断句标点补全。",
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
            summary: "社区量化版（非官方发布）：体积约为 Q8_0 的一半，运行时峰值内存约 1.8GB，解码更快，适合内存紧张的设备；精度略低于 Q8_0。",
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
            summary: "未量化的完整精度版本，质量最高；运行时峰值内存约 4.7GB（Q8_0 约 3.1GB），适合内存充裕的设备。",
            recommendedMemoryGB: 5
        ),
        ModelVariant(
            id: "t3po-q5_k_m", engineID: "model.t3po", displayName: "T3PO (Q5_K_M)",
            quantization: "Q5_K_M", approximateSizeMB: 10021,
            downloadURL: URL(
                string:
                    "https://huggingface.co/netease-youdao/Confucius4-T3PO-GGUF/resolve/main/Confucius4-T3PO-Q5_K_M.gguf"
            )!,
            sha256: "019b162a8fdff3edb1e2469445043fc2ebb0de0fbda9ca6454bc86b5898fac35",
            summary: "流式 WAIT/TRANS 实时逐字预览，中/粤/英/日/韩之间的翻译效果最佳，建议 16GB+ 统一内存设备使用。",
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
            summary: "一次性整句翻译，无实时打字机预览，内存开销极小，适合 8GB 内存设备。",
            recommendedMemoryGB: 2
        ),
        ModelVariant(
            id: "hymt15-1.8b-q8_0", engineID: "model.hymt15", displayName: "HY-MT1.5 1.8B (Q8_0)",
            quantization: "Q8_0", approximateSizeMB: 1820,
            downloadURL: URL(
                string: "https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/resolve/main/HY-MT1.5-1.8B-Q8_0.gguf"
            )!,
            sha256: "6789b06d0902f2f5312c0e1703d56ccbddfcfb6c653d22519b7c720f7db9a98e",
            summary: "一次性整句翻译，无实时打字机预览，比 Q4_K_M 略高的精度，内存开销依然很小。",
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
            displayName: "方案 A：标准实时双语字幕（推荐）",
            summary: "R2T2 语音识别 + T3PO 实时流式翻译。自动检测语种、逐字打字机流式显示、完全离线私密。建议 16GB+ 统一内存 Mac。",
            variantIDs: ["r2t2-q8_0", "t3po-q5_k_m"],
            recommendedMemoryGB: 14
        ),
        ModelBundle(
            id: "bundle.lightweight",
            displayName: "方案 B：轻量低内存方案",
            summary: "R2T2 语音识别 + HY-MT1.5 翻译。占用内存极小，整句翻译输出。适合 8GB 内存设备。",
            variantIDs: ["r2t2-q8_0", "hymt15-1.8b-q4_k_m"],
            recommendedMemoryGB: 5
        ),
    ]

    public static func modelVariants(forEngineID engineID: String) -> [ModelVariant] {
        modelVariants.filter { $0.engineID == engineID }
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
