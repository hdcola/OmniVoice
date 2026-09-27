import Testing
@testable import OmniVoiceCore

@Suite struct ModelLanguageMappingTests {
    @Test func recognitionLanguageMapsKnownPrefixesRegardlessOfRegion() {
        #expect(ModelLanguageMapping.recognitionLanguage(forCode: "zh-CN").requestValue == "Chinese")
        #expect(ModelLanguageMapping.recognitionLanguage(forCode: "zh-TW").requestValue == "Chinese")
        #expect(ModelLanguageMapping.recognitionLanguage(forCode: "yue-CN").requestValue == "Chinese")
        #expect(ModelLanguageMapping.recognitionLanguage(forCode: "en-US").requestValue == "English")
        #expect(ModelLanguageMapping.recognitionLanguage(forCode: "ja-JP").requestValue == "Japanese")
        #expect(ModelLanguageMapping.recognitionLanguage(forCode: "ko-KR").requestValue == "Korean")
    }

    @Test func recognitionLanguageFallsBackToAutoForNilOrUnknown() {
        #expect(ModelLanguageMapping.recognitionLanguage(forCode: nil).requestValue == nil)
        #expect(ModelLanguageMapping.recognitionLanguage(forCode: "fr-FR").requestValue == nil)
    }

    @Test func t3poTargetLanguageMapsKnownPrefixes() {
        #expect(ModelLanguageMapping.t3poTargetLanguage(forCode: "zh-CN").promptName == "Chinese")
        #expect(ModelLanguageMapping.t3poTargetLanguage(forCode: "en-US").promptName == "English")
        #expect(ModelLanguageMapping.t3poTargetLanguage(forCode: "ja-JP").promptName == "Japanese")
        #expect(ModelLanguageMapping.t3poTargetLanguage(forCode: "ko-KR").promptName == "Korean")
    }

    @Test func t3poTargetLanguageFallsBackToChineseForUnknown() {
        #expect(ModelLanguageMapping.t3poTargetLanguage(forCode: "fr-FR").promptName == "Chinese")
    }
}
