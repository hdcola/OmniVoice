import Testing
@testable import OmniVoiceCore

@Suite("WhatsNewCatalog")
struct WhatsNewTests {
    private let entries = [
        WhatsNewEntry(revision: 1, title: "A", bullets: []),
        WhatsNewEntry(revision: 2, title: "B", bullets: []),
        WhatsNewEntry(revision: 2, title: "C", bullets: []),
        WhatsNewEntry(revision: 3, title: "D", bullets: []),
    ]

    @Test("a first run shows nothing — the wizard covers it")
    func firstRun() {
        let shown = WhatsNewCatalog.entriesToShow(hasCompletedOnboarding: false, lastSeenRevision: nil, in: entries)
        #expect(shown.isEmpty)
    }

    @Test("a user who updated from before this screen existed sees everything")
    func neverSeen() {
        let shown = WhatsNewCatalog.entriesToShow(hasCompletedOnboarding: true, lastSeenRevision: nil, in: entries)
        #expect(shown.map(\.title) == ["D", "B", "C", "A"])
    }

    @Test("only entries newer than the last seen revision show, newest first")
    func onlyNewer() {
        let shown = WhatsNewCatalog.entriesToShow(hasCompletedOnboarding: true, lastSeenRevision: 2, in: entries)
        #expect(shown.map(\.title) == ["D"])
    }

    @Test("nothing shows once the latest revision has been seen")
    func upToDate() {
        let shown = WhatsNewCatalog.entriesToShow(hasCompletedOnboarding: true, lastSeenRevision: 3, in: entries)
        #expect(shown.isEmpty)
    }

    @Test("the latest revision is the highest entry revision")
    func latest() {
        #expect(WhatsNewCatalog.latestRevision == WhatsNewCatalog.entries.map(\.revision).max())
        #expect(WhatsNewCatalog.latestRevision >= 1)
    }
}
