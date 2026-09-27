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

    public init(id: String, displayName: String, kind: EngineKind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
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
    /// nil until a real weights host is chosen (see AGENTS discussion:
    /// model distribution is "download on first use", host still TBD) —
    /// a variant with no `downloadURL` is listed but not selectable yet.
    public let downloadURL: URL?
    public let sha256: String?

    public init(
        id: String, engineID: String, displayName: String, quantization: String,
        approximateSizeMB: Int, downloadURL: URL? = nil, sha256: String? = nil
    ) {
        self.id = id
        self.engineID = engineID
        self.displayName = displayName
        self.quantization = quantization
        self.approximateSizeMB = approximateSizeMB
        self.downloadURL = downloadURL
        self.sha256 = sha256
    }
}

/// The static, built-in list of engines/model variants this build ships
/// knowing about. Intentionally not user-editable (unlike a downloaded
/// model's local file, which does live in user-writable storage) — adding a
/// new community model audio.cpp supports means adding an entry here, not a
/// schema change.
public enum ProviderCatalog {
    public static let transcriptionEngines: [EngineDescriptor] = [
        EngineDescriptor(id: "system.speech", displayName: "系统自带 (Speech)", kind: .system),
        EngineDescriptor(id: "model.r2t2", displayName: "R2T2 模型", kind: .model),
    ]

    public static let translationEngines: [EngineDescriptor] = [
        EngineDescriptor(id: "system.translation", displayName: "系统自带 (Translation)", kind: .system),
        EngineDescriptor(id: "model.t3po", displayName: "T3PO 模型", kind: .model),
    ]

    /// Model variants are keyed by `engineID` so a settings UI can filter
    /// "what sizes/quantizations exist for the currently-selected model
    /// engine" without switching on the engine identity itself.
    public static let modelVariants: [ModelVariant] = [
        ModelVariant(
            id: "r2t2-q8_0", engineID: "model.r2t2", displayName: "R2T2 (Q8_0)",
            quantization: "Q8_0", approximateSizeMB: 1500
        ),
        ModelVariant(
            id: "t3po-q5_k_m", engineID: "model.t3po", displayName: "T3PO (Q5_K_M)",
            quantization: "Q5_K_M", approximateSizeMB: 1100
        ),
    ]

    public static func modelVariants(forEngineID engineID: String) -> [ModelVariant] {
        modelVariants.filter { $0.engineID == engineID }
    }
}
