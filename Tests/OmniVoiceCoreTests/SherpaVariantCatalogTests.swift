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
}
