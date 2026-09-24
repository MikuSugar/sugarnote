import XCTest
@testable import SugarNoteCore

/// 字符样式「切换语义」的策略测试。
///
/// 这一环是整条链路上最容易出错的地方：备忘录的字体菜单项是切换，目标已经是该样式时
/// 再按一次会把它切掉。而这些判断全靠从 AX 富文本属性里读出来的字体名和标志位，
/// 在界面上很难复现，所以必须在这里把边界钉死。
final class CharacterStylePolicyTests: XCTestCase {

    private func reading(font: String? = nil,
                         underline: Bool? = nil,
                         strikethrough: Bool? = nil,
                         styleName: String? = nil) -> ParagraphStyleReading {
        ParagraphStyleReading(styleName: styleName, fontName: font,
                              underline: underline, strikethrough: strikethrough)
    }

    // MARK: - 粗体

    func testBoldDetectedFromFontName() {
        // 系统字体的粗体叫 Emphasized，不是 Bold——两个词都得认
        XCTAssertEqual(reading(font: ".AppleSystemUIFontEmphasized").hasCharacterStyle(.bold), true)
        XCTAssertEqual(reading(font: ".AppleSystemUIFontBold").hasCharacterStyle(.bold), true)
        XCTAssertEqual(reading(font: ".AppleSystemUIFont").hasCharacterStyle(.bold), false)
    }

    func testBoldIsNotConfusedByItalic() {
        XCTAssertEqual(reading(font: ".AppleSystemUIFontItalic").hasCharacterStyle(.bold), false)
        XCTAssertEqual(reading(font: ".AppleSystemUIFontEmphasizedItalic").hasCharacterStyle(.bold), true)
    }

    // MARK: - 斜体

    func testItalicDetectedFromFontName() {
        XCTAssertEqual(reading(font: ".AppleSystemUIFontItalic").hasCharacterStyle(.italic), true)
        XCTAssertEqual(reading(font: ".AppleSystemUIFontOblique").hasCharacterStyle(.italic), true)
        XCTAssertEqual(reading(font: ".AppleSystemUIFontEmphasized").hasCharacterStyle(.italic), false)
    }

    func testBoldItalicDetectsBoth() {
        let both = reading(font: ".AppleSystemUIFontEmphasizedItalic")
        XCTAssertEqual(both.hasCharacterStyle(.bold), true)
        XCTAssertEqual(both.hasCharacterStyle(.italic), true)
    }

    // MARK: - 下划线 / 删除线

    func testUnderlineAndStrikethroughUseFlags() {
        XCTAssertEqual(reading(underline: true).hasCharacterStyle(.underline), true)
        XCTAssertEqual(reading(underline: false).hasCharacterStyle(.underline), false)
        XCTAssertEqual(reading(strikethrough: true).hasCharacterStyle(.strikethrough), true)
        XCTAssertEqual(reading(strikethrough: false).hasCharacterStyle(.strikethrough), false)
    }

    func testMissingFlagMeansUnknownNotFalse() {
        // 读不到标志位时必须是 nil（未知），不能当成 false——
        // 当成 false 会导致多按一次，把已有的样式切掉
        XCTAssertNil(reading().hasCharacterStyle(.underline))
        XCTAssertNil(reading().hasCharacterStyle(.strikethrough))
    }

    // MARK: - 高亮

    func testHighlightDetectedFromCompositeStyleName() {
        // 高亮没有独立标志位，只体现在 AXStyleName 变成复合样式名
        XCTAssertEqual(reading(styleName: "正文, 紫色高亮标记").hasCharacterStyle(.highlight), true)
        XCTAssertEqual(reading(styleName: "正文").hasCharacterStyle(.highlight), false)
    }

    func testHighlightUnknownWhenStyleNameMissing() {
        XCTAssertNil(reading().hasCharacterStyle(.highlight))
    }

    // MARK: - 段落样式不走这套

    func testParagraphStylesAreNotCharacterStyles() {
        for action in [NotesAction.title, .heading, .subheading, .body, .monospaced,
                       .bulletedList, .dashedList, .numberedList, .checklist, .blockQuote] {
            XCTAssertNil(action.isParagraphLevel ? reading().hasCharacterStyle(action) : nil,
                         "\(action.rawValue) 不该走字符样式判断")
        }
    }

    // MARK: - 触发决策

    func testSkipWhenStyleAlreadyApplied() {
        // 已经是粗体 → 不能触发，否则会切掉
        XCTAssertFalse(CharacterStylePolicy.shouldInvoke(
            .bold, current: reading(font: ".AppleSystemUIFontEmphasized")))
        // 不是粗体 → 触发
        XCTAssertTrue(CharacterStylePolicy.shouldInvoke(
            .bold, current: reading(font: ".AppleSystemUIFont")))
    }

    func testInvokeWhenStateUnknown() {
        // 读数不足时保守触发（后面有复核兜底），避免漏掉样式
        XCTAssertTrue(CharacterStylePolicy.shouldInvoke(.bold, current: nil))
        XCTAssertTrue(CharacterStylePolicy.shouldInvoke(.highlight, current: reading()))
        XCTAssertTrue(CharacterStylePolicy.shouldInvoke(.underline, current: reading(font: ".AppleSystemUIFont")))
    }

    func testParagraphStyleAlwaysInvoked() {
        // 段落样式是单选语义，再选一次不会切回正文，所以永远该触发
        XCTAssertTrue(CharacterStylePolicy.shouldInvoke(.title, current: reading(styleName: "标题")))
        XCTAssertTrue(CharacterStylePolicy.shouldInvoke(.body, current: reading(styleName: "正文")))
    }

    // MARK: - 复核

    func testSatisfiedAfterInvocation() {
        XCTAssertEqual(CharacterStylePolicy.isSatisfied(
            .bold, after: reading(font: ".AppleSystemUIFontEmphasized")), true)
        XCTAssertEqual(CharacterStylePolicy.isSatisfied(
            .bold, after: reading(font: ".AppleSystemUIFont")), false)
        XCTAssertNil(CharacterStylePolicy.isSatisfied(.bold, after: nil))
    }

    // MARK: - ActionOutcome

    func testActionOutcomeSucceeded() {
        XCTAssertTrue(ActionOutcome(action: .bold, method: nil,
                                    alreadyApplied: true, verified: true).succeeded)
        XCTAssertTrue(ActionOutcome(action: .bold, method: .axPress,
                                    alreadyApplied: false, verified: true).succeeded)
        XCTAssertFalse(ActionOutcome(action: .bold, method: .axPress,
                                     alreadyApplied: false, verified: false).succeeded)
        XCTAssertFalse(ActionOutcome(action: .bold, method: .failed,
                                     alreadyApplied: false, verified: nil).succeeded)
    }

    func testActionOutcomeSummaryIsReadable() {
        XCTAssertEqual(ActionOutcome(action: .bold, method: nil,
                                     alreadyApplied: true, verified: true).summary,
                       "bold/已是目标样式,跳过")
        XCTAssertEqual(ActionOutcome(action: .bold, method: .axPress,
                                     alreadyApplied: false, verified: true).summary,
                       "bold/axPress/已复核")
    }
}
