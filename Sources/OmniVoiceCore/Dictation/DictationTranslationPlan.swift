import Foundation

/// Whether, and into what, a finished dictation is translated before it is
/// typed — the "外语" the user set up for translation, shared with the
/// recording and the selection panel.
public enum DictationTranslationPlan {
    /// The language to translate `text` into, or nil to type it as spoken:
    /// what was said is already in the foreign language.
    ///
    /// - Parameter spokenCode: the language the recognizer was set to; nil
    ///   when it detected the language itself, in which case the text says.
    public static func targetCode(
        spokenCode: String?, text: String, myLanguageCode: String, foreignLanguageCode: String
    ) -> String? {
        let spoken = spokenCode ?? SelectionLanguageDirection.detectLanguageCode(
            of: text, myLanguageCode: myLanguageCode, foreignLanguageCode: foreignLanguageCode
        )
        if let spoken, SelectionLanguageDirection.isSameLanguage(spoken, foreignLanguageCode) { return nil }
        return foreignLanguageCode
    }
}
