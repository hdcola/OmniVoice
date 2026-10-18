import Testing
@testable import OmniVoiceCore

struct ModelSelectionPlanTests {
    private func plan(_ asr: String?, _ mt: String?) -> ModelSelectionPlan {
        ModelSelectionPlan(
            transcription: asr.flatMap(ProviderCatalog.variant(forID:)),
            translation: mt.flatMap(ProviderCatalog.variant(forID:))
        )
    }

    @Test func systemEnginesUseNoMemoryAndNeedNoDownload() {
        let p = plan(nil, nil)
        #expect(p.memoryMB == 0)
        #expect(!p.hasLocalModel)
        #expect(p.downloadMB { _ in false } == 0)
        #expect(p.pressure(physicalMemoryMB: 8 * 1024) == .comfortable)
    }

    @Test func memorySumsTheSelectedModels() throws {
        let asr = try #require(ProviderCatalog.variant(forID: "sherpa-paraformer-bilingual-zh-en"))
        let mt = try #require(ProviderCatalog.variant(forID: "hymt15-1.8b-q4_k_m"))
        let p = plan(asr.id, mt.id)
        #expect(p.memoryMB == asr.estimatedMemoryMB + mt.estimatedMemoryMB)
        #expect(p.memoryMB == 540 + 1500)
    }

    @Test func downloadCountsOnlyWhatIsMissing() throws {
        let p = plan("r2t2-q8_0", "t3po-q5_k_m")
        #expect(p.downloadMB { $0.id == "r2t2-q8_0" } == 10021)
        #expect(p.downloadMB { _ in true } == 0)
    }

    @Test func pressureFollowsTheShareOfPhysicalMemory() {
        let p = plan("r2t2-q8_0", "t3po-q5_k_m")  // 14.1 GB
        #expect(p.pressure(physicalMemoryMB: 64 * 1024) == .comfortable)
        #expect(p.pressure(physicalMemoryMB: 24 * 1024) == .tight)
        #expect(p.pressure(physicalMemoryMB: 16 * 1024) == .overcommitted)
    }

    @Test func everyVariantHasAMemoryFigure() {
        for variant in ProviderCatalog.modelVariants {
            #expect(variant.estimatedMemoryMB > 0, "\(variant.id)")
        }
    }

    @Test func estimatesAreFlaggedAndMeasurementsAreNot() throws {
        #expect(try #require(ProviderCatalog.variant(forID: "t3po-q5_k_m")).isMemoryEstimated)
        #expect(!(try #require(ProviderCatalog.variant(forID: "hymt15-1.8b-q4_k_m")).isMemoryEstimated))
        #expect(!(try #require(ProviderCatalog.variant(forID: "sherpa-zipformer-zh-14m")).isMemoryEstimated))
        #expect(plan("r2t2-q8_0", "t3po-q5_k_m").isMemoryEstimated)
        #expect(!plan("sherpa-zipformer-zh-14m", "hymt15-1.8b-q4_k_m").isMemoryEstimated)
    }

    @Test func notesWarnAboutLimitedLanguages() {
        #expect(plan("sherpa-paraformer-bilingual-zh-en", "t3po-q5_k_m").notes
            == plan("sherpa-paraformer-bilingual-zh-en", nil).notes)
        #expect(plan("sherpa-zipformer-zh-14m", nil).notes == [.limitedLanguages(["zh-CN"])])
        #expect(plan("r2t2-q8_0", nil).notes.isEmpty)
    }

    @Test func recommendationDependsOnPhysicalMemory() {
        #expect(ModelSelectionPlan.recommended(physicalMemoryMB: 16 * 1024).transcription?.id == "sherpa-paraformer-bilingual-zh-en")
        #expect(ModelSelectionPlan.recommended(physicalMemoryMB: 16 * 1024).translation?.id == "hymt15-1.8b-q4_k_m")
        #expect(ModelSelectionPlan.recommended(physicalMemoryMB: 32 * 1024).transcription?.id == "r2t2-q8_0")
        #expect(ModelSelectionPlan.recommended(physicalMemoryMB: 32 * 1024).translation?.id == "t3po-q5_k_m")
    }

    @Test func physicalMemoryReadsInBinaryGigabytes() {
        #expect(MemoryFormat.physicalText(mb: 16 * 1024) == "16 GB")
        #expect(MemoryFormat.physicalText(mb: 8 * 1024) == "8 GB")
        #expect(MemoryFormat.physicalText(mb: 512) == "512 MB")
        #expect(MemoryFormat.text(mb: 16 * 1024) == "16.4 GB")
    }
}
