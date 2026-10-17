import Testing
@testable import OmniVoiceCore

struct SherpaVariantCatalogTests {
    @Test func theSherpaEngineIsAModelEngineWithAMultiFileVariant() throws {
        let engine = try #require(ProviderCatalog.transcriptionEngines.first { $0.id == "model.sherpa" })
        #expect(engine.kind == .model)

        let variants = ProviderCatalog.modelVariants(forEngineID: "model.sherpa")
        #expect(!variants.isEmpty)
        for variant in variants {
            #expect(variant.downloadURL == nil)
            #expect(!variant.files.isEmpty)
            // Names are joined onto a directory path, so they must stay bare file names.
            for file in variant.files {
                #expect(!file.name.contains("/"))
                #expect(file.sha256.count == 64)
                #expect(file.url.host == "huggingface.co")
            }
            // The loader needs a full transducer plus tokens.
            let names = variant.files.map(\.name)
            for prefix in ["encoder", "decoder", "joiner"] {
                #expect(names.contains { $0.hasPrefix(prefix) && $0.hasSuffix(".onnx") })
            }
            #expect(names.contains("tokens.txt"))
        }
    }

    @Test func onlyEnginesThatNeedTheAppsPauseHintUseTheVADBoundary() {
        #expect(ProviderCatalog.usesVADBoundary(engineID: "model.r2t2"))
        #expect(!ProviderCatalog.usesVADBoundary(engineID: "model.sherpa"))
        #expect(!ProviderCatalog.usesVADBoundary(engineID: "system.speech"))
    }

    @Test func sourceLanguageSupportFollowsTheEngine() {
        // Sherpa: Mandarin + English, and "auto" (it detects between them).
        #expect(!ProviderCatalog.isUnsupportedSource("zh-CN", engineID: "model.sherpa"))
        #expect(!ProviderCatalog.isUnsupportedSource("en-US", engineID: "model.sherpa"))
        #expect(!ProviderCatalog.isUnsupportedSource(nil, engineID: "model.sherpa"))
        #expect(ProviderCatalog.isUnsupportedSource("ja-JP", engineID: "model.sherpa"))
        #expect(ProviderCatalog.isUnsupportedSource("zh-TW", engineID: "model.sherpa"))
        #expect(ProviderCatalog.isUnsupportedSource("yue-CN", engineID: "model.sherpa"))
        #expect(ProviderCatalog.sourceLanguageOptions(forEngineID: "model.sherpa").map(\.code) == ["zh-CN", "en-US"])
        // System: the existing rule — no "auto", a few catalog languages out.
        #expect(ProviderCatalog.isUnsupportedSource(nil, engineID: "system.speech"))
        #expect(ProviderCatalog.isUnsupportedSource("ru-RU", engineID: "system.speech"))
        #expect(!ProviderCatalog.isUnsupportedSource("ja-JP", engineID: "system.speech"))
        // R2T2: no restriction of its own.
        #expect(!ProviderCatalog.isUnsupportedSource("ru-RU", engineID: "model.r2t2"))
        #expect(ProviderCatalog.sourceLanguageOptions(forEngineID: "model.r2t2") == LanguageCatalog.common)
    }

    @Test @MainActor func dictationLeavesAnUnsupportedLanguageToTheSherpaEnginesOwnDetection() {
        typealias Session = RecordingSession
        #expect(Session.resolveDictationLanguage(
            choice: .mine, mine: "ja-JP", foreign: "en-US", isModelEngine: true, engineID: "model.sherpa") == nil)
        #expect(Session.resolveDictationLanguage(
            choice: .foreign, mine: "ja-JP", foreign: "en-US", isModelEngine: true, engineID: "model.sherpa") == "en-US")
        #expect(Session.resolveDictationLanguage(
            choice: .mine, mine: "ja-JP", foreign: "en-US", isModelEngine: true, engineID: "model.r2t2") == "ja-JP")
    }
}
