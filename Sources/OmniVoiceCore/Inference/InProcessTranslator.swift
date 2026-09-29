import CLlamaCpp
import Foundation

/// Shared between every in-process translation model
/// (`InProcessTranslator`/T3PO, `HYMT15Translator`) — kept generic (no
/// model name baked into `.modelMissing`'s/`.notLoaded`'s wording) since both
/// throw it.
enum TranslatorError: LocalizedError {
    case modelMissing(String)
    case notLoaded
    case llamaCallFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let path):
            return "找不到模型权重: \(path)"
        case .notLoaded:
            return "模型尚未加载"
        case .llamaCallFailed(let context):
            return context
        }
    }
}

/// T3PO's calibrated latency/quality operating points
/// (`inference/latency.py` in netease-youdao/Confucius4-T3PO), applied as a
/// logit bias on the stop tokens during non-forced probes — see
/// `InProcessTranslator`'s header comment for what that bias actually does.
enum TranslationLatencyMode: Sendable {
    case low, native, high

    /// Positive commits earlier (lower latency, lower quality); negative
    /// waits longer (higher latency, higher quality); zero applies no bias
    /// and trusts the model's own trained WAIT/TRANS judgement. These three
    /// values are T3PO's own calibrated points, not independently tuned here.
    var tau: Float {
        switch self {
        case .low: return 0.9375009536743164
        case .native: return 0.0
        case .high: return -0.39
        }
    }
}

/// Translation target language, for T3PO's system prompt — mirrors
/// `mac-poc-hybrid`'s `TranslationTargetLanguage`, trimmed to just what
/// `InProcessTranslator` needs (the POC's `Locale.Language` conformance for
/// the *native* translation engine lives in `LanguageCatalog` here instead).
enum T3POTargetLanguage {
    case chinese, english, japanese, korean

    /// The English language name spliced into T3PO's system prompt.
    var promptName: String {
        switch self {
        case .chinese: return "Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        }
    }
}

/// Buffering/history knobs mirroring T3PO's reference streaming engine
/// (`inference/text_inference.py`'s `StreamingTextTranslator`/
/// `TranslationEngine` defaults) — copied rather than re-tuned, since they're
/// presumably already validated by the model's authors.
struct TranslationTuning {
    var latencyMode: TranslationLatencyMode = .native
    var targetLanguage: T3POTargetLanguage = .chinese
    /// Forces a probe (guaranteed non-empty output) once the buffer reaches
    /// this many units, so a long silence-free stretch of source text can't
    /// grow the prompt unboundedly.
    var maxBufferUnits: Int = 200
    /// Triggers a non-forced probe (model may still choose WAIT) once the
    /// buffer reaches this many units, even without sentence-ending
    /// punctuation.
    var forceBreakThreshold: Int = 20
    /// How many trailing (source, target) pairs stay in the prompt as
    /// context for the next probe.
    var historyWindow: Int = 30
}

/// Runs Confucius4-T3PO's streaming WAIT/TRANS translation policy
/// **in-process** via llama.cpp's C ABI (`third_party/llama.cpp/include/llama.h`),
/// fed by `InProcessTranscriber`'s ASR deltas/final tails (via
/// `ModelTranslationProvider`, which bridges the two through
/// `RecordingSession`, same as any other `TranslationProvider`). Ported
/// unchanged from `mac-poc-hybrid`'s `InProcessTranslator` — the underlying
/// design is stateless-by-design: **there is no persistent decode session to
/// push audio into.** T3PO's own reference engine re-sends the full prompt
/// (windowed history + current buffer) on every probe rather than
/// continuing a KV cache — so this does the same: `probeLocked` clears the
/// context's KV cache (`llama_memory_clear`) and reprocesses the whole
/// prompt from scratch on every call.
///
/// **WAIT vs TRANS**: T3PO has no special control token for this — the
/// reference engine compares the sampled next-token logit for a "stop" token
/// (`<|endoftext|>`/`<|im_end|>`) against the best non-stop token, and treats
/// "wanted to stop immediately" as WAIT (empty output). Here that's
/// reproduced as: on a **non-forced** probe, apply a logit bias
/// (`llama_sampler_init_logit_bias`) on the stop tokens scaled by
/// `tuning.latencyMode.tau`, and generate — if the model still stops on the
/// very first token, the output is empty, which `probeLocked` reads as WAIT
/// and leaves the buffer untouched for the next delta to extend. On a
/// **forced** probe (buffer overflow, or `flush()` at an ASR utterance
/// boundary), the stop tokens are *fully* suppressed (bias ~= -infinity) for
/// the first `forceMinNewTokens` steps, then generation switches to an
/// unbiased sampler free to stop naturally — guaranteeing a forced probe is
/// never WAIT, without claiming to replicate the reference engine's exact
/// `min_tokens` mechanism (behind an endpoint this app doesn't have).
///
/// **Thread-safety**: same shape as `InProcessTranscriber` — every entry
/// point funnels through one serial `queue`; a llama.cpp context handle is
/// no more safe to touch from two threads at once than an audiocpp session
/// was.
/// `@unchecked Sendable`: honest given this class's own documented
/// thread-safety contract above (every entry point funnels through the
/// serial `queue`) — needed so `loadModel(modelPath:)`'s `queue.async`
/// closure (a `@Sendable` closure, unlike the `queue.sync` ones elsewhere in
/// this file) can capture `self` without a compiler warning.
final class InProcessTranslator: @unchecked Sendable {
    /// Fires once per **committed** (TRANS) probe — append-only, like
    /// `InProcessTranscriber.onDelta`, not a tentative value that might later
    /// be revised. A WAIT probe fires nothing.
    var onPartialTranslation: ((String) -> Void)?
    /// Fires once per `flush()` call, always, whether or not that flush
    /// produced a commit (the buffer may already have been emptied by an
    /// earlier threshold-triggered probe within the same utterance) — a
    /// boundary marker a caller uses to know "no more `onPartialTranslation`
    /// calls belong to whatever I fed before this flush".
    var onFlushBoundary: (() -> Void)?
    /// Fires with the model's live best-guess translation of the **entire
    /// current buffer**, regenerated from scratch each time — a preview, not
    /// a commit: never appended to `history`, buffer is never cleared for
    /// it, meant to be *replaced wholesale* by the caller the moment a real
    /// commit covering the same text arrives via `onPartialTranslation`.
    /// Debounced (see `schedulePreview`) so a burst of fast deltas doesn't
    /// queue up a backlog of stale previews.
    var onPreviewTranslation: ((String) -> Void)?
    /// Read fresh on every probe — see `TranslationLatencyMode`'s doc.
    /// **Private**, on purpose: `feed`/`flush` dispatch onto `queue`
    /// asynchronously, so a caller mutating a public `tuning` directly from
    /// outside `queue` would race the in-flight probe that reads it. Use
    /// `setLatencyMode`/`setTargetLanguage` instead, which dispatch onto the
    /// same `queue` so the change is ordered relative to pending probes.
    private var tuning = TranslationTuning()

    private let queue = DispatchQueue(label: "org.omnivoice.inprocess.llama")

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    /// Source text collected since the last committed (TRANS) probe. Each
    /// element is one ASR delta/tail as received.
    private var buffer: [String] = []
    /// Windowed (source, target) pairs from prior committed probes, used as
    /// prompt context for the next one (T3PO's engine keeps this as literal
    /// text history, not a KV-cache continuation).
    private var history: [(src: String, target: String)] = []
    /// The currently-scheduled (not yet run) preview probe, if any — a new
    /// `feed()` cancels and reschedules this rather than letting one pile up
    /// per delta.
    private var pendingPreviewWorkItem: DispatchWorkItem?
    /// How long to wait after the *last* delta before running a preview.
    private static let previewDebounce: TimeInterval = 0.3

    /// Qwen's special stop tokens and T3PO's per-token bias scale
    /// (`inference/latency.py`'s `DEFAULT_STOP_TOKEN_IDS`/`bias_scales`).
    private static let stopTokens: [(id: llama_token, scale: Float)] = [
        (151643, 1.0),   // <|endoftext|>
        (151645, 1.05),  // <|im_end|>
    ]
    private static let maxNewTokens = 200
    /// How many stop-token-suppressed steps a forced probe guarantees before
    /// letting the model stop naturally.
    private static let forceMinNewTokens = 1
    /// Source language is left unstated on purpose — the prompt just asks
    /// for "live speech" and relies on the model to recognize the source
    /// language itself, the same way T3PO's own reference engine does.
    private static func systemPrompt(targetLanguage: String) -> String {
        """
        You are a professional simultaneous interpreter translating live speech into \(targetLanguage). \
        You will be given the translation history so far, as SOURCE¦TARGET pairs separated by §, \
        followed by new source text on its own line after a --- separator. Continue translating \
        naturally and consistently with the history — output only the new \(targetLanguage) translation \
        of the new source text, nothing else, no explanations.
        """
    }

    /// Resolved weights path — `modelPath` overrides everything (the caller,
    /// `ModelTranslationProvider`, threads `TranslationConfig.modelPath`
    /// through here); otherwise falls back to the `R2T2_T3PO_MODEL_PATH` env
    /// var (matching `mac-poc-hybrid`'s override), then this repo's own
    /// `models/` directory convention.
    static func resolveModelPath(override modelPath: URL?) -> String {
        if let modelPath { return modelPath.path }
        if let override = ProcessInfo.processInfo.environment["R2T2_T3PO_MODEL_PATH"] {
            return override
        }
        // .../Sources/OmniVoiceCore/Inference/InProcessTranslator.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Inference
            .deletingLastPathComponent() // OmniVoiceCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("models/Confucius4-T3PO-GGUF/Confucius4-T3PO-Q5_K_M.gguf").path
    }

    /// Loads the model and creates a decode context. Call once before the
    /// first `feed(sourceDelta:)`; safe to call again after `unload()`.
    ///
    /// Dispatches onto `queue` **asynchronously** — see
    /// `InProcessTranscriber.loadModel(modelPath:)`'s doc for why a
    /// `queue.sync` here would instead freeze the whole (`@MainActor`-bound)
    /// app UI for the whole load: the same reasoning applies verbatim to
    /// T3PO's weights load + `llama_init_from_model`.
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
        // Same defensive guard as `InProcessTranscriber.loadModelLocked`'s
        // — see its doc. Here the leak would be `model`/`ctx` (plus a
        // redundant `llama_backend_init()`), never freed since `unload()`
        // only ever sees whichever handles are current by the time it runs.
        guard model == nil else { return }
        let path = Self.resolveModelPath(override: modelPath)
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranslatorError.modelMissing(path)
        }

        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1 // negative = offload every layer (Metal)
        guard let mdl = path.withCString({ llama_model_load_from_file($0, modelParams) }) else {
            // Undo the `llama_backend_init()` above before throwing —
            // nothing else has been allocated yet, so this is the only
            // thing to unwind. Without it, a failure here leaves backend
            // state initialized with `model`/`ctx` still both `nil`, and
            // `unload()` (every caller's failure path already calls it
            // unconditionally) skips freeing anything when both are `nil`
            // — see its own doc — leaving this `llama_backend_init()`
            // permanently unpaired.
            llama_backend_free()
            throw TranslatorError.llamaCallFailed("加载 T3PO 模型失败")
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 4096
        // Must be >= the largest single prompt `generateLocked` ever hands
        // `llama_decode` in one call — every probe reprocesses the whole
        // prompt from scratch as one batch, so this can't be smaller than
        // `n_ctx` itself without risking `llama_decode`'s
        // `GGML_ASSERT(n_tokens_all <= cparams.n_batch)`, a hard abort(), not
        // a recoverable error — see `fittedSourceAndPromptLocked`'s doc for
        // the other half of this fix (keeping the prompt itself under
        // `n_ctx`, since this alone only raises the ceiling).
        ctxParams.n_batch = ctxParams.n_ctx
        // `model`/`ctx` only get assigned to the stored properties once
        // *both* succeed, not right after `llama_model_load_from_file`
        // above — same reasoning as `InProcessTranscriber.loadModelLocked`'s
        // registry/model fix: assigning `model` eagerly would leave it set
        // (passing the `guard model == nil` retry check) while `ctx` stayed
        // `nil` if this call failed, silently wedging every future
        // `feed`/`flush` call (which both require `ctx != nil`) with no
        // error ever surfaced and no way to recover short of `unload()`.
        guard let context = llama_init_from_model(mdl, ctxParams) else {
            // Same unwind reasoning as `llama_model_load_from_file`'s
            // failure above — `model`/`ctx` are still both `nil` here too.
            llama_model_free(mdl)
            llama_backend_free()
            throw TranslatorError.llamaCallFailed("创建 T3PO 推理上下文失败")
        }
        model = mdl
        ctx = context
    }

    /// Appends one ASR delta/tail to the source buffer and, per `tuning`'s
    /// thresholds, may trigger a probe that either commits a translation
    /// (`onPartialTranslation`) or WAITs (leaves the buffer alone for the
    /// next call to extend). Safe to call before `loadModel()` finishes or
    /// after `unload()` — a no-op.
    ///
    /// Dispatches **asynchronously** onto `queue` — a probe here can take
    /// real seconds (an LLM generate call), so a caller feeding ASR deltas
    /// synchronously on its own queue never blocks behind translation
    /// latency. Relative order is still preserved — `queue` is still serial.
    func feed(sourceDelta: String) {
        queue.async { self.feedLocked(sourceDelta: sourceDelta) }
    }

    private func feedLocked(sourceDelta: String) {
        guard model != nil, ctx != nil, !sourceDelta.isEmpty else { return }
        buffer.append(sourceDelta)

        if buffer.count >= tuning.maxBufferUnits {
            pendingPreviewWorkItem?.cancel()
            probeLocked(force: true)
            return
        }

        if buffer.count >= tuning.forceBreakThreshold || SentenceBoundary.endsSentence(sourceDelta) {
            pendingPreviewWorkItem?.cancel()
            probeLocked(force: false)
            return
        }

        schedulePreview()
    }

    /// Cancels any not-yet-run preview and schedules a new one
    /// `previewDebounce` seconds out — repeated fast `feed()` calls keep
    /// pushing this back rather than each queuing its own preview.
    private func schedulePreview() {
        guard onPreviewTranslation != nil, !buffer.isEmpty else { return }
        pendingPreviewWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.runPreviewLocked()
        }
        pendingPreviewWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.previewDebounce, execute: workItem)
    }

    /// Translates the current buffer as a preview: same prompt-building and
    /// generation machinery a real probe uses, but never touches `buffer`
    /// and never calls `onPartialTranslation`. Uses `force: true` generation
    /// (no WAIT bias) since a preview should always show its best guess.
    private func runPreviewLocked() {
        guard !buffer.isEmpty else { return }
        guard let (_, prompt) = fittedSourceAndPromptLocked(bufferUnits: buffer) else { return }
        let output = generateLocked(prompt: prompt, force: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return }
        onPreviewTranslation?(output)
    }

    /// Forces a probe of whatever's left in the buffer — call this once an
    /// ASR utterance boundary reports its final tail, so a source fragment
    /// that never crossed `forceBreakThreshold`/punctuation doesn't sit
    /// untranslated forever. Also dispatches asynchronously, same reasoning
    /// as `feed(sourceDelta:)`.
    func flush() {
        queue.async {
            self.pendingPreviewWorkItem?.cancel()
            if !self.buffer.isEmpty {
                self.probeLocked(force: true)
            }
            self.onFlushBoundary?()
        }
    }

    /// Changes `tuning.latencyMode`, ordered (via `queue`) relative to any
    /// already-enqueued `feed`/`flush` calls.
    func setLatencyMode(_ mode: TranslationLatencyMode) {
        queue.async { self.tuning.latencyMode = mode }
    }

    /// Same ordering guarantee as `setLatencyMode(_:)`, for
    /// `tuning.targetLanguage`.
    func setTargetLanguage(_ language: T3POTargetLanguage) {
        queue.async { self.tuning.targetLanguage = language }
    }

    /// Runs one WAIT/TRANS decision. On TRANS, commits `(source, target)`
    /// into `history` (windowed), clears `buffer`, and reports the
    /// translation. On WAIT, leaves everything as-is. Returns whether it
    /// committed.
    @discardableResult
    private func probeLocked(force: Bool) -> Bool {
        guard !buffer.isEmpty, model != nil, ctx != nil else { return false }
        guard let (sourceText, prompt) = fittedSourceAndPromptLocked(bufferUnits: buffer) else { return false }

        let output = generateLocked(prompt: prompt, force: force)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return false } // WAIT

        history.append((src: sourceText, target: output))
        if history.count > tuning.historyWindow {
            history.removeFirst(history.count - tuning.historyWindow)
        }
        buffer.removeAll()
        onPartialTranslation?(output)
        return true
    }

    private static func serializeHistory(_ history: [(src: String, target: String)]) -> String {
        history.map { "\($0.src)¦\($0.target)" }.joined(separator: "§")
    }

    /// Builds a prompt guaranteed to tokenize within `n_ctx`'s budget for
    /// `generateLocked`'s single-shot `llama_decode` call. Because
    /// `history`/`buffer` are otherwise unbounded in total token count
    /// (`historyWindow`/`maxBufferUnits` cap *entry counts*, not tokens),
    /// this has to reduce what's sent, not just detect the overflow.
    ///
    /// Drops oldest `history` entries first — permanently, since stale
    /// context that no longer fits isn't coming back. Only if `history` is
    /// already empty and a *single* buffer is still too big does it fall
    /// back to dropping the buffer's oldest units (kept for the LLM prompt
    /// only; the caller still clears/commits the *original*, untrimmed
    /// buffer — a last resort for a pathological single delta).
    private func fittedSourceAndPromptLocked(bufferUnits: [String]) -> (sourceText: String, prompt: String)? {
        guard let ctx, let model, let vocab = llama_model_get_vocab(model) else { return nil }
        let budget = Int32(llama_n_ctx(ctx)) - Int32(Self.maxNewTokens)
        var units = bufferUnits

        while true {
            let sourceText = units.joined()
            guard let prompt = buildPromptLocked(sourceText: sourceText) else { return nil }
            let tokenCount = LlamaGeneration.tokenCount(of: prompt, vocab: vocab)
            if tokenCount <= budget || (history.isEmpty && units.count <= 1) {
                return (sourceText, prompt)
            }
            if !history.isEmpty {
                history.removeFirst()
            } else {
                units.removeFirst()
            }
        }
    }

    /// Builds the prompt via the model's own built-in chat template
    /// (`llama_model_chat_template(model, nil)` — Qwen's `<|im_start|>...`
    /// format). Every role/content C string must stay alive for the whole
    /// `llama_chat_apply_template` call, not just the `withCString` that
    /// produced it, hence the nesting.
    private func buildPromptLocked(sourceText: String) -> String? {
        guard let model else { return nil }
        let historyText = Self.serializeHistory(history)
        let userText = historyText.isEmpty ? sourceText : "\(historyText)\n---\n\(sourceText)"
        let systemPrompt = Self.systemPrompt(targetLanguage: tuning.targetLanguage.promptName)
        return LlamaGeneration.applyChatTemplate(model: model, systemPrompt: systemPrompt, userText: userText)
    }

    /// Greedily decodes up to `maxNewTokens` — see the class doc's WAIT/TRANS
    /// section for what `force` changes about the sampler chain used.
    private func generateLocked(prompt: String, force: Bool) -> String {
        guard let model, let ctx, let vocab = llama_model_get_vocab(model) else { return "" }

        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else { return "" }
        defer { llama_sampler_free(chain) }
        if !force {
            let tau = tuning.latencyMode.tau
            guard let waitBiasSampler = LlamaGeneration.makeLogitBiasSampler(
                vocab: vocab, biases: Self.stopTokens.map { ($0.id, -tau * $0.scale) }
            ) else { return "" }
            llama_sampler_chain_add(chain, waitBiasSampler)
        }
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())

        var suppressChain: UnsafeMutablePointer<llama_sampler>?
        defer { if let suppressChain { llama_sampler_free(suppressChain) } }
        if force {
            guard let suppressBias = LlamaGeneration.makeLogitBiasSampler(
                vocab: vocab, biases: Self.stopTokens.map { ($0.id, Float(-1e9)) }
            ) else { return "" }
            let suppressParams = llama_sampler_chain_default_params()
            guard let built = llama_sampler_chain_init(suppressParams) else { return "" }
            llama_sampler_chain_add(built, suppressBias)
            llama_sampler_chain_add(built, llama_sampler_init_greedy())
            suppressChain = built
        }

        return LlamaGeneration.generate(
            ctx: ctx, model: model, prompt: prompt, maxNewTokens: Self.maxNewTokens,
            samplerForStep: { i in (force && i < Self.forceMinNewTokens) ? suppressChain! : chain }
        )
    }

    /// Ends this recording's session — clears the buffered source text and
    /// windowed history so a new recording's first `feed(sourceDelta:)`
    /// doesn't leak the previous one's context into its prompt — without
    /// releasing `model`/`ctx` (contrast `unload()` below, the actual
    /// teardown). Cheap: no GPU/model resources are touched, just the two
    /// in-memory arrays.
    func resetSession() {
        queue.sync {
            pendingPreviewWorkItem?.cancel()
            buffer.removeAll()
            history.removeAll()
        }
    }

    /// Releases the context/model. Also frees the llama.cpp backend
    /// (`llama_backend_free`) — like `InProcessTranscriber.unload()`'s
    /// audiocpp teardown, this matters for ggml's Metal backend exit-time
    /// assert (`ggml_metal_rsets_free`), not just cleanliness; leaving GPU
    /// resources alive past process exit trips it.
    func unload() {
        queue.sync {
            pendingPreviewWorkItem?.cancel()
            buffer.removeAll()
            history.removeAll()
            // Every caller in `RecordingSession` calls this unconditionally
            // on any `loadModel()` failure, including one that threw before
            // `loadModelLocked` ever called `llama_backend_init()` (e.g.
            // `TranslatorError.modelMissing`) — `model`/`ctx` both `nil`
            // here is exactly that case, and `llama_backend_free()` would
            // free global backend state that was never initialized in the
            // first place. `loadModelLocked`'s own failure paths already
            // pair every `llama_backend_init()` they perform with a
            // matching `llama_backend_free()` before throwing, so by the
            // time this runs, "backend was initialized" and "`model`/`ctx`
            // non-`nil`" are the same condition.
            guard model != nil || ctx != nil else { return }
            if let ctx { llama_free(ctx) }
            if let model { llama_model_free(model) }
            ctx = nil
            model = nil
            llama_backend_free()
        }
    }

    /// A safety net, not the normal teardown path — see
    /// `InProcessTranscriber.deinit`'s doc, which applies here verbatim
    /// (same risk: a leaked, Metal-backed `ctx`/`model` past process exit
    /// trips ggml's exit-time assert). No `queue.sync`, for the same reason
    /// given there.
    ///
    /// Unlike that one, this guards on `ctx`/`model` still being non-nil —
    /// `llama_backend_free()` looks to be global/singleton teardown (unlike
    /// audiocpp's per-handle frees, which are null-safe to call twice by
    /// this class's own contract), so calling it again here after `unload()`
    /// already ran (leaving both `nil`) would double-free global backend
    /// state instead of safely no-op'ing.
    deinit {
        guard ctx != nil || model != nil else { return }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        llama_backend_free()
    }
}
