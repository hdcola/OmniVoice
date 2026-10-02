import Testing
@testable import OmniVoiceCore

/// R2T2 ships in three user-selectable precisions. The first catalog entry
/// is what `RecordingSession.resolveModelVariant` falls back to, so it must
/// stay Q8_0 — and the recommended bundles must keep naming exactly Q8_0
/// rather than picking up the new entries.
struct R2T2VariantCatalogTests {
    @Test func r2t2OffersQ4Q8AndF16WithQ8AsDefault() {
        let ids = ProviderCatalog.modelVariants(forEngineID: "model.r2t2").map(\.id)
        #expect(ids == ["r2t2-q8_0", "r2t2-q4_k_m", "r2t2-f16"])
    }

    @Test func r2t2VariantsHaveVerifiableDownloads() {
        for variant in ProviderCatalog.modelVariants(forEngineID: "model.r2t2") {
            #expect(variant.sha256?.count == 64, "\(variant.id) needs a SHA-256")
            #expect(variant.downloadURL?.host == "huggingface.co")
            #expect(variant.downloadURL?.lastPathComponent.hasSuffix(".gguf") == true)
        }
    }

    @Test func r2t2VariantsGrowWithPrecision() throws {
        let q4 = try #require(ProviderCatalog.variant(forID: "r2t2-q4_k_m"))
        let q8 = try #require(ProviderCatalog.variant(forID: "r2t2-q8_0"))
        let f16 = try #require(ProviderCatalog.variant(forID: "r2t2-f16"))
        #expect(q4.approximateSizeMB < q8.approximateSizeMB)
        #expect(q8.approximateSizeMB < f16.approximateSizeMB)
        #expect(q4.recommendedMemoryGB <= q8.recommendedMemoryGB)
        #expect(q8.recommendedMemoryGB <= f16.recommendedMemoryGB)
    }

    @Test func bundlesStillPinR2T2ToQ8() {
        for bundle in ProviderCatalog.bundles {
            let r2t2 = bundle.variantIDs.filter { $0.hasPrefix("r2t2-") }
            #expect(r2t2 == ["r2t2-q8_0"], "\(bundle.id)")
        }
    }

    @Test func companionSuggestionOffersDefaultR2T2OnlyWhenNoVariantIsDownloaded() {
        let none = ProviderCatalog.companionSuggestion(forEngineID: "model.r2t2") { _ in false }
        #expect(none?.id == "r2t2-q8_0")
    }

    @Test func companionSuggestionIsSuppressedByAnyDownloadedR2T2Variant() {
        for id in ["r2t2-q8_0", "r2t2-q4_k_m", "r2t2-f16"] {
            let suggestion = ProviderCatalog.companionSuggestion(forEngineID: "model.r2t2") { $0.id == id }
            #expect(suggestion == nil, "\(id) already covers R2T2")
        }
    }

    @Test func replacementVariantIsNilWhenTheResolvedVariantIsDownloaded() {
        let r = ProviderCatalog.replacementVariantID(
            forEngineID: "model.r2t2", selectedID: "r2t2-q4_k_m"
        ) { $0.id == "r2t2-q4_k_m" || $0.id == "r2t2-q8_0" }
        #expect(r == nil)
    }

    @Test func replacementVariantIsTheFirstDownloadedOneWhenTheSelectedOneIsMissing() {
        let r = ProviderCatalog.replacementVariantID(
            forEngineID: "model.r2t2", selectedID: "r2t2-q4_k_m"
        ) { $0.id == "r2t2-q8_0" || $0.id == "r2t2-f16" }
        #expect(r == "r2t2-q8_0", "catalog order, so Q8_0 beats F16")
    }

    @Test func replacementVariantTreatsAnUnsetSelectionAsTheDefaultVariant() {
        let r = ProviderCatalog.replacementVariantID(
            forEngineID: "model.r2t2", selectedID: nil
        ) { $0.id == "r2t2-q4_k_m" }
        #expect(r == "r2t2-q4_k_m", "unset resolves to Q8_0, which isn't downloaded")
    }

    @Test func replacementVariantIsNilWhenNothingIsDownloaded() {
        let r = ProviderCatalog.replacementVariantID(
            forEngineID: "model.r2t2", selectedID: "r2t2-q4_k_m"
        ) { _ in false }
        #expect(r == nil, "engine-level fallback to .system handles this, and a pending pick keeps its selection")
    }
}
