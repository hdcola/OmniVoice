import Foundation

/// Placeholder for the T3PO in-process model translation engine.
///
/// The real implementation is already validated in `../mac-poc-hybrid`'s
/// `Inference/InProcessTranslator.swift` (streaming WAIT/TRANS policy via
/// llama.cpp's C ABI) — its `feed(sourceDelta:)`/`flush()` shape already
/// matches `TranslationProvider` almost exactly (this protocol was modeled
/// on it), so porting it is mostly:
/// 1. Adding the `third_party/llama.cpp` C target shim + linker flags to
///    `Package.swift`, same recipe as `mac-poc-hybrid/Package.swift`.
/// 2. Renaming `onPartialTranslation`/`onPreviewTranslation`/`onFlushBoundary`
///    to this protocol's `onCommit`/`onPreview`/`onFlushBoundary`.
/// 3. Threading `ProviderCatalog.modelVariants(forEngineID:)`'s resolved
///    weights path through `TranslationConfig.modelPath`.
///
/// Deferred until the system-engine path and app shell are in place — see
/// this repo's `Package.swift` doc comment.
public final class ModelTranslationProvider: TranslationProvider {
    public var onCommit: ((String) -> Void)?
    public var onPreview: ((String) -> Void)?
    public var onFlushBoundary: (() -> Void)?

    public init() {}

    public func loadModel() async throws {
        throw ProviderError.notImplemented("T3PO 模型翻译引擎尚未接入，见 ModelTranslationProvider 的类型注释")
    }

    public func unload() {}

    public func start(config: TranslationConfig) async throws {
        throw ProviderError.notImplemented("T3PO 模型翻译引擎尚未接入")
    }

    public func feed(_ text: String) {}
    public func flush() {}
    public func stop() async {}
}
