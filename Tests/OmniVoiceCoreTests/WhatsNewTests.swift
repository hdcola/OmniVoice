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

    @Test("the full list holds every catalog entry, newest first")
    func allEntries() {
        let all = WhatsNewCatalog.allEntriesNewestFirst
        #expect(all.count == WhatsNewCatalog.entries.count)
        #expect(all.map(\.revision) == all.map(\.revision).sorted(by: >))
    }

    @Test("the latest revision is the highest entry revision")
    func latest() {
        #expect(WhatsNewCatalog.latestRevision == WhatsNewCatalog.entries.map(\.revision).max())
        #expect(WhatsNewCatalog.latestRevision >= 1)
    }

    @Test("someone who saw revision 1 is shown the speech and Return-to-send notes, then the voice input note")
    func voiceInputIsNewForRevisionOneUsers() {
        let shown = WhatsNewCatalog.entriesToShow(hasCompletedOnboarding: true, lastSeenRevision: 1)
        #expect(shown.map(\.action) == [nil, nil, .enableDictation])
    }

    @Test("someone who saw revision 2 is shown the translation-speech note, then the Return-to-send note")
    func returnToSendIsNewForRevisionTwoUsers() {
        let shown = WhatsNewCatalog.entriesToShow(hasCompletedOnboarding: true, lastSeenRevision: 2)
        #expect(shown.map(\.revision) == [4, 3])
    }

    @Test("someone who saw revision 3 is shown just the translation-speech note")
    func translationSpeechIsNewForRevisionThreeUsers() {
        let shown = WhatsNewCatalog.entriesToShow(hasCompletedOnboarding: true, lastSeenRevision: 3)
        #expect(shown.map(\.title) == ["翻译朗读"])
    }
}
