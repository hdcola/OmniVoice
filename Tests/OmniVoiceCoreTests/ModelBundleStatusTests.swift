import Testing
@testable import OmniVoiceCore

/// Round-4 user report (`ModelManagementView.bundleCard(for:)`'s "推荐方案快速
/// 配置" cards) — pins the exact scenario reported: R2T2 (Q8_0) downloaded,
/// T3PO (Q5_K_M) not. Audits `ModelBundle.status(isDownloaded:)` against the
/// four points that report asked for: (1) counts only the bundle's own
/// `variantIDs`, never a sibling quantization/other variant of the same
/// engine family; (2) `remainingVariants`/`remainingSizeMB` cover only what
/// that bundle itself is still missing; (3) a fully-downloaded bundle reports
/// `isFullyDownloaded == true`; (4) each bundle's variant count matches its
/// `variantIDs.count` exactly (no duplicate/ambiguous counting).
struct ModelBundleStatusTests {
    private func isDownloaded(_ downloadedIDs: Set<String>) -> (ModelVariant) -> Bool {
        { downloadedIDs.contains($0.id) }
    }

    @Test func standardRealtimeBundleCountsOnlyItsOwnTwoVariants() throws {
        let bundle = try #require(ProviderCatalog.bundles.first { $0.id == "bundle.standard-realtime" })
        // The reported scenario: R2T2 Q8_0 downloaded, T3PO Q5_K_M isn't.
        let status = bundle.status(isDownloaded: isDownloaded(["r2t2-q8_0"]))

        #expect(status.variants.count == 2)
        #expect(status.downloadedVariants.map(\.id) == ["r2t2-q8_0"])
        #expect(status.remainingVariants.map(\.id) == ["t3po-q5_k_m"])
        #expect(status.remainingSizeMB == 10021)
        #expect(!status.isFullyDownloaded)
    }

    /// This is the report's actual discrepancy: with only R2T2 downloaded
    /// (HY-MT1.5 not), 方案B must *not* read as fully downloaded either —
    /// sharing `r2t2-q8_0` with 方案A only ever counts that one shared
    /// variant, never implicitly marks the other bundle's distinct
    /// HY-MT1.5 variant as done too.
    @Test func lightweightBundleDoesNotFalselyReportCompleteFromASharedVariantAlone() throws {
        let bundle = try #require(ProviderCatalog.bundles.first { $0.id == "bundle.lightweight" })
        let status = bundle.status(isDownloaded: isDownloaded(["r2t2-q8_0"]))

        #expect(status.variants.count == 2)
        #expect(status.downloadedVariants.map(\.id) == ["r2t2-q8_0"])
        #expect(status.remainingVariants.map(\.id) == ["hymt15-1.8b-q4_k_m"])
        #expect(status.remainingSizeMB == 1080)
        #expect(!status.isFullyDownloaded)
    }

    @Test func lightweightBundleReportsCompleteOnlyOnceBothItsOwnVariantsAreDownloaded() throws {
        let bundle = try #require(ProviderCatalog.bundles.first { $0.id == "bundle.lightweight" })
        let status = bundle.status(isDownloaded: isDownloaded(["r2t2-q8_0", "hymt15-1.8b-q4_k_m"]))

        #expect(status.remainingVariants.isEmpty)
        #expect(status.remainingSizeMB == 0)
        #expect(status.isFullyDownloaded)
    }

    /// A sibling quantization of a bundle member being downloaded (e.g. the
    /// HY-MT1.5 Q8_0 variant, not the Q4_K_M `bundle.lightweight` actually
    /// names) must never count toward that bundle — otherwise the family
    /// itself, not the exact variant the bundle promised to install, would
    /// silently decide the bundle's status.
    @Test func aSiblingQuantizationNeverCountsTowardABundleThatNamesADifferentOne() throws {
        let bundle = try #require(ProviderCatalog.bundles.first { $0.id == "bundle.lightweight" })
        let status = bundle.status(isDownloaded: isDownloaded(["r2t2-q8_0", "hymt15-1.8b-q8_0"]))

        #expect(status.downloadedVariants.map(\.id) == ["r2t2-q8_0"])
        #expect(status.remainingVariants.map(\.id) == ["hymt15-1.8b-q4_k_m"])
        #expect(!status.isFullyDownloaded)
    }

    @Test func everyBundlesVariantCountMatchesItsVariantIDsExactlyWithNoDuplicates() {
        for bundle in ProviderCatalog.bundles {
            let status = bundle.status(isDownloaded: isDownloaded([]))
            #expect(status.variants.count == bundle.variantIDs.count)
            #expect(Set(status.variants.map(\.id)).count == bundle.variantIDs.count)
        }
    }
}
