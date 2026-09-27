import Foundation

/// One normalized event out of a `TranscriptionProvider`, regardless of
/// whether the underlying engine reports incremental append-only deltas
/// (e.g. R2T2's streaming LSP output) or full-replace volatile hypotheses
/// (e.g. `SpeechTranscriber`'s volatile/final results) — see
/// `docs/provider-design.md` for the reasoning behind collapsing two very
/// different engine shapes into one three-case event instead of leaking
/// engine-specific callback shapes to `RecordingSession`.
///
/// Contract every `TranscriptionProvider` implementation must uphold:
/// - `.appended`'s text is new content, safe to both display-append and feed
///   straight to a `TranslationProvider`.
/// - `.revised`'s text is a full replacement of the current segment's
///   tentative/not-yet-final text — display only, never fed to translation
///   (it may still be rewritten before the segment closes).
/// - `.segmentClosed`'s `finalAppend` is whatever text for this segment has
///   **not** already been delivered via a prior `.appended` — i.e. the tail
///   for an append-style engine, or the entire final text for a
///   replace-style engine that never emitted `.appended` at all. Consumers
///   always do the same thing with it: append + feed + flush, then move to
///   the next segment.
public enum TranscriptionEvent: Sendable {
    case appended(String)
    case revised(String)
    case segmentClosed(finalAppend: String)
}

/// Session-scope configuration handed to `TranscriptionProvider.start(config:)`.
/// Per-provider tuning knobs (e.g. R2T2's chunk size / unfixed-token knobs)
/// don't belong here — they're provider-specific and passed through whatever
/// concrete config type that provider's initializer/setup accepts instead.
public struct TranscriptionConfig: Sendable {
    /// BCP-47-ish language tag, or nil for "let the engine auto-detect" —
    /// not every provider supports auto-detect (`SpeechTranscriber` doesn't;
    /// see `SystemTranscriptionProvider`).
    public var languageCode: String?
    /// Resolved path to a model weights file, only meaningful for `.model`
    /// providers — ignored by `.system` providers.
    public var modelPath: URL?

    public init(languageCode: String? = nil, modelPath: URL? = nil) {
        self.languageCode = languageCode
        self.modelPath = modelPath
    }
}

public enum ProviderError: LocalizedError {
    case notImplemented(String)
    case notLoaded
    case localeNotSupported

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let detail): return "尚未实现: \(detail)"
        case .notLoaded: return "模型尚未加载"
        case .localeNotSupported: return "所选语言在本机不受支持"
        }
    }
}

/// Drives speech recognition for one recording. One instance is started
/// fresh per recording (`RecordingSession.start()`), same rule the POCs
/// established — no engine here is expected to support a hot-swap mid-run.
///
/// `@MainActor`-isolated **except** `push(samples:)`/`notifyUtteranceBoundary()`:
/// `RecordingSession` (also `@MainActor`) is the only caller of every other
/// member, so those stay on the same isolation domain as their one caller.
/// `push`/`notifyUtteranceBoundary` are different — they're the hot audio
/// path, called directly from `AudioMixer`'s/`MicrophoneCapture`'s own
/// background capture queues (never hopped to the main actor first, both for
/// latency and because hopping per-buffer would mean the audio thread
/// blocking on the main run loop), so they're `nonisolated` here. A
/// conforming type is responsible for its own thread-safety on whatever
/// mutable state those two touch — see `SystemTranscriptionProvider`'s
/// `audioQueue` for how it does that.
@MainActor
public protocol TranscriptionProvider: AnyObject {
    /// Fires for every recognized event — see `TranscriptionEvent`'s doc.
    /// Set once, before `start(config:)`.
    var onEvent: ((TranscriptionEvent) -> Void)? { get set }

    /// Loads whatever backend/model this provider needs. A no-op for system
    /// providers. Safe to call again after `unload()`.
    func loadModel() async throws

    /// Releases the backend/model. Safe to call whether or not a model was
    /// ever loaded.
    func unload()

    /// Starts a fresh recognition session/stream.
    func start(config: TranscriptionConfig) async throws

    /// Feeds one buffer of mono 16 kHz Float32 PCM in -1...1 range — the
    /// format `AudioMixer` emits (see `Audio/AudioMixer.swift`). Called from
    /// a background audio queue, not the main actor — see this protocol's
    /// doc.
    nonisolated func push(samples: [Float])

    /// Hints that a voice-activity-detected pause just occurred. Providers
    /// that derive segment boundaries some other way (e.g. `SpeechTranscriber`'s
    /// own volatile/final distinction) can ignore this — the default
    /// implementation below does exactly that. Called from a background
    /// audio queue, not the main actor — see this protocol's doc.
    nonisolated func notifyUtteranceBoundary()

    /// Ends the current session, flushing any trailing uncommitted segment
    /// through `onEvent` (`.segmentClosed`) first.
    func stop() async
}

extension TranscriptionProvider {
    public nonisolated func notifyUtteranceBoundary() {}
}
