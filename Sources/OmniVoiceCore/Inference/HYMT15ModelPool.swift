import Foundation

/// Hands out one loaded `HYMT15Translator` per weights file, reference
/// counted, so the recording's `HYMT15TranslationProvider` and the selection
/// panel's `SelectionModelBackend` share a single copy of the weights
/// instead of each loading their own.
///
/// Sharing one instance is safe because `HYMT15Translator` already
/// serializes every model call on its own queue, and the two users touch
/// disjoint state: the recording uses the streaming `feed`/`flush` path
/// (`buffer`/`history`/`targetLanguage`), the panel only the stateless
/// `translateText(_:targetLanguage:sourceIsChinese:)`. The one cost is
/// latency, not correctness — a selection translation queues behind an
/// in-flight transcript translation (and vice versa), each well under a
/// second for the 1.8B variants.
@MainActor
final class HYMT15ModelPool {
    static let shared = HYMT15ModelPool()

    /// Internal so tests can use a private pool instead of `shared`.
    init() {}

    private final class Entry {
        let translator = HYMT15Translator()
        var holders = 0
        var load: Task<Void, Error>?
    }

    /// Keyed by `HYMT15Translator.resolveModelPath(override:)`, so a nil
    /// `modelURL` (the env-var/`models/` fallback) and the explicit URL it
    /// resolves to share an entry.
    private var entries: [String: Entry] = [:]

    /// Whether `modelURL`'s weights are already loaded by some holder — lets
    /// the panel skip its "正在加载模型…" state when a recording has them.
    func isLoaded(modelURL: URL?) -> Bool {
        guard let entry = entries[HYMT15Translator.resolveModelPath(override: modelURL)] else { return false }
        return entry.holders > 0 && entry.load == nil
    }

    /// Loads the weights on first acquisition; later ones wait for (or
    /// reuse) that same load. Every successful `acquire` must be balanced
    /// by one `release`.
    func acquire(modelURL: URL?) async throws -> HYMT15Translator {
        let path = HYMT15Translator.resolveModelPath(override: modelURL)
        let entry: Entry
        if let existing = entries[path] {
            entry = existing
        } else {
            entry = Entry()
            let translator = entry.translator
            entry.load = Task { try await translator.loadModel(modelPath: URL(fileURLWithPath: path)) }
            entries[path] = entry
        }
        entry.holders += 1
        do {
            try await entry.load?.value
            entry.load = nil
            return entry.translator
        } catch {
            // A failed load leaves nothing to share — the next `acquire`
            // retries from scratch instead of re-reading this failure.
            entry.holders -= 1
            if entries[path] === entry { entries[path] = nil }
            throw error
        }
    }

    /// Synchronously frees the weights once the last holder lets go — safe
    /// to call from `applicationWillTerminate` (see
    /// `InProcessTranslator.unload()`'s doc for why that must be synchronous).
    func release(_ translator: HYMT15Translator) {
        guard let (path, entry) = entries.first(where: { $0.value.translator === translator }) else { return }
        entry.holders -= 1
        guard entry.holders <= 0 else { return }
        entries[path] = nil
        translator.unload()
    }
}
