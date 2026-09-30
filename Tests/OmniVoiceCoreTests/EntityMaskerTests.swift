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
        #expect(restored == "结果是 还有 abc")
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
        #expect(restored == "结果 valid_token 和 broken valid_token 以及 unclosed")
    }

    @Test func restoresPlaceholdersWithInnerWhitespace() {
        let restored = EntityMasker.restore(translation: "使用 ⟦ 0 ⟧ 和 ⟦1 ⟧", verbatim: ["model_path", "--verbose"])
        #expect(restored == "使用 model_path 和 --verbose")
    }

    @Test func leavesPlainNumbersAndDropsUnknownPlaceholders() {
        #expect(EntityMasker.restore(translation: "共 3 个", verbatim: ["x_y"]) == "共 3 个")
        #expect(EntityMasker.restore(translation: "⟦5⟧ 结束", verbatim: []) == "结束")
    }

    @Test func doesNotMaskOrdinaryDottedProse() {
        for input in ["See e.g. this", "Made in the U.S.", "Hi Mr.Smith", "okay.So we start", "okay.so we start"] {
            let (masked, verbatim) = EntityMasker.mask(input)
            #expect(masked == input, "\(input)")
            #expect(verbatim.isEmpty, "\(input)")
        }
    }

    @Test func masksDottedCodeAndFilenames() {
        let (_, verbatim) = EntityMasker.mask("Open README.md, set config.modelPath and read self.view.frame.")
        #expect(verbatim == ["README.md", "config.modelPath", "self.view.frame"])
    }

    @Test func doesNotMaskSlashesInsideWords() {
        for input in ["use and/or/xor here", "about 1/2/3 of them"] {
            let (masked, verbatim) = EntityMasker.mask(input)
            #expect(masked == input, "\(input)")
            #expect(verbatim.isEmpty, "\(input)")
        }
    }

    @Test func masksHomeRelativePaths() {
        let (masked, verbatim) = EntityMasker.mask("Check ~/Downloads/model.gguf now")
        #expect(masked == "Check ⟦0⟧ now")
        #expect(verbatim == ["~/Downloads/model.gguf"])
    }

    @Test func masksSingleSegmentHomeAndRelativePaths() {
        for input in ["Check ~/Downloads now", "Run ./build now", "See ../parent now"] {
            let (_, verbatim) = EntityMasker.mask(input)
            #expect(verbatim.count == 1, "\(input)")
        }
    }

    @Test func masksSnakeCaseWithLeadingUnderscore() {
        let (_, verbatim) = EntityMasker.mask("Call _private_helper first")
        #expect(verbatim == ["_private_helper"])
    }

    @Test func masksDunderIdentifiers() {
        let (masked, verbatim) = EntityMasker.mask("Define __init__ and __main__ here")
        #expect(masked == "Define ⟦0⟧ and ⟦1⟧ here")
        #expect(verbatim == ["__init__", "__main__"])
    }

    @Test func trimsTrailingSentencePunctuationFromUrlsAndPaths() {
        let (masked1, verbatim1) = EntityMasker.mask("Please visit https://github.com.")
        #expect(masked1 == "Please visit ⟦0⟧.")
        #expect(verbatim1 == ["https://github.com"])

        let (masked2, verbatim2) = EntityMasker.mask("See https://example.com, it is good.")
        #expect(masked2 == "See ⟦0⟧, it is good.")
        #expect(verbatim2 == ["https://example.com"])

        let (masked3, verbatim3) = EntityMasker.mask("The log is in /usr/local/bin.")
        #expect(masked3 == "The log is in ⟦0⟧.")
        #expect(verbatim3 == ["/usr/local/bin"])
    }

    @Test func masksShortCliFlagsAndFlagsWithoutLeadingSpace() {
        let (masked, verbatim) = EntityMasker.mask("Run with -c now")
        #expect(masked == "Run with ⟦0⟧ now")
        #expect(verbatim == ["-c"])

        let (maskedZh, verbatimZh) = EntityMasker.mask("执行--dry-run选项")
        #expect(maskedZh == "执行⟦0⟧选项")
        #expect(verbatimZh == ["--dry-run"])
    }

    @Test func doesNotMaskNegativeNumbersAsFlags() {
        let (masked, verbatim) = EntityMasker.mask("The temperature is -1 degrees, or -3.14 exactly.")
        #expect(masked == "The temperature is -1 degrees, or -3.14 exactly.")
        #expect(verbatim.isEmpty)
    }

    @Test func masksCombinedShortFlags() {
        for (input, flag) in [("rm -rf now", "-rf"), ("tar -czvf now", "-czvf"), ("gcc -Wall now", "-Wall")] {
            let (_, verbatim) = EntityMasker.mask(input)
            #expect(verbatim == [flag], "\(input)")
        }
    }

    @Test func doesNotMaskAmPmAsFilenames() {
        for input in ["Meet at 10 a.m. tomorrow", "Call before 8 p.m. tonight"] {
            let (masked, verbatim) = EntityMasker.mask(input)
            #expect(masked == input, "\(input)")
            #expect(verbatim.isEmpty, "\(input)")
        }
    }

    @Test func keepsBalancedParenthesesInsideUrlsButTrimsWrappingOnes() {
        let (masked1, verbatim1) = EntityMasker.mask("See https://en.wikipedia.org/wiki/Foo_(bar) for details.")
        #expect(masked1 == "See ⟦0⟧ for details.")
        #expect(verbatim1 == ["https://en.wikipedia.org/wiki/Foo_(bar)"])

        let (masked2, verbatim2) = EntityMasker.mask("please check (https://github.com) now")
        #expect(masked2 == "please check (⟦0⟧) now")
        #expect(verbatim2 == ["https://github.com"])
    }

    @Test func flagValueDoesNotSwallowFollowingCJKText() {
        let (masked, verbatim) = EntityMasker.mask("执行--output=foo选项")
        #expect(masked == "执行⟦0⟧选项")
        #expect(verbatim == ["--output=foo"])
    }

    @Test func trimsTrailingPunctuationFromFlagValues() {
        let (masked, verbatim) = EntityMasker.mask("Run with --filter=abc, then test.")
        #expect(masked == "Run with ⟦0⟧, then test.")
        #expect(verbatim == ["--filter=abc"])
    }

    @Test func masksQuotedFlagValuesContainingSpaces() {
        let (masked, verbatim) = EntityMasker.mask("Run with --message=\"hello world\" now")
        #expect(masked == "Run with ⟦0⟧ now")
        #expect(verbatim == ["--message=\"hello world\""])
    }

    @Test func masksFlagValuesThatAreURLsOrHostPorts() {
        let (masked1, verbatim1) = EntityMasker.mask("执行--url=https://github.com选项")
        #expect(masked1 == "执行⟦0⟧选项")
        #expect(verbatim1 == ["--url=https://github.com"])

        let (masked2, verbatim2) = EntityMasker.mask("Connect with --addr=127.0.0.1:8080 now")
        #expect(masked2 == "Connect with ⟦0⟧ now")
        #expect(verbatim2 == ["--addr=127.0.0.1:8080"])
    }
}
