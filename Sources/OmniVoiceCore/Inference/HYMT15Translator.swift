import CLlamaCpp
import Foundation

/// Translation target language, for HY-MT1.5's translation-instruction
/// prompt — same four-language subset `T3POTargetLanguage` exposes (see
/// `ModelLanguageMapping`'s doc for why: this app's `LanguageCatalog` only
/// ever offers `zh`/`en`/`ja`/`ko` as translation targets today, a small
/// slice of HY-MT1.5's own much larger supported language list).
enum HYMT15TargetLanguage {
    case chinese, english, japanese, korean

    var promptName: String {
        switch self {
        case .chinese: return "Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        }
    }
}

/// Runs Tencent's HY-MT1.5 translation model **in-process** via llama.cpp's
/// C ABI, fed by an ASR provider's committed deltas/final tails (via
/// `HYMT15TranslationProvider`), same wiring shape as `InProcessTranslator`
/// (T3PO).
///
/// Unlike T3PO, HY-MT1.5 has no trained WAIT/TRANS control signal to probe
/// for (see `Docs/PROGRESS.md`'s "known gaps" and `InProcessTranslator`'s
/// class doc for what that trick is and why it's T3PO-specific) — it's a
/// standard instruction-following model whose card documents a single
/// "translate the following segment" turn, not an incremental/streaming
/// decode. So this class never probes mid-utterance and never emits a
/// preview: `feed(sourceDelta:)` only buffers text, and `flush()` is the
/// only thing that ever calls the model, translating whatever's buffered in
/// one shot — the same cadence `SystemTranslationProvider` uses for the
/// system Translation framework, just backed by an in-process model instead
/// of an API call.
///
/// **Thread-safety**: same shape as `InProcessTranslator` — every entry
/// point funnels through one serial `queue`.
/// `@unchecked Sendable`: honest given that contract, same reasoning as
/// `InProcessTranslator`'s.
final class HYMT15Translator: @unchecked Sendable {
    /// Fires once per `flush()` that had anything buffered to translate —
    /// there is no separate preview/partial signal, unlike
    /// `InProcessTranslator.onPartialTranslation`/`onPreviewTranslation`.
    var onCommit: ((String) -> Void)?
    /// Fires once per `flush()` call, always — same boundary-marker contract
    /// as `InProcessTranslator.onFlushBoundary`.
    var onFlushBoundary: (() -> Void)?

    private var targetLanguage: HYMT15TargetLanguage = .chinese
    /// See `TranslationConfig.earlyTranslateThreshold`'s doc — read fresh in
    /// `feedLocked`, same "mutate only via a queue-dispatched setter"
    /// reasoning as `InProcessTranslator.tuning`'s doc.
    private var earlyTranslateThreshold = 150

    private let queue = DispatchQueue(label: "org.omnivoice.inprocess.hymt15")

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    /// Source text collected since the last `flush()` — unlike
    /// `InProcessTranslator.buffer`, this never gets probed mid-way; it's
    /// only ever consumed whole by `flush()`.
    private var buffer: [String] = []

    private static let maxNewTokens = 200
    /// Tencent's own recommended sampling parameters for this model
    /// (HY-MT1.5 model card) — this model wasn't trained with T3PO's
    /// WAIT/TRANS logit-bias trick, so there's no reason to force greedy
    /// decoding the way `InProcessTranslator` does.
    private static let temperature: Float = 0.7
    private static let topK: Int32 = 20
    private static let topP: Float = 0.6
    private static let repeatPenalty: Float = 1.05
    private static let repeatLastN: Int32 = 64

    /// Tencent's documented translation-instruction template (HY-MT1.5
    /// model card) — deliberately does not ask for "live speech" the way
    /// T3PO's prompt does, since this model has no notion of an in-progress
    /// utterance; each call gets the complete buffered text.
    private static func systemPrompt(targetLanguage: String) -> String {
        "Translate the following segment into \(targetLanguage), without additional explanation."
    }

    /// Resolved weights path — mirrors `InProcessTranslator.resolveModelPath`'s
    /// override chain (explicit path, then an env var, then this repo's own
    /// `models/` directory convention), with HY-MT1.5's own env var name and
    /// default filename.
    static func resolveModelPath(override modelPath: URL?) -> String {
        if let modelPath { return modelPath.path }
        if let override = ProcessInfo.processInfo.environment["HY_MT15_MODEL_PATH"] {
            return override
        }
        // .../Sources/OmniVoiceCore/Inference/HYMT15Translator.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Inference
            .deletingLastPathComponent() // OmniVoiceCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("models/HY-MT1.5-GGUF/HY-MT1.5-1.8B-Q4_K_M.gguf").path
    }

    /// Loads the model and creates a decode context — same shape/reasoning
    /// as `InProcessTranslator.loadModel(modelPath:)`.
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
        guard model == nil else { return }
        let path = Self.resolveModelPath(override: modelPath)
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranslatorError.modelMissing(path)
        }

        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1 // negative = offload every layer (Metal)
        guard let mdl = path.withCString({ llama_model_load_from_file($0, modelParams) }) else {
            llama_backend_free()
            throw TranslatorError.llamaCallFailed("加载 HY-MT1.5 模型失败")
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 4096
        // Must be >= the largest single prompt `translateBufferLocked` ever
        // hands `llama_decode` in one call — see
        // `InProcessTranslator.loadModelLocked`'s doc for the same
        // `GGML_ASSERT` this guards against.
        ctxParams.n_batch = ctxParams.n_ctx
        guard let context = llama_init_from_model(mdl, ctxParams) else {
            llama_model_free(mdl)
            llama_backend_free()
            throw TranslatorError.llamaCallFailed("创建 HY-MT1.5 推理上下文失败")
        }
        model = mdl
        ctx = context
    }

    /// Appends one ASR delta/tail to the source buffer — and, once the
    /// buffer crosses half of `earlyTranslateThreshold`, watches for the
    /// next delta that ends a sentence and translates early as soon as one
    /// arrives, rather than cutting mid-sentence purely by length; crossing
    /// the full `earlyTranslateThreshold` forces an early translation
    /// regardless of punctuation (see
    /// `TranslationConfig.earlyTranslateThreshold`'s doc for the full
    /// reasoning: a single long, pause-free utterance shouldn't leave the
    /// user waiting for a translation, or waiting on a large block of text
    /// all at once, until the speaker finally stops). That early translation
    /// reuses `translateBufferLocked()` — the same primitive `flush()` uses
    /// below — which only ever calls `onCommit`, never `onFlushBoundary`, so
    /// it appends into the segment's still-open translation row instead of
    /// closing it. Safe to call before `loadModel()` finishes or after
    /// `unload()` — a no-op.
    func feed(sourceDelta: String) {
        queue.async {
            guard self.model != nil, self.ctx != nil, !sourceDelta.isEmpty else { return }
            self.buffer.append(sourceDelta)
            let bufferedLength = self.buffer.reduce(0) { $0 + $1.count }
            let threshold = self.earlyTranslateThreshold
            let crossedHardCap = bufferedLength >= threshold
            let crossedSoftBreak = bufferedLength >= threshold / 2 && SentenceBoundary.endsSentence(sourceDelta)
            if crossedHardCap || crossedSoftBreak {
                self.translateBufferLocked()
            }
        }
    }

    /// Translates whatever's buffered (if anything) in one shot, then fires
    /// `onFlushBoundary` — call this once an ASR utterance/segment boundary
    /// is reported. Dispatches asynchronously, same reasoning as
    /// `InProcessTranslator.flush()`.
    func flush() {
        queue.async {
            if !self.buffer.isEmpty {
                self.translateBufferLocked()
            }
            self.onFlushBoundary?()
        }
    }

    func setTargetLanguage(_ language: HYMT15TargetLanguage) {
        queue.async { self.targetLanguage = language }
    }

    func setEarlyTranslateThreshold(_ characters: Int) {
        queue.async { self.earlyTranslateThreshold = characters }
    }

    private func translateBufferLocked() {
        guard let ctx, let model, let vocab = llama_model_get_vocab(model) else { return }
        let sourceText = buffer.joined()
        buffer.removeAll()
        guard !sourceText.isEmpty else { return }

        let systemPrompt = Self.systemPrompt(targetLanguage: targetLanguage.promptName)
        guard var prompt = LlamaGeneration.applyChatTemplate(
            model: model, systemPrompt: systemPrompt, userText: sourceText
        ) else { return }

        // A single buffered utterance can in principle still overflow a
        // small context — trim from the front of the source text and
        // rebuild the prompt rather than risking `llama_decode`'s hard
        // `abort()` on an over-budget batch. Same *mechanism*
        // `InProcessTranslator.fittedSourceAndPromptLocked` uses, but a
        // different trade-off: T3PO trims stale (source, target) *history*
        // first — already-translated text, safe to drop. Here there's no
        // history to trim; `trimmedSource` is the untranslated text itself,
        // so trimming its front permanently drops whatever was said first
        // in this buffer, uncommitted, never translated. Only reachable at
        // all with an exceptionally large `earlyTranslateThreshold` (user
        // configurable up to 1000) on a small context window — accepted as
        // a last-resort safety valve against a hard crash, not a graceful
        // degradation.
        let budget = Int32(llama_n_ctx(ctx)) - Int32(Self.maxNewTokens)
        var trimmedSource = sourceText
        while LlamaGeneration.tokenCount(of: prompt, vocab: vocab) > budget, trimmedSource.count > 1 {
            let dropCount = max(1, trimmedSource.count / 8)
            trimmedSource.removeFirst(min(dropCount, trimmedSource.count - 1))
            guard let retried = LlamaGeneration.applyChatTemplate(
                model: model, systemPrompt: systemPrompt, userText: trimmedSource
            ) else { return }
            prompt = retried
        }

        guard let sampler = Self.makeSamplerChain(vocab: vocab) else { return }
        defer { llama_sampler_free(sampler) }

        let output = LlamaGeneration.generate(
            ctx: ctx, model: model, prompt: prompt, maxNewTokens: Self.maxNewTokens,
            samplerForStep: { _ in sampler }
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !output.isEmpty else { return }
        onCommit?(output)
    }

    private static func makeSamplerChain(vocab: OpaquePointer) -> UnsafeMutablePointer<llama_sampler>? {
        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else { return nil }
        llama_sampler_chain_add(
            chain,
            llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), repeatLastN, repeatPenalty, 0, 0)
        )
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        return chain
    }

    /// Ends this recording's session — clears the buffered source text so a
    /// new recording's first `feed(sourceDelta:)` doesn't leak the previous
    /// one's leftover buffer into a translation — without releasing
    /// `model`/`ctx` (contrast `unload()` below).
    func resetSession() {
        queue.sync {
            buffer.removeAll()
        }
    }

    /// Releases the context/model — same reasoning as
    /// `InProcessTranslator.unload()`'s doc (including the ggml Metal
    /// exit-time-assert concern).
    func unload() {
        queue.sync {
            buffer.removeAll()
            guard model != nil || ctx != nil else { return }
            if let ctx { llama_free(ctx) }
            if let model { llama_model_free(model) }
            ctx = nil
            model = nil
            llama_backend_free()
        }
    }

    /// A safety net, not the normal teardown path — see
    /// `InProcessTranslator.deinit`'s doc, which applies here verbatim.
    deinit {
        guard ctx != nil || model != nil else { return }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        llama_backend_free()
    }
}
