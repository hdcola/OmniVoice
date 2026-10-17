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
            // The loader recognizes the kind from the files: transducer
            // (encoder+decoder+joiner), Paraformer (encoder+decoder) or CTC
            // (one model file), always with tokens.
            let names = variant.files.map(\.name)
            func has(_ prefix: String) -> Bool { names.contains { $0.hasPrefix(prefix) && $0.hasSuffix(".onnx") } }
            #expect((has("encoder") && has("decoder")) || has("model"), "\(variant.id) has no recognizable model layout")
            #expect(names.contains("tokens.txt"))
            #expect(variant.approximateSizeMB > 0)
            #expect((variant.memoryMB ?? 0) > 0, "\(variant.id) needs a measured memory figure")
            // Every language it claims must be one the pickers can show.
            let codes = try #require(variant.sourceLanguageCodes)
            #expect(!codes.isEmpty)
            for code in codes {
                #expect(LanguageCatalog.common.contains { $0.code == code }, "\(code) is not in LanguageCatalog")
            }
        }
    }

    @Test func variantIDsAreUniqueAndTheDefaultIsTheBilingualModel() {
        let ids = ProviderCatalog.modelVariants(forEngineID: "model.sherpa").map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.first == "sherpa-zipformer-bilingual-zh-en")
        #expect(ids.count >= 9)
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
        // The languages follow the selected model, not just the engine.
        func options(_ variantID: String) -> [String] {
            ProviderCatalog.sourceLanguageOptions(forEngineID: "model.sherpa", variantID: variantID).map(\.code)
        }
        #expect(options("sherpa-zipformer-zh-2025") == ["zh-CN"])
        #expect(options("sherpa-paraformer-trilingual-zh-yue-en") == ["zh-CN", "yue-CN", "en-US"])
        #expect(options("sherpa-zipformer-multilingual-8").contains("ja-JP"))
        #expect(ProviderCatalog.isUnsupportedSource("en-US", engineID: "model.sherpa", variantID: "sherpa-zipformer-zh-2025"))
        // A stale variant ID falls back to the engine's first one.
        #expect(options("not-a-variant") == ["zh-CN", "en-US"])
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
