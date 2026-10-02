import Foundation

/// One highlight of a release that is worth telling existing users about —
/// something they have to opt into, or a permission/setting that changed.
/// Plain fixes and tweaks don't belong here (they go in `CHANGELOG.md` only).
public struct WhatsNewEntry: Equatable, Sendable, Identifiable {
    /// What the entry's button does; the app maps each case to a real action.
    public enum Action: Equatable, Sendable {
        case enableDoubleCopyTranslate
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
            revision: 1,
            title: "连按两次 ⌘C 翻译（可选）",
            bullets: [
                "在其他应用里选中文字后，快速按两下 ⌘C，直接翻译刚复制的内容；网页等 ⌥A 读不到选区的地方也能用。",
                "默认关闭。开启后需要「输入监控」权限，只检测这个组合，不记录其他按键。",
            ],
            actionTitle: "开启",
            action: .enableDoubleCopyTranslate
        ),
        WhatsNewEntry(
            revision: 1,
            title: "可以重新运行新手引导",
            bullets: [
                "在「设置 › 通用 › 新手引导」里点「重新运行」，随时回头调整权限和运行模式。",
            ],
            actionTitle: "重新运行",
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
