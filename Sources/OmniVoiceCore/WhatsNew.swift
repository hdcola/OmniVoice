import Foundation

/// One highlight of a release that is worth telling existing users about —
/// something they have to opt into, or a permission/setting that changed.
/// Plain fixes and tweaks don't belong here (they go in `CHANGELOG.md` only).
public struct WhatsNewEntry: Equatable, Sendable, Identifiable {
    /// What the entry's button does; the app maps each case to a real action.
    public enum Action: Equatable, Sendable {
        case enableDoubleCopyTranslate
        case enableDictation
        case rerunOnboarding
    }

    /// The `WhatsNewCatalog.latestRevision` value that first included this
    /// entry. A user who has seen revision N is shown entries above N.
    public let revision: Int
    public let title: String
    public let bullets: [String]
    public let actionTitle: String?
    public let action: Action?

    public var id: String { title }

    public init(revision: Int, title: String, bullets: [String], actionTitle: String? = nil, action: Action? = nil) {
        self.revision = revision
        self.title = title
        self.bullets = bullets
        self.actionTitle = actionTitle
        self.action = action
    }
}

/// The "what's new" notes shown once after an update. Bump an entry's
/// `revision` (one higher than the current `latestRevision`) only for
/// something users should hear about; releases without a new entry show
/// nothing.
public enum WhatsNewCatalog {
    public static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(
            revision: 7,
            title: String(localized: "Dictation: automatically pause music and video"),
            bullets: [
                String(localized: "When you start speaking, music that is playing (such as Music) or video in your browser (such as YouTube) pauses automatically, and resumes once your text has been entered, so the audio isn't recorded. It only resumes what it paused itself."),
                String(localized: "On by default; you can turn it off in “Settings › Dictation”. Requires “Accessibility” permission. If several players are playing at once, only the current one is paused."),
            ]
        ),
        WhatsNewEntry(
            revision: 6,
            title: String(localized: "Dictation: polish recognized text (optional)"),
            bullets: [
                String(localized: "When on, what you said is first handed to an LLM you configure yourself (an OpenAI-compatible API, or Ollama on this Mac) to add punctuation, remove filler words, and tidy lists before it is entered. The recognized text is sent to that service. Off by default."),
                String(localized: "Enter the service, model, and API key (stored in the Keychain) in “Settings › Dictation”, choose one of four styles (Keep original, Clean, Structured, Professional), and adjust the timeout. If it fails, times out, or the result looks unreliable, your original text is entered; pressing Esc while polishing also enters the original text. When translation is on too, text is polished first and then translated."),
            ]
        ),
        WhatsNewEntry(
            revision: 5,
            title: String(localized: "Dictation: translate before entering"),
            bullets: [
                String(localized: "With the “press once to start, press again to stop” trigger, what you say can be translated into a foreign language before it is entered: review the translation in the bubble, then press Return to enter and send, press the trigger key to only enter, press Esc to discard, or click “Type Original”."),
                String(localized: "Click the “Translate to…” button on the bubble while dictating to turn it on or off at any time. Translation uses the engine chosen under “Translate selection and screenshot”, and the target language is your “Foreign language”. The bubble grows taller for long text."),
            ]
        ),
        WhatsNewEntry(
            revision: 4,
            title: String(localized: "Read translations aloud"),
            bullets: [
                String(localized: "In the Translation panel, the source text and the translation each have a ▶ button: click it to read the text aloud with the macOS system voice, and click again to stop. Handy for hearing pronunciation and checking translations."),
                String(localized: "In “Settings › General › Translate selection and screenshot” you can have the translation read aloud automatically when it finishes, and adjust the speaking rate. For more natural voices or more languages, download voices in System Settings under Accessibility (the menu next to “System Voice”)."),
            ]
        ),
        WhatsNewEntry(
            revision: 3,
            title: String(localized: "Dictation: press Return to finish and send"),
            bullets: [
                String(localized: "With the “press once to start, press again to stop” trigger, press Return when you finish speaking: the text is entered and Return is pressed automatically, so chat messages and prompts go out in one step. Finishing with the trigger key only enters the text, without pressing Return."),
                String(localized: "Set the trigger to press-once-to-start in “Settings › Dictation” to use it."),
            ]
        ),
        WhatsNewEntry(
            revision: 2,
            title: String(localized: "Dictation (optional)"),
            bullets: [
                String(localized: "In any app, hold the right ⌥ Option key and speak; when you let go, the text is entered at the cursor. You can also switch to press once to start and press again to stop, and press Esc to cancel."),
                String(localized: "Off by default. Turning it on requires “Input Monitoring”, “Accessibility”, and Microphone permissions; if live transcription uses a local model that is already loaded, it is reused directly."),
            ],
            actionTitle: String(localized: "Turn On"),
            action: .enableDictation
        ),
        WhatsNewEntry(
            revision: 1,
            title: String(localized: "Double ⌘C translate (optional)"),
            bullets: [
                String(localized: "After selecting text in another app, press ⌘C twice quickly to translate what you just copied; it also works where ⌥A can't read the selection, such as web pages."),
                String(localized: "Off by default. Turning it on requires “Input Monitoring” permission; it only detects this combination and doesn't record other keys."),
            ],
            actionTitle: String(localized: "Turn On"),
            action: .enableDoubleCopyTranslate
        ),
        WhatsNewEntry(
            revision: 1,
            title: String(localized: "You can re-run onboarding"),
            bullets: [
                String(localized: "In “Settings › General › Onboarding”, click “Re-run” to revisit permissions and the run mode at any time."),
            ],
            actionTitle: String(localized: "Re-run"),
            action: .rerunOnboarding
        ),
    ]

    public static var latestRevision: Int {
        entries.map(\.revision).max() ?? 0
    }

    /// Every entry, newest first — what Settings' "查看新功能" shows.
    public static var allEntriesNewestFirst: [WhatsNewEntry] {
        entriesToShow(hasCompletedOnboarding: true, lastSeenRevision: 0)
    }

    /// Entries to show at launch, newest first.
    ///
    /// - Parameters:
    ///   - hasCompletedOnboarding: false on a first run, where the wizard
    ///     already introduces everything.
    ///   - lastSeenRevision: nil for a user who updated from a version that
    ///     predates this screen — they have seen none of it.
    public static func entriesToShow(
        hasCompletedOnboarding: Bool, lastSeenRevision: Int?,
        in entries: [WhatsNewEntry] = WhatsNewCatalog.entries
    ) -> [WhatsNewEntry] {
        guard hasCompletedOnboarding else { return [] }
        let seen = lastSeenRevision ?? 0
        return entries.filter { $0.revision > seen }.sorted { $0.revision > $1.revision }
    }
}
