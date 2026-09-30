import Testing
@testable import OmniVoiceCore

@Suite struct EntityMaskerTests {
    @Test func masksAndRestoresURLs() {
        let input = "Please visit https://github.com/apple/swift for details."
        let (masked, verbatim) = EntityMasker.mask(input)
        #expect(masked == "Please visit ⟦0⟧ for details.")
        #expect(verbatim == ["https://github.com/apple/swift"])

        let translated = "请访问 ⟦0⟧ 了解详情。"
        let restored = EntityMasker.restore(translation: translated, verbatim: verbatim)
        #expect(restored == "请访问 https://github.com/apple/swift 了解详情。")
    }

    @Test func masksAndRestoresCodeAndFlags() {
        let input = "Run `swift build` with --verbose flag on /usr/local/bin path."
        let (masked, verbatim) = EntityMasker.mask(input)
        #expect(masked.contains("⟦0⟧"))
        #expect(masked.contains("⟦1⟧"))
        #expect(masked.contains("⟦2⟧"))
        #expect(verbatim.contains("`swift build`"))
        #expect(verbatim.contains("--verbose"))
        #expect(verbatim.contains("/usr/local/bin"))

        let restored = EntityMasker.restore(translation: masked, verbatim: verbatim)
        #expect(restored == input)
    }

    @Test func masksIdentifiers() {
        let input = "Check parse_args and swiftVersion in file.swift."
        let (masked, verbatim) = EntityMasker.mask(input)
        #expect(verbatim.contains("parse_args"))
        #expect(verbatim.contains("swiftVersion"))
        #expect(verbatim.contains("file.swift"))

        let restored = EntityMasker.restore(translation: masked, verbatim: verbatim)
        #expect(restored == input)
    }

    @Test func handlesTextWithoutEntities() {
        let input = "Hello world, how are you today?"
        let (masked, verbatim) = EntityMasker.mask(input)
        #expect(masked == input)
        #expect(verbatim.isEmpty)

        let restored = EntityMasker.restore(translation: "你好世界，今天过得怎么样？", verbatim: verbatim)
        #expect(restored == "你好世界，今天过得怎么样？")
    }

    @Test func handlesMismatchedOrOutOfRangePlaceholdersGracefully() {
        let restored = EntityMasker.restore(translation: "结果是 ⟦99⟧ 还有 ⟦abc⟧", verbatim: ["test"])
        #expect(restored == "结果是 99 还有 abc")
    }

    @Test func masksAndRestoresRepeatedIdenticalEntities() {
        let input = "Use model_path here and model_path there."
        let (masked, verbatim) = EntityMasker.mask(input)
        #expect(masked == "Use ⟦0⟧ here and ⟦1⟧ there.")
        #expect(verbatim == ["model_path", "model_path"])

        let translated = "在这里使用 ⟦0⟧，并在那里使用 ⟦1⟧。"
        let restored = EntityMasker.restore(translation: translated, verbatim: verbatim)
        #expect(restored == "在这里使用 model_path，并在那里使用 model_path。")
    }

    @Test func masksRepeatedIdentifiersInChineseContext() {
        let input = "调用parse_args并传入parse_args参数"
        let (masked, verbatim) = EntityMasker.mask(input)
        #expect(masked == "调用⟦0⟧并传入⟦1⟧参数")
        #expect(verbatim == ["parse_args", "parse_args"])

        let restored = EntityMasker.restore(translation: masked, verbatim: verbatim)
        #expect(restored == input)
    }

    @Test func cleansDanglingOrBrokenBracketsGracefully() {
        let restored = EntityMasker.restore(translation: "结果 ⟦0⟧ 和 broken 0⟧ 以及 ⟦unclosed", verbatim: ["valid_token"])
        #expect(restored == "结果 valid_token 和 broken 0 以及 unclosed")
    }
}
