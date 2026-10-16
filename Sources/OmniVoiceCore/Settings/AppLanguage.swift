import Foundation

/// The UI language the user picked in Settings → General → Interface language.
///
/// macOS already supports a per-app language: an `AppleLanguages` entry in the
/// app's own defaults domain makes the next launch resolve its `.lproj`
/// folders (and `Bundle.main.preferredLocalizations`) from it instead of the
/// system language. So switching is "write the entry, relaunch" — nothing in
/// the UI layer has to re-resolve strings at runtime.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// No override: follow the system language.
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    /// The languages the app ships `.lproj` folders for.
    public static let supportedCodes = ["en", "zh-Hans"]

    static let overrideKey = "AppleLanguages"

    /// The language this process resolved at launch. Captured once (touch it
    /// early) so a later override write doesn't change what "running" means.
    public static let runningCode: String =
        Bundle.main.preferredLocalizations.first(where: supportedCodes.contains) ?? "en"

    /// The override currently stored for the app, `.system` when there is none
    /// (or it names a language we have no translation for).
    public static func stored(
        defaults: UserDefaults = .standard,
        domain: String? = Bundle.main.bundleIdentifier
    ) -> AppLanguage {
        let languages = domain.flatMap { defaults.persistentDomain(forName: $0)?[overrideKey] as? [String] }
        guard let first = languages?.first else { return .system }
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    /// Stores `language` as the override; `.system` removes it.
    public static func store(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        if language == .system {
            defaults.removeObject(forKey: overrideKey)
        } else {
            defaults.set([language.rawValue], forKey: overrideKey)
        }
    }

    /// The `.lproj` code this choice resolves to on next launch.
    public func resolvedCode(systemPreferred: [String] = AppLanguage.systemPreferredLanguages()) -> String {
        if self != .system { return rawValue }
        return Bundle.preferredLocalizations(from: Self.supportedCodes, forPreferences: systemPreferred).first ?? "en"
    }

    /// The user's system-wide language list, ignoring this app's own override.
    public static func systemPreferredLanguages() -> [String] {
        let value = CFPreferencesCopyValue(
            overrideKey as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? [String]) ?? ["en"]
    }

    /// Whether the stored choice differs from what this process is showing.
    public static func needsRestart(
        stored: AppLanguage = AppLanguage.stored(),
        running: String = AppLanguage.runningCode,
        systemPreferred: [String] = AppLanguage.systemPreferredLanguages()
    ) -> Bool {
        stored.resolvedCode(systemPreferred: systemPreferred) != running
    }
}
