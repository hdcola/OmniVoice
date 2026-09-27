import Testing
@testable import OmniVoiceCore

@Suite struct SentenceBoundaryTests {
    @Test func endsSentenceRecognizesTerminalPunctuation() {
        #expect(SentenceBoundary.endsSentence("Hello world."))
        #expect(SentenceBoundary.endsSentence("你好。"))
        #expect(!SentenceBoundary.endsSentence("Hello world"))
    }

    @Test func endsWithBreakAlsoAcceptsSoftBreaks() {
        #expect(SentenceBoundary.endsWithBreak("first clause,"))
        #expect(SentenceBoundary.endsWithBreak("第一句，"))
        #expect(!SentenceBoundary.endsWithBreak("no break here"))
    }

    @Test func providerCatalogModelVariantsAreScopedByEngine() {
        let r2t2Variants = ProviderCatalog.modelVariants(forEngineID: "model.r2t2")
        #expect(!r2t2Variants.isEmpty)
        #expect(r2t2Variants.allSatisfy { $0.engineID == "model.r2t2" })
    }
}
