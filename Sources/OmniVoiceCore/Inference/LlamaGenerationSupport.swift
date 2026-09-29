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
                        // `>=`, not `>`: `llama_chat_apply_template`'s C++
                        // implementation copies via `strncpy(buf,
                        // formatted_chat.c_str(), length)`, which only
                        // null-terminates when `length` is *strictly
                        // larger* than the source — `n == bufSize` (the
                        // formatted prompt exactly filling the first,
                        // 8192-byte buffer) is just as unterminated as
                        // `n > bufSize`, so checking `>` alone would silently
                        // skip the retry for that one exact-fit size and
                        // fall through to `String(cString:)` reading past
                        // the end of `buf` hunting for a `\0` that was never
                        // written.
                        if n >= bufSize {
                            // Retry with `n + 1`: guarantees `length` is
                            // strictly larger than the source this time, so
                            // `strncpy` pads the last byte with the `\0`
                            // `String(cString:)` needs.
                            bufSize = n + 1
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

        // Sized from an exact dry-run count (`tokenCount(of:vocab:)`,
        // `llama_tokenize`'s own "-n means n tokens needed" convention)
        // rather than a `prompt.utf8.count`-based guess — a fixed slack
        // constant can't be trusted to always cover the actual token count
        // for every tokenizer/language (a byte-level BPE vocab can tokenize
        // some scripts, notably CJK, less than 1:1 with UTF-8 bytes).
        let neededTokens = Int(tokenCount(of: prompt, vocab: vocab))
        guard neededTokens > 0 else { return "" }
        var tokens = [llama_token](repeating: 0, count: neededTokens)
        let nTokens = prompt.withCString { promptPtr in
            llama_tokenize(vocab, promptPtr, Int32(strlen(promptPtr)), &tokens, Int32(tokens.count), true, true)
        }
        guard nTokens > 0, Int(nTokens) <= tokens.count else { return "" }
        tokens = Array(tokens.prefix(Int(nTokens)))

        // `llama_batch_get_one` just wraps whatever pointer it's given —
        // it doesn't copy `tokens`' contents — so the batch it returns is
        // only valid for as long as that pointer is: Swift's `&tokens`
        // conversion is documented as valid *only during the call it's
        // passed to*, so using the resulting `llama_batch` in a *separate*,
        // later statement (as this used to, splitting the batch's
        // construction from `llama_decode`'s call) is undefined behavior,
        // not just theoretically — even though it "happens to work" against
        // the current toolchain. Constructing the batch and decoding it
        // inside the same `withUnsafeMutableBufferPointer` closure keeps
        // both within the pointer's one guaranteed-valid scope.
        let initialDecodeSucceeded = tokens.withUnsafeMutableBufferPointer { tokensBuf in
            llama_decode(ctx, llama_batch_get_one(tokensBuf.baseAddress, Int32(tokensBuf.count))) == 0
        }
        guard initialDecodeSucceeded else { return "" }

        // Accumulated as raw bytes and decoded to UTF-8 once at the end,
        // not per token — a byte-level tokenizer's vocab can (and for CJK
        // output, routinely does) split one multi-byte UTF-8 character
        // across more than one token/piece; decoding each piece on its own
        // would hit an incomplete byte sequence mid-character and silently
        // replace it with U+FFFD instead of ever seeing the complete
        // character.
        var outputBytes: [UInt8] = []
        for i in 0..<maxNewTokens {
            guard let sampler = samplerForStep(i) else { break }
            let newToken = llama_sampler_sample(sampler, ctx, -1)
            llama_sampler_accept(sampler, newToken)
            if llama_vocab_is_eog(vocab, newToken) { break }

            // Same negative-return-means-"needed this many bytes" convention
            // as `llama_tokenize`'s — 64 bytes covers a typical single-token
            // piece, but not guaranteed for every one (a long byte-fallback
            // sequence or an unusual special/control token could exceed
            // it), and silently dropping a token instead of retrying would
            // lose a chunk of the output with no sign anything went wrong.
            var pieceBuf = [CChar](repeating: 0, count: 64)
            var n = llama_token_to_piece(vocab, newToken, &pieceBuf, Int32(pieceBuf.count), 0, false)
            if n < 0 {
                pieceBuf = [CChar](repeating: 0, count: Int(-n))
                n = llama_token_to_piece(vocab, newToken, &pieceBuf, Int32(pieceBuf.count), 0, false)
            }
            if n > 0 {
                outputBytes.append(contentsOf: pieceBuf[0..<Int(n)].map { UInt8(bitPattern: $0) })
            }

            // Same scoping reasoning as the initial batch above.
            var nextToken = newToken
            let nextDecodeSucceeded = withUnsafeMutablePointer(to: &nextToken) { tokenPtr in
                llama_decode(ctx, llama_batch_get_one(tokenPtr, 1)) == 0
            }
            guard nextDecodeSucceeded else { break }
        }
        return String(decoding: outputBytes, as: UTF8.self)
    }
}
