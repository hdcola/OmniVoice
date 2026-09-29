import CLlamaCpp
import Foundation

/// Mechanical llama.cpp C-ABI plumbing shared by every in-process
/// translation model (`InProcessTranslator`/T3PO, `HYMT15Translator`) —
/// tokenizing, applying a model's own chat template, and the
/// clear-KV-cache-then-decode generation loop. None of this is aware of a
/// specific model's prompt wording, WAIT/TRANS policy, or sampling
/// parameters — those stay in each translator, which composes these
/// primitives its own way (see `InProcessTranslator`'s class doc for why
/// T3PO's WAIT/TRANS trick in particular isn't factored in here).
enum LlamaGeneration {
    /// Returns how many tokens `text` would tokenize to, without allocating
    /// an output buffer — uses `llama_tokenize`'s documented convention of
    /// returning `-n` when the (here, zero-sized) output buffer is too
    /// small for `n` tokens.
    static func tokenCount(of text: String, vocab: OpaquePointer) -> Int32 {
        let n = text.withCString { textPtr in
            llama_tokenize(vocab, textPtr, Int32(strlen(textPtr)), nil, 0, true, true)
        }
        return n < 0 ? -n : n
    }

    /// Applies `model`'s own built-in chat template
    /// (`llama_model_chat_template(model, nil)`) to a single (system, user)
    /// message pair. Every role/content C string must stay alive for the
    /// whole `llama_chat_apply_template` call, not just the `withCString`
    /// that produced it, hence the nesting.
    static func applyChatTemplate(model: OpaquePointer, systemPrompt: String, userText: String) -> String? {
        let tmpl = llama_model_chat_template(model, nil)
        return "system".withCString { systemRolePtr in
            "user".withCString { userRolePtr in
                systemPrompt.withCString { sysContentPtr -> String? in
                    userText.withCString { userContentPtr -> String? in
                        let messages = [
                            llama_chat_message(role: systemRolePtr, content: sysContentPtr),
                            llama_chat_message(role: userRolePtr, content: userContentPtr),
                        ]
                        var bufSize: Int32 = 8192
                        var buf = [CChar](repeating: 0, count: Int(bufSize))
                        var n = messages.withUnsafeBufferPointer { msgs in
                            llama_chat_apply_template(tmpl, msgs.baseAddress, msgs.count, true, &buf, bufSize)
                        }
                        if n > bufSize {
                            bufSize = n
                            buf = [CChar](repeating: 0, count: Int(bufSize))
                            n = messages.withUnsafeBufferPointer { msgs in
                                llama_chat_apply_template(tmpl, msgs.baseAddress, msgs.count, true, &buf, bufSize)
                            }
                        }
                        guard n > 0 else { return nil }
                        return String(cString: buf)
                    }
                }
            }
        }
    }

    // llama_sampler (unlike llama_model/llama_context/llama_vocab) is a
    // fully-defined C struct in llama.h, not forward-declared-only — so
    // Swift imports pointers to it as UnsafeMutablePointer<llama_sampler>,
    // not OpaquePointer. Must match that exactly, not the OpaquePointer
    // convention used for model/ctx/vocab.
    static func makeLogitBiasSampler(
        vocab: OpaquePointer, biases: [(id: llama_token, value: Float)]
    ) -> UnsafeMutablePointer<llama_sampler>? {
        let nVocab = llama_vocab_n_tokens(vocab)
        let logitBias = biases.map { llama_logit_bias(token: $0.id, bias: $0.value) }
        return logitBias.withUnsafeBufferPointer { buf in
            llama_sampler_init_logit_bias(nVocab, Int32(buf.count), buf.baseAddress)
        }
    }

    /// Clears `ctx`'s KV cache and reprocesses `prompt` from scratch — every
    /// caller of this is a stateless-by-design model that resends the whole
    /// prompt on each call rather than continuing a KV cache (see
    /// `InProcessTranslator`'s class doc) — then decodes up to
    /// `maxNewTokens` tokens, greedily accepting whatever `samplerForStep`
    /// hands back for that step index (0-based). Returning `nil` from
    /// `samplerForStep` stops generation early (unused by any caller today,
    /// kept for symmetry with a fixed-length forced/primary split like
    /// T3PO's). Stops on the model's own end-of-generation token or a
    /// `llama_decode` failure.
    static func generate(
        ctx: OpaquePointer, model: OpaquePointer, prompt: String, maxNewTokens: Int,
        samplerForStep: (Int) -> UnsafeMutablePointer<llama_sampler>?
    ) -> String {
        guard let vocab = llama_model_get_vocab(model) else { return "" }

        llama_memory_clear(llama_get_memory(ctx), true)

        var tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 16)
        let nTokens = prompt.withCString { promptPtr in
            llama_tokenize(vocab, promptPtr, Int32(strlen(promptPtr)), &tokens, Int32(tokens.count), true, true)
        }
        guard nTokens > 0 else { return "" }
        tokens = Array(tokens.prefix(Int(nTokens)))

        let initialBatch = llama_batch_get_one(&tokens, Int32(tokens.count))
        guard llama_decode(ctx, initialBatch) == 0 else { return "" }

        var output = ""
        for i in 0..<maxNewTokens {
            guard let sampler = samplerForStep(i) else { break }
            let newToken = llama_sampler_sample(sampler, ctx, -1)
            llama_sampler_accept(sampler, newToken)
            if llama_vocab_is_eog(vocab, newToken) { break }

            var pieceBuf = [CChar](repeating: 0, count: 64)
            let n = llama_token_to_piece(vocab, newToken, &pieceBuf, Int32(pieceBuf.count), 0, false)
            if n > 0 {
                output += String(decoding: pieceBuf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }

            var nextToken = newToken
            let nextBatch = llama_batch_get_one(&nextToken, 1)
            guard llama_decode(ctx, nextBatch) == 0 else { break }
        }
        return output
    }
}
