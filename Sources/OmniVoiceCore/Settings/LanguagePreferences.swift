import Combine
import Foundation

/// Which side of the transcript the user is on: hearing a foreign language
/// translated into their own, or speaking their own translated into a
/// foreign one. The panel's ⇄ button flips this.
public enum TranscriptionDirection: String, Sendable {
    /// Source = foreign language, target = my language.
    case listenForeign
    /// Source = my language, target = foreign language.
    case speakMine
}

/// Which language voice input (dictation) recognizes.
public enum DictationLanguageChoice: String, Sendable {
    case mine
    case foreign
    /// Let an on-device model detect it. Only meaningful with a `.model`
    /// transcription engine — `RecordingSession.dictationLanguageCode`
    /// falls back to `mine` otherwise.
    case auto
}

/// The four values the pre-0.7 settings kept in two places (recording's
/// source/target, selection translation's my/foreign), reduced to what
/// `LanguageSettingsMigration` needs.
struct LegacyLanguageSettings: Equatable {
    /// Recording's source language; nil = "自动".
    var source: String?
    var target: String
    /// Selection translation's languages, nil when never set (or no longer
    /// in `LanguageCatalog`).
    var quickMine: String?
    var quickForeign: String?
    var isModelEngine: Bool
}

struct MigratedLanguageSettings: Equatable {
    var mine: String
    var foreign: String
    var direction: TranscriptionDirection
    var foreignAutoDetect: Bool
    var dictation: DictationLanguageChoice
}

/// Pure mapping from the old settings to the unified "my language /
/// foreign language" model — see `LanguagePreferences`.
enum LanguageSettingsMigration {
    static let defaultMine = "zh-CN"
    static let defaultForeign = "en-US"

    static func migrate(_ legacy: LegacyLanguageSettings) -> MigratedLanguageSettings {
        let quickMine = legacy.quickMine ?? defaultMine
        let quickForeign = legacy.quickForeign ?? defaultForeign
        // Selection translation is the only place the user ever said which
        // language is "theirs", so a customized pair wins; otherwise infer
        // from the recording's target (what they read) and source (what
        // they hear).
        let customized = (legacy.quickMine != nil || legacy.quickForeign != nil)
            && !(quickMine == defaultMine && quickForeign == defaultForeign)

        var mine: String
        var foreign: String
        if customized {
            mine = quickMine
            foreign = quickForeign
        } else {
            mine = legacy.target
            foreign = legacy.source ?? defaultForeign
        }
        if SelectionLanguageDirection.isSameLanguage(foreign, mine) {
            foreign = distinctForeign(from: mine, preferring: quickForeign)
        }

        let direction: TranscriptionDirection
        if let source = legacy.source,
           SelectionLanguageDirection.isSameLanguage(source, mine),
           !SelectionLanguageDirection.isSameLanguage(source, foreign) {
            direction = .speakMine
        } else {
            direction = .listenForeign
        }

        let dictation: DictationLanguageChoice
        if let source = legacy.source {
            dictation = SelectionLanguageDirection.isSameLanguage(source, mine)
                && !SelectionLanguageDirection.isSameLanguage(source, foreign) ? .mine : .foreign
        } else {
            dictation = legacy.isModelEngine ? .auto : .mine
        }

        return MigratedLanguageSettings(
            mine: mine, foreign: foreign, direction: direction,
            foreignAutoDetect: legacy.source == nil, dictation: dictation
        )
    }

    private static func distinctForeign(from mine: String, preferring preferred: String) -> String {
        if !SelectionLanguageDirection.isSameLanguage(preferred, mine) { return preferred }
        return SelectionLanguageDirection.isSameLanguage(mine, defaultForeign) ? defaultMine : defaultForeign
    }
}

enum PersistedLanguageKey {
    static let schemaVersion = "org.hdcola.omnivoice.settingsSchemaVersion"
    static let myLanguageCode = "org.hdcola.omnivoice.myLanguageCode"
    static let foreignLanguageCode = "org.hdcola.omnivoice.foreignLanguageCode"
    static let transcriptionDirection = "org.hdcola.omnivoice.transcriptionDirection"
    static let foreignLanguageAutoDetect = "org.hdcola.omnivoice.foreignLanguageAutoDetect"
    static let dictationLanguage = "org.hdcola.omnivoice.dictationLanguage"
}

/// The one place the user's languages live: "我的语言" and "外语", plus
/// which way the transcript runs and which language voice input uses.
/// Recording (source/target), selection translation (my/foreign) and
/// dictation all read from here.
///
/// Codes are full BCP-47-ish locales (`zh-CN`, `en-US`); comparing "same
/// language" is coarsened on demand by `SelectionLanguageDirection.isSameLanguage`.
@MainActor
public final class LanguagePreferences: ObservableObject {
    static let currentSchemaVersion = 2

    @Published public var myLanguageCode: String {
        didSet { defaults.set(myLanguageCode, forKey: PersistedLanguageKey.myLanguageCode) }
    }
    @Published public var foreignLanguageCode: String {
        didSet { defaults.set(foreignLanguageCode, forKey: PersistedLanguageKey.foreignLanguageCode) }
    }
    @Published public var transcriptionDirection: TranscriptionDirection {
        didSet { defaults.set(transcriptionDirection.rawValue, forKey: PersistedLanguageKey.transcriptionDirection) }
    }
    /// The foreign side is "auto-detect" (source nil while listening to a
    /// foreign language). Only on-device models can do that — see
    /// `RecordingSession.sourceLanguageCode`.
    @Published public var foreignLanguageAutoDetect: Bool {
        didSet { defaults.set(foreignLanguageAutoDetect, forKey: PersistedLanguageKey.foreignLanguageAutoDetect) }
    }
    @Published public var dictationLanguage: DictationLanguageChoice {
        didSet { defaults.set(dictationLanguage.rawValue, forKey: PersistedLanguageKey.dictationLanguage) }
    }

    private let defaults: UserDefaults

    /// Restores the persisted preferences, or — the first launch after the
    /// unification — migrates them from the old keys (which stay in place
    /// for one release, untouched).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let restored = Self.restore(from: defaults)
        let settings = restored ?? LanguageSettingsMigration.migrate(Self.readLegacy(from: defaults))
        myLanguageCode = settings.mine
        foreignLanguageCode = settings.foreign
        transcriptionDirection = settings.direction
        foreignLanguageAutoDetect = settings.foreignAutoDetect
        dictationLanguage = settings.dictation
        if restored == nil {
            defaults.set(settings.mine, forKey: PersistedLanguageKey.myLanguageCode)
            defaults.set(settings.foreign, forKey: PersistedLanguageKey.foreignLanguageCode)
            defaults.set(settings.direction.rawValue, forKey: PersistedLanguageKey.transcriptionDirection)
            defaults.set(settings.foreignAutoDetect, forKey: PersistedLanguageKey.foreignLanguageAutoDetect)
            defaults.set(settings.dictation.rawValue, forKey: PersistedLanguageKey.dictationLanguage)
            defaults.set(Self.currentSchemaVersion, forKey: PersistedLanguageKey.schemaVersion)
        }
    }

    // MARK: Recording's view of the languages

    /// What the recognizer listens for — nil means "自动" (only reachable
    /// while listening to a foreign language).
    public var sourceLanguageCode: String? {
        get {
            switch transcriptionDirection {
            case .listenForeign: return foreignLanguageAutoDetect ? nil : foreignLanguageCode
            case .speakMine: return myLanguageCode
            }
        }
        set {
            switch transcriptionDirection {
            case .listenForeign:
                if let newValue {
                    foreignLanguageCode = newValue
                    foreignLanguageAutoDetect = false
                } else {
                    foreignLanguageAutoDetect = true
                }
            case .speakMine:
                // There is no "auto" for the user's own language — a nil is
                // ignored rather than silently flipping the direction.
                if let newValue { myLanguageCode = newValue }
            }
        }
    }

    /// What the transcript is translated into.
    public var targetLanguageCode: String {
        get { Self.targetCode(mine: myLanguageCode, foreign: foreignLanguageCode, direction: transcriptionDirection) }
        set {
            switch transcriptionDirection {
            case .listenForeign: myLanguageCode = newValue
            case .speakMine: foreignLanguageCode = newValue
            }
        }
    }

    /// False while the source is "自动": swapping would make the target "自动".
    public var canSwapDirection: Bool { sourceLanguageCode != nil }

    /// Flips source and target. No-op unless `canSwapDirection`.
    public func swapDirection() {
        guard canSwapDirection else { return }
        transcriptionDirection = transcriptionDirection == .listenForeign ? .speakMine : .listenForeign
    }

    static func targetCode(mine: String, foreign: String, direction: TranscriptionDirection) -> String {
        direction == .listenForeign ? mine : foreign
    }

    static func sourceCode(
        mine: String, foreign: String, direction: TranscriptionDirection, foreignAutoDetect: Bool
    ) -> String? {
        switch direction {
        case .listenForeign: return foreignAutoDetect ? nil : foreign
        case .speakMine: return mine
        }
    }

    // MARK: Persistence

    private static func restore(from defaults: UserDefaults) -> MigratedLanguageSettings? {
        guard defaults.integer(forKey: PersistedLanguageKey.schemaVersion) >= currentSchemaVersion else { return nil }
        func code(_ key: String, fallback: String) -> String {
            let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? fallback : value
        }
        return MigratedLanguageSettings(
            mine: code(PersistedLanguageKey.myLanguageCode, fallback: LanguageSettingsMigration.defaultMine),
            foreign: code(PersistedLanguageKey.foreignLanguageCode, fallback: LanguageSettingsMigration.defaultForeign),
            direction: defaults.string(forKey: PersistedLanguageKey.transcriptionDirection)
                .flatMap(TranscriptionDirection.init(rawValue:)) ?? .listenForeign,
            foreignAutoDetect: defaults.bool(forKey: PersistedLanguageKey.foreignLanguageAutoDetect),
            dictation: defaults.string(forKey: PersistedLanguageKey.dictationLanguage)
                .flatMap(DictationLanguageChoice.init(rawValue:)) ?? .mine
        )
    }

    private static func readLegacy(from defaults: UserDefaults) -> LegacyLanguageSettings {
        func trimmed(_ key: String) -> String? {
            defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func inCatalog(_ code: String?) -> String? {
            LanguageCatalog.common.contains { $0.code == code } ? code : nil
        }
        // Never stored = the old default; stored "" = "自动".
        let source: String?
        if let stored = trimmed(PersistedSettingsKey.sourceLanguageCode) {
            source = stored.isEmpty ? nil : stored
        } else {
            source = LanguageSettingsMigration.defaultForeign
        }
        let storedTarget = trimmed(PersistedSettingsKey.targetLanguageCode) ?? ""
        let engineID = defaults.string(forKey: PersistedSettingsKey.transcriptionEngineID)
        return LegacyLanguageSettings(
            source: source,
            target: storedTarget.isEmpty ? LanguageSettingsMigration.defaultMine : storedTarget,
            quickMine: inCatalog(defaults.string(forKey: PersistedSelectionKey.myLanguageCode)),
            quickForeign: inCatalog(defaults.string(forKey: PersistedSelectionKey.foreignLanguageCode)),
            isModelEngine: ProviderCatalog.transcriptionEngines.first { $0.id == engineID }?.kind == .model
        )
    }
}
