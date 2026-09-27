import CAudioCpp
import Foundation

enum TranscriberError: LocalizedError {
    case modelMissing(String)
    case status(audiocpp_status, String)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .modelMissing(let path):
            return "找不到模型权重: \(path)"
        case .status(let status, let context):
            let name = String(cString: audiocpp_status_string(status))
            let detail = String(cString: audiocpp_last_error())
            return "\(context): \(name) — \(detail)"
        case .notLoaded:
            return "模型尚未加载"
        }
    }
}

/// Recognition language options R2T2 itself understands — not an exhaustive
/// list of what the underlying Qwen3-ASR-based model supports (R2T2's own
/// docs don't enumerate one), just what `ModelTranscriptionProvider` maps
/// `TranscriptionConfig.languageCode` onto. `.auto` passes no request
/// language at all, leaving language detection to the model — the documented
/// default (docs/community_models/r2t2.md's `language` request option:
/// "empty ... `Auto` keeps detection").
enum RecognitionLanguage {
    case auto, chinese, english, japanese, korean

    /// The literal string R2T2's `language` request option / `--language`
    /// CLI flag expects, or nil to force nothing (auto-detect).
    var requestValue: String? {
        switch self {
        case .auto: return nil
        case .chinese: return "Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        }
    }
}

/// Session-scope knobs for confucius4_r2t2's streaming LSP state machine
/// (docs/community_models/r2t2.md "Session options"), applied at session
/// creation. There is no API to un-commit or rewrite text already reported
/// via `onDelta` — R2T2's LSP design is deliberately append-only ("Committed
/// text is never revised") — so these only trade latency against accuracy
/// for *not-yet-committed* audio, not a way to revise committed output.
/// Values copied unchanged from `mac-poc-hybrid`'s validated defaults.
struct StreamingTuning {
    /// `confucius4_r2t2.chunk_size_ms`: streaming decode chunk, 80-2000ms.
    /// Smaller = lower latency, more re-decoding, more error-prone commits.
    var chunkSizeMs: Int = 320
    /// `confucius4_r2t2.unfixed_chunk_num`: leading chunks decoded without a
    /// stable-prefix prompt.
    var unfixedChunkNum: Int = 2
    /// `confucius4_r2t2.unfixed_token_num`: tokens held back from the
    /// accumulated text before it's used as the next prefix prompt.
    var unfixedTokenNum: Int = 5
    /// `confucius4_r2t2.rollback_punctuation`: keep trailing text uncommitted
    /// when it already ends with punctuation, instead of rolling back tokens.
    var rollbackPunctuation: Bool = false
    /// Unlike the knobs above (baked into the session at creation), this is
    /// a **request** option (`audiocpp_request_set_text_language`), applied
    /// fresh on every `audiocpp_stream_start` call — which happens on a full
    /// Start *and* on every VAD-triggered `rotateStream()`. So changing it
    /// mid-run takes effect at the next utterance boundary, not only on a
    /// full Stop/Start.
    var recognitionLanguage: RecognitionLanguage = .auto
}

/// Runs Confucius4-R2T2 streaming ASR **in-process** via audio.cpp's C ABI
/// (`third_party/audio.cpp/include/audiocpp.h`). The registry/model are
/// loaded once per instance (`loadModel()`) and released by `unload()`; the
/// **session** is recreated for every top-level run (`startStream()` after
/// `finishStream()` freed the previous one) but reused across
/// VAD-triggered utterance boundaries within one run (`rotateStream()`,
/// which only restarts the *stream*, not the session) — reusing a session
/// across `audiocpp_stream_finish` + a later `audiocpp_stream_start` left
/// later runs producing no transcript at all (observed after Stop → Start,
/// in `mac-poc-hybrid`), so a finished session is not assumed restartable;
/// only recreating it is.
///
/// `audiocpp_result_text` on a streaming event already returns the
/// *incremental* committed delta, not the full accumulated transcript — the
/// LSP bookkeeping described in docs/community_models/r2t2.md happens inside
/// the session itself, so callers just append what they're given.
///
/// **Thread-safety**: audiocpp.h documents a single handle as not
/// individually thread-safe. `push(samples:)` is called from
/// `AudioMixer`'s own capture queue, while `rotateStream()`/`finishStream()`
/// are called from `RecordingSession` (main actor) — two different threads
/// that can both reach the same `session` handle. In `mac-poc-hybrid`, Stop
/// racing with an in-flight mic buffer (Stop calls `finishStream()` right
/// after asking capture to stop, but a buffer already queued on its
/// delegate callback can still land after that) crashed inside
/// `ggml_backend_synchronize` because of exactly this — two threads
/// touching one session concurrently. Every entry point below therefore
/// funnels through one serial `queue`, and the `_locked` helpers assume
/// they're already running on it (so `rotateStream` can call
/// `_startStreamLocked` internally without a nested `queue.sync` deadlock).
/// `@unchecked Sendable`: honest given this class's own documented
/// thread-safety contract above (every mutable field is only ever touched
/// from inside `queue`, synchronously or, since `loadModel(modelPath:)`,
/// asynchronously) — needed so `loadModel(modelPath:)`'s `queue.async`
/// closure (a `@Sendable` closure, unlike the `queue.sync` ones elsewhere in
/// this file) can capture `self` without a compiler warning.
final class InProcessTranscriber: @unchecked Sendable {
    var onDelta: ((String) -> Void)?
    var onFinalTail: ((String) -> Void)?
    /// Read by `startStream()` when it creates a session — i.e. changes only
    /// take effect on the next full Start, not on a mid-run VAD rotation
    /// (`rotateStream()` reuses the existing session as-is).
    var tuning = StreamingTuning()

    private let queue = DispatchQueue(label: "org.omnivoice.inprocess.audiocpp")

    private var registry: OpaquePointer?
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private var streamSampleOffset: Int64 = 0
    /// Concatenation of every delta reported for the *current* utterance —
    /// needed because, unlike the per-push deltas, `audiocpp_stream_finish`'s
    /// result carries the utterance's complete transcript rather than just
    /// its uncommitted tail. Diffing against this is what recovers the true
    /// tail to report.
    private var committedThisUtterance = ""

    /// Resolved weights path — `modelPath` overrides everything (the caller,
    /// `ModelTranscriptionProvider`, threads `TranscriptionConfig.modelPath`
    /// through here); otherwise falls back to the `R2T2_MODEL_PATH` env var
    /// (matching `mac-poc-hybrid`'s override), then this repo's own
    /// `models/` directory convention.
    static func resolveModelPath(override modelPath: URL?) -> String {
        if let modelPath { return modelPath.path }
        if let override = ProcessInfo.processInfo.environment["R2T2_MODEL_PATH"] {
            return override
        }
        // .../Sources/OmniVoiceCore/Inference/InProcessTranscriber.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Inference
            .deletingLastPathComponent() // OmniVoiceCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("models/Confucius4-R2T2-GGUF/r2t2-q8_0.gguf").path
    }

    private static func resolveBackend() -> String {
        ProcessInfo.processInfo.environment["R2T2_BACKEND"] ?? "metal"
    }

    /// Loads the registry and model. Call once before the first
    /// `startStream()`; safe to call again after `unload()`. Does not create
    /// a session — `startStream()` creates one on demand.
    ///
    /// Dispatches onto `queue` **asynchronously** (`queue.async`, not the
    /// `queue.sync` every other entry point here uses) — reading a
    /// multi-hundred-MB weights file plus backend init is the one operation
    /// on this type that can take real seconds, and every caller of this is
    /// `@MainActor`-isolated (`ModelTranscriptionProvider`). A `queue.sync`
    /// call from the main actor blocks that actor's executor for the whole
    /// load — the app's entire UI (including whatever "loading…" spinner is
    /// meant to show progress) would freeze solid for that duration, not
    /// just look busy. Suspending via a continuation instead lets the main
    /// actor keep servicing SwiftUI/AppKit while this runs on `queue`.
    func loadModel(modelPath: URL? = nil) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.loadModelLocked(modelPath: modelPath)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadModelLocked(modelPath: URL?) throws {
        // A defensive guard, not the expected path — every caller already
        // pairs `loadModel()` with `unload()` before ever calling it again
        // (see `RecordingSession`'s `isModelLoaded` bookkeeping), but
        // without this, an unexpected duplicate call would overwrite
        // `registry`/`model` with fresh handles while leaking the old ones
        // — `unload()` never gets to free them, since it only ever reads
        // whatever's currently in these two properties.
        guard model == nil else { return }
        let path = Self.resolveModelPath(override: modelPath)
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriberError.modelMissing(path)
        }

        var reg: OpaquePointer?
        try check(audiocpp_registry_create(nil, &reg), "创建 registry 失败")
        registry = reg

        var mdl: OpaquePointer?
        try "confucius4_r2t2".withCString { familyPtr -> Void in
            var config = audiocpp_model_config(
                family_hint: familyPtr,
                config_id: nil,
                weight_id: nil,
                model_spec_override: nil
            )
            try check(audiocpp_model_load(reg, path, &config, nil, &mdl), "加载模型失败")
        }
        model = mdl
    }

    /// Starts a fresh utterance stream. Creates a new session first if the
    /// previous run's was freed by `finishStream()` — cheap relative to
    /// `loadModel()` (no weights to re-read), and avoids reusing a session
    /// that already went through a full `audiocpp_stream_finish`.
    func startStream() throws {
        try queue.sync { try startStreamLocked() }
    }

    private func startStreamLocked() throws {
        if session == nil {
            guard let model else { throw TranscriberError.notLoaded }
            let sessionOptions = Self.makeSessionOptions(tuning)
            defer { audiocpp_options_free(sessionOptions) }
            var sess: OpaquePointer?
            try Self.resolveBackend().withCString { backendPtr -> Void in
                var backend = audiocpp_backend_config(backend: backendPtr, device: 0, threads: 4)
                try check(
                    audiocpp_session_create(model, "asr", "streaming", &backend, sessionOptions, &sess),
                    "创建流式会话失败"
                )
            }
            session = sess
        }
        guard let session else { throw TranscriberError.notLoaded }
        streamSampleOffset = 0
        committedThisUtterance = ""

        guard let requestLanguage = tuning.recognitionLanguage.requestValue else {
            try check(audiocpp_stream_start(session, nil), "启动流失败")
            return
        }
        let request = audiocpp_request_create()
        defer { audiocpp_request_free(request) }
        try requestLanguage.withCString { languagePtr -> Void in
            try check(audiocpp_request_set_text_language(request, languagePtr), "设置识别语言失败")
        }
        try check(audiocpp_stream_start(session, request), "启动流失败")
    }

    /// Feeds one buffer of mono 16 kHz Float32 PCM in -1...1 range (the
    /// format `AudioMixer` emits). Any committed delta the session emits for
    /// this push is reported via `onDelta`. Safe to call after
    /// `finishStream()`/`unload()` freed the session (a no-op) — mic buffers
    /// already queued when Stop is pressed can still land here.
    func push(samples: [Float]) {
        queue.sync { pushLocked(samples: samples) }
    }

    private func pushLocked(samples: [Float]) {
        guard let session, !samples.isEmpty else { return }
        var event: OpaquePointer?
        let status = samples.withUnsafeBufferPointer { buffer in
            audiocpp_stream_push(
                session, buffer.baseAddress, buffer.count, 16000, 1, streamSampleOffset, &event
            )
        }
        streamSampleOffset += Int64(samples.count)
        guard status == AUDIOCPP_OK else { return }
        guard let event else { return }
        defer { audiocpp_event_free(event) }
        if let delta = Self.text(from: audiocpp_event_as_result(event)), !delta.isEmpty {
            committedThisUtterance += delta
            onDelta?(delta)
        }
    }

    /// Ends the current utterance's stream and reports its uncommitted tail
    /// via `onFinalTail`, then immediately starts a fresh stream so mic audio
    /// keeps having somewhere to go — this is `notifyUtteranceBoundary()`'s
    /// hook (a VAD-triggered pause), not the end of the whole recording.
    func rotateStream() {
        queue.sync {
            if let tail = finishLocked() {
                onFinalTail?(tail)
            }
            try? startStreamLocked()
        }
    }

    /// Ends the current stream and reports its final tail, then frees the
    /// session — used when stopping for good, so a later `startStream()`
    /// gets a fresh session instead of restarting a finished one.
    func finishStream() {
        queue.sync {
            if let tail = finishLocked() {
                onFinalTail?(tail)
            }
            audiocpp_session_free(session)
            session = nil
        }
    }

    /// Ends the stream and returns just the uncommitted tail (the suffix of
    /// the finish result's full transcript beyond what deltas already
    /// reported), or nil if there's nothing new.
    ///
    /// **Requires the patched audio.cpp**: on an unpatched build,
    /// `audiocpp_stream_finish` SIGSEGVs the whole process whenever the
    /// session's decoded text is empty at finish time (a trailing pause, or
    /// silence) — a null dereference in audio.cpp's own
    /// `R2T2ASRSession::build_stream_prefix(final_flush:)`, nothing this file
    /// can guard against from the C API surface. Fixed by
    /// `Patches/audio.cpp/0001-r2t2-fix-null-deref-on-empty-final-flush.patch`,
    /// applied as part of `Docs/MODEL_ENGINE_SETUP.md`; see
    /// `Docs/PROGRESS.md`'s Known gaps section for the root cause.
    private func finishLocked() -> String? {
        guard let session else { return nil }
        var result: OpaquePointer?
        let status = audiocpp_stream_finish(session, &result)
        guard status == AUDIOCPP_OK, let result else { return nil }
        defer { audiocpp_result_free(result) }
        guard let fullText = Self.text(from: result), !fullText.isEmpty else { return nil }
        let tail = fullText.hasPrefix(committedThisUtterance)
            ? String(fullText.dropFirst(committedThisUtterance.count))
            : fullText
        return tail.isEmpty ? nil : tail
    }

    /// Releases the session/model/registry. Order doesn't matter — handles
    /// keep their parents alive internally (see audiocpp.h's lifetime note).
    func unload() {
        queue.sync {
            audiocpp_session_free(session)
            audiocpp_model_free(model)
            audiocpp_registry_free(registry)
            session = nil
            model = nil
            registry = nil
        }
    }

    /// A safety net, not the normal teardown path — every caller in this
    /// codebase already unloads explicitly (`RecordingSession.unloadModelsBeforeQuit()`/
    /// `discardLoadedModelsIfStale()`), but if some future caller ever drops
    /// or replaces an instance without going through that, this is what
    /// stops the underlying registry/model/session C handles from leaking
    /// silently — and, for the Metal-backed ones, risking the ggml
    /// exit-time assert `unload()`'s doc describes. No `queue.sync` here:
    /// by the time `deinit` runs, no other reference (and so no concurrent
    /// caller) can exist, so the lock `unload()` needs elsewhere isn't
    /// needed for this one guaranteed-exclusive access.
    deinit {
        audiocpp_session_free(session)
        audiocpp_model_free(model)
        audiocpp_registry_free(registry)
    }

    private static func makeSessionOptions(_ tuning: StreamingTuning) -> OpaquePointer? {
        guard let options = audiocpp_options_create() else { return nil }
        audiocpp_options_set(options, "confucius4_r2t2.chunk_size_ms", String(tuning.chunkSizeMs))
        audiocpp_options_set(options, "confucius4_r2t2.unfixed_chunk_num", String(tuning.unfixedChunkNum))
        audiocpp_options_set(options, "confucius4_r2t2.unfixed_token_num", String(tuning.unfixedTokenNum))
        audiocpp_options_set(
            options, "confucius4_r2t2.rollback_punctuation", tuning.rollbackPunctuation ? "true" : "false"
        )
        return options
    }

    private static func text(from result: OpaquePointer?) -> String? {
        guard let result else { return nil }
        var outText: UnsafePointer<CChar>?
        var outLanguage: UnsafePointer<CChar>?
        let status = audiocpp_result_text(result, &outText, &outLanguage)
        guard status == AUDIOCPP_OK, let outText else { return nil }
        return String(cString: outText)
    }

    private func check(_ status: audiocpp_status, _ context: String) throws {
        guard status == AUDIOCPP_OK else { throw TranscriberError.status(status, context) }
    }
}
