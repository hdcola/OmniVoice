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
            revision: 5,
            title: "语音输入：翻译后再输入",
            bullets: [
                "在「按一下开始，再按一下结束」的触发方式下，可以把你说的话先翻译成外语再输入：说完先在气泡里看译文，Return 输入并发送，触发键只输入，Esc 放弃，也可以点「输入原文」。",
                "听写时点气泡上的「译成…」按钮就能随时开关；翻译用「划词与截图翻译」里选的引擎，目标语言是你的「外语」。长内容时气泡会随内容变高。",
            ]
        ),
        WhatsNewEntry(
            revision: 4,
            title: "翻译朗读",
            bullets: [
                "翻译面板里，原文和译文旁边各有一个 ▶ 按钮，点一下用 macOS 系统语音朗读，再点一下停止，方便听发音、核对译文。",
                "在「设置 › 通用 › 划词与截图翻译」里可以让译文翻译完成后自动朗读，并调节语速；想要更自然的声音或更多语言，可在系统设置的辅助功能里（「系统语音」旁的菜单）下载语音。",
            ]
        ),
        WhatsNewEntry(
            revision: 3,
            title: "语音输入：按 Return 结束并发送",
            bullets: [
                "在「按一下开始，再按一下结束」的触发方式下，说完直接按 Return：文字输入后自动回车，聊天消息、提示词一步发出；按触发键结束则只输入文字，不回车。",
                "在「设置 › 通用 › 语音输入」里把触发方式设为按一下开始即可使用。",
            ]
        ),
        WhatsNewEntry(
            revision: 2,
            title: "语音输入（可选）",
            bullets: [
                "在任何应用里按住右 ⌥ Option 说话，松开后文字自动输入到光标处；也可以改成按一下开始、再按一下结束，按 Esc 取消。",
                "默认关闭。开启后需要「输入监控」「辅助功能」和麦克风权限；实时转录用本地模型且已加载时，会直接复用它。",
            ],
            actionTitle: "开启",
            action: .enableDictation
        ),
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
