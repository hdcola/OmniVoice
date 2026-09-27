import Foundation

/// Placeholder for the R2T2 in-process model ASR engine.
///
/// The real implementation is already validated in `../mac-poc-hybrid`'s
/// `Inference/InProcessTranscriber.swift` (streaming LSP ASR via audio.cpp's
/// C ABI) — porting it here means:
/// 1. Adding `CAudioCpp`/`CLlamaCpp`-style C target shims and the
///    `third_party/audio.cpp` linker flags to `Package.swift`, exactly as
///    `mac-poc-hybrid/Package.swift` does (gitignored checkout, built
///    out-of-band with `-DAUDIOCPP_BUILD_C_API=ON`).
/// 2. Wrapping `InProcessTranscriber`'s `onDelta`/`onFinalTail` callbacks as
///    `.appended`/`.segmentClosed(finalAppend:)` `TranscriptionEvent`s — this
///    is a closer fit to the delta-shaped half of `TranscriptionEvent` than
///    `SystemTranscriptionProvider`'s revised/final shape, since R2T2's
///    output is already incremental/committed.
/// 3. Wiring `notifyUtteranceBoundary()` to `InProcessTranscriber.rotateStream()`
///    (this provider's VAD-driven row-closing hook — `RecordingSession` will
///    call this after `UtteranceSegmenter` fires).
/// 4. Threading `ProviderCatalog.modelVariants(forEngineID:)`'s resolved
///    weights path through `TranscriptionConfig.modelPath` into
///    `InProcessTranscriber.resolveModelPath()`'s override point.
///
/// Deferred until the system-engine path and app shell are in place — see
/// this repo's `Package.swift` doc comment.
public final class ModelTranscriptionProvider: TranscriptionProvider {
    public var onEvent: ((TranscriptionEvent) -> Void)?

    public init() {}

    public func loadModel() async throws {
        throw ProviderError.notImplemented("R2T2 模型 ASR 引擎尚未接入，见 ModelTranscriptionProvider 的类型注释")
    }

    public func unload() {}

    public func start(config: TranscriptionConfig) async throws {
        throw ProviderError.notImplemented("R2T2 模型 ASR 引擎尚未接入")
    }

    public func push(samples: [Float]) {}

    public func stop() async {}
}
