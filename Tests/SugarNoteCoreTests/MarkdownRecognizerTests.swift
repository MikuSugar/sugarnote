import XCTest
@testable import SugarNoteCore

/// 识别器的单元测试。
///
/// 这些用例不碰 AX、不碰备忘录，纯字符串逻辑——所以能脱离权限和 Notes 反复跑。
/// 文本里用 `|` 标记光标位置，`recognize` 之前会把它剥掉。
final class MarkdownRecognizerTests: XCTestCase {

    /// 用 `|` 标记光标。返回识别结果。
    ///
    /// 注意光标要按 **UTF-16 码元**算，不是 Swift 的字符簇个数——`🎉` 是 1 个字符
    /// 但占 2 个码元，按字符数算会偏。
    private func recognize(_ marked: String,
                           options: RecognizerOptions = RecognizerOptions()) -> EditPlan? {
        let caret = marked[marked.startIndex..<marked.firstIndex(of: "|")!].utf16.count
        let text = marked.replacingOccurrences(of: "|", with: "")
        return MarkdownRecognizer.recognize(text: text as NSString, caret: caret, options: options)
    }

    /// 应用那一次原子替换，得到转换后的文本。
    private func applying(_ plan: EditPlan, to marked: String) -> String {
        let mutable = NSMutableString(string: marked.replacingOccurrences(of: "|", with: ""))
        mutable.replaceCharacters(in: plan.replacement.range, with: plan.replacement.text)
        return mutable as String
    }

    // MARK: - 行内语法

    func testBold() {
        let plan = recognize("**bold**|")
        XCTAssertEqual(plan?.actions, [.bold])
        XCTAssertEqual(plan?.replacement, Replacement(range: NSRange(location: 0, length: 8), text: "bold"))
        // 删掉首尾分隔符后，中间内容正好落在开分隔符原来的起点
        XCTAssertEqual(plan?.selection, NSRange(location: 0, length: 4))
        XCTAssertEqual(applying(plan!, to: "**bold**"), "bold")
    }

    /// 范围一律是 UTF-16 码元偏移，不是字符个数。
    /// 「粗体」是 2 个字符 = 2 个 UTF-16 单元，所以 `**粗体**` 总长 6 而不是 8。
    func testRangesAreUTF16Offsets() {
        let plan = recognize("**粗体**|")
        XCTAssertEqual(plan?.actions, [.bold])
        XCTAssertEqual(plan?.replacement, Replacement(range: NSRange(location: 0, length: 6), text: "粗体"))
        XCTAssertEqual(plan?.selection, NSRange(location: 0, length: 2))
        XCTAssertEqual(applying(plan!, to: "**粗体**"), "粗体")
    }

    /// emoji 这类代理对占 2 个 UTF-16 单元，范围计算必须按码元走
    func testRangesWithSurrogatePairs() {
        let plan = recognize("**🎉**|")
        XCTAssertEqual(plan?.actions, [.bold])
        // 🎉 是 2 个码元，所以整个 `**🎉**` 是 6 个码元、中间长度是 2
        XCTAssertEqual(plan?.replacement, Replacement(range: NSRange(location: 0, length: 6), text: "🎉"))
        XCTAssertEqual(plan?.selection, NSRange(location: 0, length: 2))
    }

    func testBoldDoesNotGetMistakenForItalic() {
        // `**粗体**` 里内层那个星号不能被当成斜体语法
        let plan = recognize("**粗体**|")
        XCTAssertEqual(plan?.actions, [.bold])
    }

    func testItalicWithAsterisk() {
        let plan = recognize("*italic*|")
        XCTAssertEqual(plan?.actions, [.italic])
        XCTAssertEqual(applying(plan!, to: "*italic*"), "italic")
    }

    func testItalicWithUnderscore() {
        let plan = recognize("_italic_|")
        XCTAssertEqual(plan?.actions, [.italic])
    }

    func testDoubleUnderscoreMeansUnderline() {
        let plan = recognize("__under__|")
        XCTAssertEqual(plan?.actions, [.underline])

        var options = RecognizerOptions()
        options.doubleUnderscoreMeansUnderline = false
        let asBold = recognize("__bold__|", options: options)
        XCTAssertEqual(asBold?.actions, [.bold])
    }

    func testStrikethrough() {
        XCTAssertEqual(recognize("~~strike~~|")?.actions, [.strikethrough])
    }

    func testInlineCode() {
        XCTAssertEqual(recognize("`code`|")?.actions, [.monospaced])
    }

    func testHighlight() {
        XCTAssertEqual(recognize("==mark==|")?.actions, [.highlight])
    }

    func testCaretInMiddleOfParagraph() {
        // 后面还有内容时也要能识别，光标就在闭合分隔符之后
        let plan = recognize("**bold**| and more")
        XCTAssertEqual(plan?.actions, [.bold])
        XCTAssertEqual(plan?.selection, NSRange(location: 0, length: 4))
    }

    func testUnclosedDelimiterIsIgnored() {
        XCTAssertNil(recognize("**bold*|"))
        XCTAssertNil(recognize("**|"))
        XCTAssertNil(recognize("**|bold**"))
    }

    func testWhitespaceInnerIsIgnored() {
        // 首尾是空白的不算强调。用 `_` 测：`* ` 在行首会被当成项目符号列表，
        // 那样测的就不是行内规则了。
        XCTAssertNil(recognize("_ 强调 _|"))
        XCTAssertNil(recognize("_强调 _|"))
    }

    func testAsteriskAtParagraphStartIsABulletNotItalic() {
        // `* 内容 *` 在行首应解读成项目符号列表，符合 Markdown 的优先级
        XCTAssertEqual(recognize("* 强调 *|")?.actions, [.bulletedList])
    }

    func testInlineDoesNotCrossParagraph() {
        XCTAssertNil(recognize("**first\nsecond**|"))
    }

    func testEscapedDelimiterIsIgnored() {
        XCTAssertNil(recognize("\\**bold**|"))
    }

    func testInlineAfterNewlineUsesParagraphStart() {
        // 跨段落时范围要正确偏移
        let plan = recognize("first\n**bold**|")
        XCTAssertEqual(plan?.actions, [.bold])
        XCTAssertEqual(plan?.replacement, Replacement(range: NSRange(location: 6, length: 8), text: "bold"))
        XCTAssertEqual(plan?.selection, NSRange(location: 6, length: 4))
        XCTAssertEqual(applying(plan!, to: "first\n**bold**"), "first\nbold")
    }

    // MARK: - 段落语法

    func testHeadings() {
        XCTAssertEqual(recognize("# |")?.actions, [.title])
        XCTAssertEqual(recognize("## |")?.actions, [.heading])
        XCTAssertEqual(recognize("### |")?.actions, [.subheading])
        // 四级以上没有对应的备忘录样式
        XCTAssertNil(recognize("#### |"))
    }

    func testHeadingMustBeAtParagraphStart() {
        XCTAssertNil(recognize("前面有字 # |"))
        XCTAssertEqual(recognize("上一行\n# |")?.actions, [.title])
    }

    func testBulletedList() {
        XCTAssertEqual(recognize("- |")?.actions, [.bulletedList])
        XCTAssertEqual(recognize("* |")?.actions, [.bulletedList])
        XCTAssertEqual(recognize("+ |")?.actions, [.bulletedList])
    }

    func testNumberedList() {
        XCTAssertEqual(recognize("1. |")?.actions, [.numberedList])
        XCTAssertEqual(recognize("12. |")?.actions, [.numberedList])
        // 三位数字不认，免得把年份之类当列表
        XCTAssertNil(recognize("123. |"))
    }

    func testChecklist() {
        XCTAssertEqual(recognize("- [ ] |")?.actions, [.checklist])
        XCTAssertEqual(recognize("[] |")?.actions, [.checklist])
        // 打了勾的要「先转成核对清单再打勾」
        XCTAssertEqual(recognize("- [x] |")?.actions, [.checklist, .markChecked])
        XCTAssertEqual(recognize("- [X] |")?.actions, [.checklist, .markChecked])
    }

    func testChecklistAcceptsBareBrackets() {
        // 关键行为：备忘录的智能列表会先把 `- ` 变成短划线列表，
        // 等我们看到的时候正文里只剩 `[ ] `。所以必须认裸的方括号形式。
        XCTAssertEqual(recognize("[ ] |")?.actions, [.checklist])
        XCTAssertEqual(recognize("[] |")?.actions, [.checklist])
        XCTAssertEqual(recognize("[x] |")?.actions, [.checklist, .markChecked])
        XCTAssertEqual(recognize("[X] |")?.actions, [.checklist, .markChecked])
        // 带前缀的写法也要认（用户没开智能列表时会走到这里）
        XCTAssertEqual(recognize("- [ ] |")?.actions, [.checklist])
        XCTAssertEqual(recognize("* [x] |")?.actions, [.checklist, .markChecked])
    }

    func testChecklistRequiresParagraphStart() {
        XCTAssertNil(recognize("前面有字 [ ] |"))
    }

    func testDividerAcceptsFormsSmartDashesDoesNotEat() {
        // `---` 会被备忘录的智能破折号变成 em dash，所以推荐写法是 *** 和 ___
        XCTAssertEqual(recognize("***|")?.actions, [.insertDivider])
        XCTAssertEqual(recognize("___|")?.actions, [.insertDivider])
        XCTAssertEqual(recognize("---|")?.actions, [.insertDivider])
        // 已经被智能破折号转成 em dash 的情况也要认
        XCTAssertEqual(recognize("—|")?.actions, [.insertDivider])
        XCTAssertEqual(recognize("——|")?.actions, [.insertDivider])
    }

    func testBlockQuote() {
        XCTAssertEqual(recognize("> |")?.actions, [.blockQuote])
    }

    func testCodeFence() {
        XCTAssertEqual(recognize("```|")?.actions, [.monospaced])
    }

    func testDivider() {
        XCTAssertEqual(recognize("---|")?.actions, [.insertDivider])
        var options = RecognizerOptions()
        options.recognizesDivider = false
        XCTAssertNil(recognize("---|", options: options))
    }

    func testParagraphTriggerDeletesWholeTrigger() {
        let plan = recognize("## |")
        XCTAssertEqual(plan?.replacement.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(plan?.replacement.text, "")
        // 段落样式按光标所在段落生效，光标本来就在这一段里，所以不设选区也不动光标
        XCTAssertNil(plan?.selection)
        XCTAssertNil(plan?.caretAfter)
    }

    func testParagraphTriggerMatchesWhenCaretIsAfterTheHeadingText() {
        // 用户敲完 `# ` 会接着敲标题文字，等我们去看的时候段落已是 `# 标题`。
        // 触发字符只消费开头那几个，后面的内容原样保留。
        let plan = recognize("# 标题|")
        XCTAssertEqual(plan?.actions, [.title])
        XCTAssertEqual(plan?.replacement, Replacement(range: NSRange(location: 0, length: 2), text: ""))
        XCTAssertEqual(applying(plan!, to: "# 标题"), "标题")
    }

    func testInlineTriggerMatchesWhenCaretIsPastTheClosingMarker() {
        // 敲完 `**粗体**` 又接着打了两字，光标不在闭合标记后面了，也应该识别
        let plan = recognize("**粗体** 后面|")
        XCTAssertEqual(plan?.actions, [.bold])
        XCTAssertEqual(plan?.replacement, Replacement(range: NSRange(location: 0, length: 6), text: "粗体"))
        // 语法在光标前面：按删掉的 4 个字符把光标前移，保住用户的输入位置。
        // 原文 9 个码元，删掉 4 个（两处 `**`）后光标应在 5，即编辑后文本的末尾。
        XCTAssertEqual(plan?.caretAfter, 5)
        XCTAssertEqual(applying(plan!, to: "**粗体** 后面"), "粗体 后面")
    }

    func testCaretStaysAtEndWhenClosingMarkerTouchesIt() {
        let plan = recognize("**粗体**|")
        XCTAssertEqual(plan?.caretAfter, 2)
    }

    // MARK: - 边界

    func testEmptyAndCaretAtStart() {
        XCTAssertNil(MarkdownRecognizer.recognize(text: "" as NSString, caret: 0))
        XCTAssertNil(MarkdownRecognizer.recognize(text: "abc" as NSString, caret: 0))
    }

    func testPlainTextIsIgnored() {
        XCTAssertNil(recognize("就是一句普通的话|"))
        XCTAssertNil(recognize("单价是 100 元|"))
    }

    func testParagraphRange() {
        let text = "第一段\n第二段\n第三段" as NSString
        // 光标在第二段中间
        let range = MarkdownRecognizer.paragraphRange(in: text, containing: 6)
        XCTAssertEqual(text.substring(with: range), "第二段")
    }

    func testParagraphRangeAtEndOfText() {
        let text = "第一段\n第二段" as NSString
        let range = MarkdownRecognizer.paragraphRange(in: text, containing: text.length)
        XCTAssertEqual(text.substring(with: range), "第二段")
    }
}
