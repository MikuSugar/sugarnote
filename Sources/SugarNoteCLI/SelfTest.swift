import ApplicationServices
import AppKit
import Foundation
import SugarNoteCore

/// 端到端自检：真的往备忘录里写东西，验证「识别 → 删分隔符 → 应用样式」整条链路。
///
/// ## 安全护栏（必须保持）
///
/// 这个工具会写备忘录，所以护栏是硬性的，不是可选项：
///
/// 1. **只允许在空白笔记里跑。** 一进来就断言当前笔记正文长度为 0，不是 0 就立刻退出，
///    什么都不动、什么都不"清理"。
/// 2. **绝不按整篇长度做替换。** 每一轮只删自己刚插入的那一段，删之前还要校验那一段
///    的内容确实是自己的，对不上就跳过并报告。
/// 3. **不做任何删除笔记的操作。** 不按 ⌘⌫、不移动、不碰废纸篓。要删笔记由用户自己删。
/// 4. 跑完把正文长度恢复到测试前的值，并断言一致。
///
/// 之所以写这么死：2026-09-24 我第一版自检里假设「⌘N 一定会新建笔记」，但合成的按键
/// 其实没触发菜单快捷键，结果跑进了用户的真实笔记，清理时又整篇清空，把一条 2963 字的
/// 笔记清掉了。护栏是针对那次的根因加的。
enum SelfTest {

    struct Case {
        let markdown: String
        let expectedText: String
        let expectedActions: [NotesAction]
        /// 转换后应该是哪个段落样式。用菜单项的勾选状态判定——这是备忘录自己的状态，
        /// 且与界面语言无关（AXStyleName 是本地化的，中文「标题」和「小标题」都含「标题」，
        /// 拿它做断言分不开）。
        let expectedParagraphStyle: NotesAction?
        /// 转换后应该带上的字符样式。
        let expectedCharacterStyle: NotesAction?

        init(markdown: String, expectedText: String, expectedActions: [NotesAction],
             expectedParagraphStyle: NotesAction? = nil,
             expectedCharacterStyle: NotesAction? = nil) {
            self.markdown = markdown
            self.expectedText = expectedText
            self.expectedActions = expectedActions
            self.expectedParagraphStyle = expectedParagraphStyle
            self.expectedCharacterStyle = expectedCharacterStyle
        }
    }

    static let cases: [Case] = [
        Case(markdown: "**bold**", expectedText: "bold", expectedActions: [.bold],
             expectedCharacterStyle: .bold),
        Case(markdown: "*italic*", expectedText: "italic", expectedActions: [.italic],
             expectedCharacterStyle: .italic),
        Case(markdown: "__under__", expectedText: "under", expectedActions: [.underline],
             expectedCharacterStyle: .underline),
        Case(markdown: "~~strike~~", expectedText: "strike", expectedActions: [.strikethrough],
             expectedCharacterStyle: .strikethrough),
        Case(markdown: "`code`", expectedText: "code", expectedActions: [.monospaced],
             expectedParagraphStyle: .monospaced),
        Case(markdown: "==mark==", expectedText: "mark", expectedActions: [.highlight],
             expectedCharacterStyle: .highlight),
        Case(markdown: "# ", expectedText: "", expectedActions: [.title],
             expectedParagraphStyle: .title),
        Case(markdown: "## ", expectedText: "", expectedActions: [.heading],
             expectedParagraphStyle: .heading),
        Case(markdown: "> ", expectedText: "", expectedActions: [.blockQuote],
             expectedParagraphStyle: .blockQuote),
        Case(markdown: "- [ ] ", expectedText: "", expectedActions: [.checklist],
             expectedParagraphStyle: .checklist),
        Case(markdown: "1. ", expectedText: "", expectedActions: [.numberedList],
             expectedParagraphStyle: .numberedList),
    ]

    static func run(runUndoCheck: Bool) -> Int32 {
        guard AXIsProcessTrusted() else {
            print("没有辅助功能权限。")
            return 1
        }
        guard let app = NotesApp.running() else {
            print("备忘录没在运行。")
            return 1
        }

        // 前台是硬要求：菜单项在后台是禁用的，AXPress 会失败
        guard app.activate() else {
            print("备忘录没能切到前台，放弃（不改动任何内容）。")
            return 1
        }

        // 焦点可能停在侧边栏/搜索框上，先移回正文（只移动焦点，不改内容）
        guard let initialNote = app.focusNoteBody() else {
            print("找不到笔记正文元素。请打开备忘录、确认窗口里有一条笔记，然后重试。")
            return 1
        }

        let engine = NotesEngine(app: app)
        engine.refreshMenuIndex()

        // 护栏 1：只允许在空白笔记里跑。当前笔记非空就先新建一条（新建不是破坏性操作），
        // 新建后仍非空就直接放弃——绝不"清理"用户已有内容。
        var note = initialNote
        var createdNote = false
        if !initialNote.isEmpty {
            print("当前笔记不是空的（\(initialNote.noteID ?? "未知")，"
                  + "\(initialNote.textLength ?? -1) 字），先新建一条空白笔记…")
            guard let newNoteItem = engine.currentMenuIndex().resolve(.newNote) else {
                print("⛔️ 菜单里找不到「新建备忘录」，放弃（不改动任何内容）。")
                return 1
            }
            let result = MenuInvoker().invoke(newNoteItem.item, in: app)
            print("  触发「新建备忘录」：\(result.method.rawValue)")
            guard result.success else {
                print("⛔️ 新建备忘录失败，放弃（不改动任何内容）。")
                return 1
            }
            usleep(1_200_000)

            guard let fresh = app.focusNoteBody() else {
                print("⛔️ 新建后找不到正文元素，放弃。")
                return 1
            }
            note = fresh
            createdNote = true
        }

        guard note.isEmpty else {
            let length = note.textLength ?? -1
            print("""
            ⛔️ 目标笔记不是空的（正文长度 \(length)），拒绝运行。

            这个自检会往正文里写测试内容，只允许在空白笔记里跑。
            它不会删除任何笔记，也不会改动非空白笔记的正文。
            """)
            return 1
        }

        print("目标笔记 id：\(note.noteID ?? "未知")")
        print("测试前正文长度：0（已确认空白）")
        print("")

        var passed = 0
        var failures: [String] = []

        for testCase in cases {
            guard let caret = note.selectedRange?.location else {
                failures.append("\(testCase.markdown): 读不到光标")
                continue
            }
            // 空笔记的 AXValue 读出来是 nil，统一按空串处理
            let ns = (note.text() ?? "") as NSString
            let ownedStart = ns.length

            // 基线归零：上一轮把段落设成标题/列表后，下一段会继承那个样式（备忘录的
            // 段落样式是向下继承的），不归零的话「样式是应用上的还是继承来的」分不清。
            _ = note.setSelectedRange(NSRange(location: ownedStart, length: 0))
            if let bodyAction = engine.currentMenuIndex().resolve(.body) {
                _ = MenuInvoker().invoke(bodyAction.item, in: app)
                usleep(90_000)
            }
            _ = caret

            guard note.insert("\n" + testCase.markdown, at: ownedStart) else {
                failures.append("\(testCase.markdown): 插入测试文本失败")
                continue
            }
            usleep(120_000)

            let outcome = engine.handleTextChange()

            guard case .converted(let plan, let outcomes) = outcome else {
                failures.append("\(testCase.markdown): \(outcome.summary)")
                cleanUp(note: note, from: ownedStart, expecting: testCase.markdown)
                continue
            }

            usleep(120_000)
            let paragraph = readCurrentParagraph(note)
            let actions = outcomes.map(\.action)

            var problems: [String] = []
            if actions != testCase.expectedActions {
                problems.append("动作 \(actions.map(\.rawValue)) ≠ 期望 \(testCase.expectedActions.map(\.rawValue))")
            }
            if paragraph != testCase.expectedText {
                problems.append("段落文本 \(paragraph.debugDescription) ≠ 期望 \(testCase.expectedText.debugDescription)")
            }
            let styleReading = note.paragraphStyle()
            let rawAttributes = note.attributes(in: MarkdownRecognizer.paragraphRange(
                in: (note.text() ?? "") as NSString,
                containing: note.selectedRange?.location ?? 0))

            let failed = outcomes.filter { !$0.succeeded }
            if !failed.isEmpty {
                problems.append("触发未生效：\(failed.map(\.summary))")
            }

            // 样式验证：只看文本变没变是不够的，分隔符删了但样式没打上也符合「文本正确」
            if let expected = testCase.expectedParagraphStyle {
                let checked = checkedParagraphStyles(engine: engine)
                if !checked.contains(expected) {
                    problems.append("段落样式 \(expected.rawValue) 没打上（菜单勾选："
                                    + "\(checked.map(\.rawValue).sorted().joined(separator: ",") )）")
                } else if expected != .blockQuote,
                          let stray = checked.subtracting([.blockQuote, expected]).first {
                    // 块引用是正交属性，可以和标题共存，所以单独放行；
                    // 其余段落样式属于同一组单选，同时勾上两个说明应用错了。
                    problems.append("段落样式多出 \(stray.rawValue)")
                }
            }
            if let expected = testCase.expectedCharacterStyle {
                if styleReading?.hasCharacterStyle(expected) != true {
                    problems.append("字符样式 \(expected.rawValue) 没打上（\(styleReading?.summary ?? "读不到")）")
                }
            }

            if problems.isEmpty {
                passed += 1
                let via = outcomes.map(\.summary).joined(separator: " ")
                print("  ✓ \(testCase.markdown.padding(toLength: 12, withPad: " ", startingAt: 0))"
                      + " → \(via)")
                print("      样式读数：\(styleReading?.summary ?? "读不到")")
                if !rawAttributes.isEmpty {
                    let described = rawAttributes.map { key, value -> String in
                        if let s = value as? NSAttributedString { return "\(key)=\(s.string)" }
                        return "\(key)=\(String(describing: value))"
                    }.joined(separator: " | ")
                    print("      原始属性：\(described)")
                }
            } else {
                failures.append("\(testCase.markdown): \(problems.joined(separator: "；"))")
                print("  ✗ \(testCase.markdown)  \(problems.joined(separator: "；"))")
            }

            cleanUp(note: note, from: ownedStart, expecting: testCase.expectedText)
        }

        print("")
        print("样式可读性检查（看看 AX 富文本属性里有什么）：")
        dumpStyleAttributes(note)

        print("")
        if runUndoCheck {
            print("撤销行为检查（--undo）：")
            checkUndo(app: app, note: note, engine: engine)
        } else {
            print("撤销行为检查：跳过（要跑加 --undo，它可能动到撤销栈顶的其它笔记）")
        }

        print("")
        let finalLength = note.textLength ?? -1
        print("测试后正文长度：\(finalLength)（测试前是 0）")
        if finalLength != 0 {
            print("⚠️ 正文里还残留 \(finalLength) 个字符，请手动检查这条笔记。")
        }
        if createdNote {
            print("")
            print("这次测试新建了一条草稿笔记（id \(note.noteID ?? "未知")），内容已清空。")
            print("按约定自检不删任何笔记，这条空草稿请你自己在备忘录里删掉。")
        }

        print("")
        print("结果：\(passed)/\(cases.count) 通过")
        if !failures.isEmpty {
            print("失败明细：")
            for failure in failures { print("  - \(failure)") }
        }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - 护栏 2：只删自己插入的那一段

    /// 删掉从 `from` 到正文末尾的内容，但删之前先确认那一段确实是自己插入的。
    ///
    /// `expecting` 是预期内容（去掉触发字符后的结果）。内容对不上就什么都不做——
    /// 说明期间有别的改动（比如用户敲了字），宁可留一点残留也不能误删。
    ///
    /// 段落级转换（`# `、`> ` 这类）会让 Notes 在段尾补一个换行，所以比较时允许
    /// 尾部多出换行；但只允许换行，出现任何别的字符就放弃清理。
    private static func cleanUp(note: NoteTextElement, from start: Int, expecting: String) {
        guard let text = note.text() else { return }
        let ns = text as NSString
        guard ns.length > start else { return }

        let tail = ns.substring(from: start)
        let expectedTail = "\n" + expecting
        // 段落级转换会让 Notes 在段尾补换行，所以两边都归一化后再比
        let normalize: (String) -> String = { value in
            var trimmed = value
            while trimmed.hasSuffix("\n") { trimmed.removeLast() }
            return trimmed
        }

        guard normalize(tail) == normalize(expectedTail) else {
            print("    （跳过清理：尾部 \(tail.debugDescription) 与预期 \(expectedTail.debugDescription) 不符）")
            return
        }
        _ = note.replace(NSRange(location: start, length: ns.length - start), with: "")
        usleep(60_000)
    }

    // MARK: - 辅助

    /// 当前段落样式的候选集合，按用途分组。
    static let paragraphStyleCandidates: [NotesAction] = [
        .title, .heading, .subheading, .body, .monospaced,
        .bulletedList, .dashedList, .numberedList, .checklist, .blockQuote,
    ]

    /// 当前段落是哪个样式——读菜单项的勾选状态。
    ///
    /// 为什么用勾选状态：它是备忘录自己的 UI 状态，与界面语言无关。备选信号都不行——
    /// `AXStyleName` 是本地化字符串，而且列表段落读出来是 nil；`AXHeadingLevel` /
    /// `AXBlockQuoteLevel` 这两个 macOS 26 新增的属性在备忘录里恒为 nil（实测）。
    ///
    /// **必须读两次**：勾选状态是懒验证的，紧跟应用之后那一次读到的是**上一个**样式
    /// （实测 `dashedList` 会读成 `bulletedList`、`checklist` 读成 `numberedList`）。
    /// 隔 250ms 再读一次就是当前值。
    private static func checkedParagraphStyles(engine: NotesEngine) -> Set<NotesAction> {
        func readOnce() -> Set<NotesAction> {
            let fresh = engine.refreshMenuIndex()
            return Set(paragraphStyleCandidates.filter { fresh.resolve($0)?.item.isChecked == true })
        }
        // 读三次：勾选是懒验证的，紧跟应用之后那次读到的是上一个样式
        _ = readOnce()
        usleep(250_000)
        let second = readOnce()
        if second.count == 1 { return second }
        usleep(250_000)
        return readOnce()
    }

    private static func readCurrentParagraph(_ note: NoteTextElement) -> String? {
        guard let text = note.text(), let caret = note.selectedRange?.location else { return nil }
        let ns = text as NSString
        let range = MarkdownRecognizer.paragraphRange(in: ns, containing: caret)
        guard NSMaxRange(range) <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    /// 把光标所在段的富文本属性键打出来。AX 的属性键是私有约定，得先看一眼才知道怎么判样式。
    private static func dumpStyleAttributes(_ note: NoteTextElement) {
        guard let text = note.text(), let caret = note.selectedRange?.location else {
            print("  读不到文本或光标")
            return
        }
        let ns = text as NSString
        var range = MarkdownRecognizer.paragraphRange(in: ns, containing: max(0, caret - 1))
        if range.length == 0 {
            range = MarkdownRecognizer.paragraphRange(in: ns, containing: caret)
        }
        guard range.length > 0, NSMaxRange(range) <= ns.length else {
            print("  光标所在段是空的，跳过")
            return
        }
        guard let attributed = note.attributedString(in: range) else {
            print("  读不到富文本")
            return
        }
        print("  段落 \(ns.substring(with: range).debugDescription) 的属性（含取值）：")
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            print("    {\(range.location),\(range.length)}")
            for (key, value) in attributes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let described: String
                if let s = value as? NSAttributedString { described = "\(s.string)" }
                else { described = String(describing: value) }
                print("        \(key.rawValue) = \(described)")
            }
        }
        if let level = note.headingLevel { print("  AXHeadingLevel = \(level)") }
        if let level = note.blockQuoteLevel { print("  AXBlockQuoteLevel = \(level)") }
    }

    /// 撤销检查：插一段 → 转换 → 连续撤销 → 看回到 Markdown 原文需要几次。
    ///
    /// 这决定这套实现能不能被用户接受：如果按一次 ⌘Z 就能退回 Markdown 原文，体验是完整的；
    /// 如果要按四五次才退回去，说明每次 AX 改写都单独进了撤销栈，需要重新设计（比如把
    /// 「删分隔符 + 应用样式」合成一步，或改用合成按键让它走 Notes 的正常编辑路径）。
    ///
    /// **默认不跑**：备忘录的撤销栈可能跨笔记，万一栈顶不是本次测试的操作，撤销就会改到
    /// 别的笔记上。要跑必须显式加 `--undo`，并且只在专用草稿笔记里跑。
    ///
    /// 撤销走菜单项 AXPress（按 ⌘Z 快捷键匹配），不用合成按键——实测合成的按键触发不了
    /// 备忘录的菜单快捷键。
    private static func checkUndo(app: NotesApp, note: NoteTextElement, engine: NotesEngine) {
        guard let text = note.text() ?? Optional(""), let caret = note.selectedRange?.location else {
            print("  读不到文本"); return
        }
        let ns = text as NSString
        let ownedStart = ns.length
        _ = caret

        let markdown = "**undotest**"
        guard note.insert("\n" + markdown, at: ownedStart) else {
            print("  插入失败"); return
        }
        usleep(180_000)
        let beforeText = note.text() ?? ""

        let outcome = engine.handleTextChange()
        guard outcome.didConvert else {
            print("  转换没发生（\(outcome.summary)），跳过撤销检查")
            cleanUp(note: note, from: ownedStart, expecting: markdown)
            return
        }
        usleep(200_000)
        let afterConvert = note.text() ?? ""
        print("  转换后正文：\(afterConvert.debugDescription)")
        if afterConvert == beforeText {
            print("  ⚠️ 转换没改动文本？")
        }

        guard let undo = engine.currentMenuIndex().item(
            withKeyEquivalent: KeyEquivalent(character: "z", modifiers: [.command])) else {
            print("  菜单里找不到 ⌘Z（撤销），无法检查")
            cleanUp(note: note, from: ownedStart, expecting: afterConvert)
            return
        }

        var steps = 0
        var restored = false
        var log: [String] = []
        for attempt in 1...6 {
            _ = MenuInvoker().invoke(undo, in: app)
            usleep(320_000)
            let current = note.text() ?? ""
            log.append("第 \(attempt) 次 ⌘Z → \(current.debugDescription)")
            steps = attempt
            if current.hasSuffix(markdown) {
                restored = true
                break
            }
        }
        for line in log { print("    \(line)") }

        if restored {
            print("  → 撤销干净：\(steps) 次 ⌘Z 退回 Markdown 原文")
        } else {
            print("  → ⚠️ 连续 6 次 ⌘Z 都没退回 Markdown 原文，需要重新设计改写方式")
        }

        // 把这段测试内容清掉（只删自己插入的那一段）
        if let current = note.text(), let baseline = note.textLength {
            let nsCurrent = current as NSString
            if nsCurrent.length > ownedStart {
                let tail = nsCurrent.substring(from: ownedStart)
                if tail.allSatisfy({ !$0.isLetter || markdown.contains($0) }) {
                    _ = note.replace(NSRange(location: ownedStart,
                                             length: nsCurrent.length - ownedStart), with: "")
                    usleep(150_000)
                } else {
                    print("    （跳过清理：尾部 \(tail.debugDescription) 不是本次插入的内容）")
                }
            }
            _ = baseline
        }
    }
}
