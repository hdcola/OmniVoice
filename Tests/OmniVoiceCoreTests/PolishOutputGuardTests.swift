import Testing
@testable import OmniVoiceCore

@Suite("PolishOutputGuard")
struct PolishOutputGuardTests {
    private let source = "嗯那个我明天下午三点有个会就是说可能没法吃饭了"

    private func check(_ output: String, source: String? = nil, style: PolishStyle = .clean) -> String? {
        PolishOutputGuard.validate(output: output, source: source ?? self.source, style: style)
    }

    @Test("a sensible output passes, trimmed")
    func passes() {
        #expect(check("\n我明天下午三点有个会，可能没法吃饭了。 ") == "我明天下午三点有个会，可能没法吃饭了。")
    }

    @Test("empty output is rejected")
    func empty() {
        #expect(check("") == nil)
        #expect(check("  \n ") == nil)
    }

    @Test("too long or too short is rejected")
    func length() {
        #expect(check(String(repeating: "好", count: 200)) == nil)
        #expect(check("好") == nil)
    }

    @Test("structured style allows a longer output")
    func structuredLength() {
        let short = "第一件事 第二件事"
        let listed = "1. 第一件事\n2. 第二件事\n3. 第三件事\n4. 第四件事"
        #expect(check(listed, source: short, style: .clean) == nil)
        #expect(check(listed, source: short, style: .structured) == listed)
    }

    @Test("code blocks are rejected")
    func codeFence() {
        #expect(check("```\n我明天下午三点有个会，可能没法吃饭了。\n```") == nil)
    }

    @Test("a chatty preamble is rejected")
    func preamble() {
        #expect(check("好的，以下是整理后的文本：我明天下午三点有个会，可能没法吃饭了。") == nil)
        #expect(check("Here is the polished text: 我明天下午三点有个会可能没法吃饭了") == nil)
    }

    @Test("an echoed few-shot 输出： label is rejected")
    func exampleLabel() {
        #expect(check("输出：我明天下午三点有个会，可能没法吃饭了。") == nil)
        #expect(check("输出: 我明天下午三点有个会，可能没法吃饭了。") == nil)
    }

    @Test("a code block hidden inside quotes is rejected")
    func quotedCodeFence() {
        #expect(check("\"```\n我明天下午三点有个会，可能没法吃饭了。\n```\"") == nil)
    }

    @Test("leaked prompt fragments are rejected")
    func leak() {
        #expect(check("我明天下午三点有个会 [RULES] 可能没法吃饭了") == nil)
        for marker in ["[STYLE]", "[EXAMPLES]", "[EXTRA]"] {
            #expect(check("\(marker) 我明天下午三点有个会，可能没法吃饭了。") == nil)
        }
    }

    @Test("one layer of wrapping quotes is stripped")
    func quotes() {
        #expect(check("“我明天下午三点有个会，可能没法吃饭了。”") == "我明天下午三点有个会，可能没法吃饭了。")
        #expect(check("\"我明天下午三点有个会，可能没法吃饭了。\"") == "我明天下午三点有个会，可能没法吃饭了。")
    }

    @Test("quotes the speaker had are kept")
    func ownQuotes() {
        let quoted = "“我明天下午三点有个会就是说可能没法吃饭了”"
        #expect(check(quoted, source: quoted) == quoted)
    }

    @Test("every placeholder must come back exactly once")
    func placeholders() {
        let masked = "打开 ⟦0⟧ 然后访问 ⟦1⟧ 看一下结果"
        #expect(check("打开 ⟦0⟧，然后访问 ⟦1⟧，看一下结果。", source: masked) != nil)
        #expect(check("打开 ⟦0⟧，然后访问，看一下结果。", source: masked) == nil)
        #expect(check("打开 ⟦0⟧，然后访问 ⟦1⟧ ⟦1⟧，看一下结果。", source: masked) == nil)
        #expect(check("打开 ⟦0⟧，然后访问 ⟦2⟧，看一下结果。", source: masked) == nil)
        // A small model's inner spaces are tolerated (EntityMasker.restore fixes them).
        #expect(check("打开 ⟦ 0 ⟧，然后访问 ⟦1 ⟧，看一下结果。", source: masked) != nil)
    }

    @Test("think tags are rejected, whether leftover or said by the speaker")
    func thinkTags() {
        #expect(check("我想了想</think>今天天气很好。", source: "今天天气很好") == nil)
        #expect(check("<Think>今天天气很好。", source: "今天天气很好") == nil)
        // The speaker said it: stripping would have cut the sentence, so type the original.
        #expect(check("今天天气很好，用", source: "今天天气很好 <think> 标签") == nil)
        #expect(check("今天天气很好，用 <think> 标签。", source: "今天天气很好 <think> 标签") == nil)
    }
}
