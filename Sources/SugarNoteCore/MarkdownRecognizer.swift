import Foundation

/// 一次文本改写：把 `range` 换成 `text`。
public struct Replacement: Equatable, Sendable {
    public var range: NSRange
    public var text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

/// 一次转换要做的事。
///
/// **文本改写刻意只做一次原子替换**（`**粗体**` 是「开分隔符+内容+闭分隔符 → 内容」，
/// 段落语法是「触发字符 → 空」），而不是「先删尾分隔符、再删首分隔符」。
///
/// 为什么坚持一次：备忘录的撤销栈按编辑事件分组，多一次 AX 改写就多一步撤销。
/// 实测拆成两次删除时，用户按一次 ⌘Z 会退到中间状态（正文变成 `**粗体`），
/// 要按两次才回到 `**粗体**`；而单字符样式的 `代码` 一次就够。行为不一致比慢一步更糟。
public struct EditPlan: Equatable, Sendable {
    public var replacement: Replacement
    /// 要应用样式的范围（替换后的坐标）。nil 表示不设选区——段落样式按光标所在段落生效。
    public var selection: NSRange?
    /// 替换完成后光标该去哪。nil 表示交给 AppKit 按编辑位置自动调整。
    ///
    /// 为什么需要区分：只有「闭合分隔符正好在光标处」时，把光标收到样式文本末尾才是
    /// 用户期望的；如果语法在光标前面（用户已经接着往下打了），动光标就会把用户的
    /// 输入位置抢走。
    public var caretAfter: Int?
    /// 依次调用的动作。多数情况只有一个，勾选清单需要「先转成核对清单再打勾」两个。
    public var actions: [NotesAction]

    public init(replacement: Replacement, selection: NSRange?,
                caretAfter: Int? = nil, actions: [NotesAction]) {
        self.replacement = replacement
        self.selection = selection
        self.caretAfter = caretAfter
        self.actions = actions
    }
}

public struct RecognizerOptions: Sendable {
    /// `__文本__` 映射到「下划线」而不是 Markdown 标准的「粗体」。
    /// Notes 有原生下划线样式，而 Markdown 没有，所以默认按 ProNotes 的习惯走。
    public var doubleUnderscoreMeansUnderline = true

    /// 是否把 `---` 识别为插入分隔线。
    public var recognizesDivider = true

    public init() {}
}

/// 从「文本 + 光标位置」判断用户是不是刚敲完一个 Markdown 语法。
///
/// 设计上刻意从**文本状态**触发，而不是从按键事件触发。好处是天然兼容输入法：
/// 中文输入法在拼字阶段不会把 `**` 提交进正文，所以我们根本看不到触发字符，
/// 也就不会在用户打拼音时误动作。
///
/// 不是完整的 CommonMark 解析器，只认那些「值得用快捷输入」的语法。
public enum MarkdownRecognizer {

    /// 段落分隔符。Notes 正文用 `\n`，U+2028/U+2029 一并兜住。
    /// 用 `UInt32` 存：emoji 这类代理对的标量值超出 `unichar` 的 16 位范围，
    /// 拿 `unichar(scalar.value)` 会直接崩。
    private static let paragraphBreakScalars: Set<UInt32> = [0x0A, 0x0D, 0x2028, 0x2029]

    private static func isParagraphBreak(_ scalar: Unicode.Scalar) -> Bool {
        paragraphBreakScalars.contains(scalar.value)
    }

    public static func recognize(text: NSString,
                                caret: Int,
                                options: RecognizerOptions = RecognizerOptions()) -> EditPlan? {
        guard caret > 0, caret <= text.length else { return nil }

        if let plan = recognizeParagraphTrigger(text: text, caret: caret, options: options) {
            return plan
        }
        return recognizeInlineTrigger(text: text, caret: caret, options: options)
    }

    // MARK: - 段落触发器

    /// 行首语法：`# `、`- [ ] `、`> `、```` ``` ```` 等。
    ///
    /// 只有整段从触发字符开始时才算——正文中间出现的 `# ` 不是标题语法。
    private static func recognizeParagraphTrigger(text: NSString,
                                                 caret: Int,
                                                 options: RecognizerOptions) -> EditPlan? {
        let start = paragraphStart(in: text, before: caret)
        guard start < caret else { return nil }
        let prefix = text.substring(with: NSRange(location: start, length: caret - start))

        // 触发字符必须在**段落开头**，但光标不必紧跟其后——用户敲完 `# ` 会接着敲标题
        // 文字，等我们去看的时候段落已经是 `# 标题` 了。所以匹配靠 `hasPrefix`，
        // 只删掉开头那段触发字符，其余内容原样保留。
        //
        // 选区不设（nil）：段落样式按光标所在段落生效，光标本来就还在这一段里；
        // 动光标反而会和用户正在敲的下一个字符抢位置。
        func plan(_ actions: [NotesAction], consume characters: Int) -> EditPlan {
            EditPlan(replacement: Replacement(range: NSRange(location: start, length: characters),
                                              text: ""),
                     selection: nil,
                     actions: actions)
        }

        // 顺序有讲究：长的、更具体的放前面
        if options.recognizesDivider, let consumed = dividerTriggerLength(prefix) {
            return plan([.insertDivider], consume: consumed)
        }
        if prefix.hasPrefix("```") {
            return plan([.monospaced], consume: 3)
        }
        // 核对清单要区分勾选态，放在普通列表前面
        if let (consumed, checked) = checklistTrigger(prefix) {
            return plan(checked ? [.checklist, .markChecked] : [.checklist], consume: consumed)
        }
        if prefix.hasPrefix("### ") {
            return plan([.subheading], consume: 4)
        }
        if prefix.hasPrefix("## ") {
            return plan([.heading], consume: 3)
        }
        if prefix.hasPrefix("# ") {
            return plan([.title], consume: 2)
        }
        if prefix.hasPrefix("> ") {
            return plan([.blockQuote], consume: 2)
        }
        // 下面几条备忘录自己就会转（智能列表），留着是为了用户关掉智能列表时兜底；
        // 开着的时候触发字符已经被备忘录消费掉了，我们根本看不到，不会重复处理。
        if prefix.hasPrefix("- ") || prefix.hasPrefix("* ") || prefix.hasPrefix("+ ") {
            return plan([.bulletedList], consume: 2)
        }
        if let consumed = orderedListTriggerLength(prefix) {
            return plan([.numberedList], consume: consumed)
        }
        return nil
    }

    /// 分隔线触发写法，返回要消费掉几个字符；不匹配返回 nil。
    private static func dividerTriggerLength(_ prefix: String) -> Int? {
        for marker in ["***", "___", "---"] where prefix.hasPrefix(marker) { return marker.count }
        for marker in ["——", "—"] where prefix.hasPrefix(marker) { return marker.count }
        return nil
    }

    /// 分隔线的触发写法。
    ///
    /// `---` 默认收不到：备忘录的**智能破折号**会把它变成 em dash `—`（实测 `--` 和
    /// `---` 都变成 `—`）。所以除了 `---` 本身，也认 `***` / `___`（这两个不受智能
    /// 破折号影响），以及已经被转成 em dash 的那种。
    private static func isDividerTrigger(_ prefix: String) -> Bool {
        switch prefix {
        case "---", "***", "___", "—", "——":
            return true
        default:
            return false
        }
    }

    /// 核对清单的触发写法，返回是否要打勾。
    ///
    /// 关键：必须接受**裸的** `[ ] ` / `[x] `，不能只认 `- [ ] `。
    /// 因为备忘录的智能列表会先把 `- ` 变成短划线列表，等我们看的时候正文里只剩 `[ ] `，
    /// 前面那个 `- ` 已经没了（实测：敲 `- [ ] ` 之后正文是 `[ ] `，段落已是短划线列表）。
    private static func checklistTrigger(_ prefix: String) -> (consumed: Int, checked: Bool)? {
        let candidates: [(String, Bool)] = [
            ("- [ ] ", false), ("- [x] ", true), ("- [X] ", true),
            ("* [ ] ", false), ("* [x] ", true), ("* [X] ", true),
            ("+ [ ] ", false), ("+ [x] ", true), ("+ [X] ", true),
            ("[ ] ", false), ("[] ", false), ("[x] ", true), ("[X] ", true),
            ("[ ]", false), ("[x]", true), ("[X]", true),
        ]
        for (marker, checked) in candidates where prefix.hasPrefix(marker) {
            return (marker.count, checked)
        }
        return nil
    }

    /// `1. ` `12. ` 这类有序列表标记，返回要消费掉几个字符；上限两位数字，避免把年份当列表。
    private static func orderedListTriggerLength(_ prefix: String) -> Int? {
        guard let dot = prefix.firstIndex(of: ".") else { return nil }
        let digits = prefix[prefix.startIndex..<dot]
        guard !digits.isEmpty, digits.count <= 2, digits.allSatisfy(\.isNumber) else { return nil }
        let after = prefix.index(after: dot)
        guard after < prefix.endIndex, prefix[after] == " " else { return nil }
        return digits.count + 2
    }

    // MARK: - 行内触发器

    /// 行内语法：光标刚落到闭合分隔符之后时，删掉首尾分隔符并把中间内容应用字符样式。
    ///
    /// 分隔符按长度降序检查：`**粗体**` 必须先于 `*斜体*` 匹配，否则 `**` 会被
    /// 当成两个单星号。
    private static let inlineDelimiters: [(marker: String, action: NotesAction)] = [
        ("**", .bold),
        ("__", .underline),
        ("~~", .strikethrough),
        ("==", .highlight),
        ("`", .monospaced),
        ("*", .italic),
        ("_", .italic),
    ]

    private static func recognizeInlineTrigger(text: NSString,
                                               caret: Int,
                                               options: RecognizerOptions) -> EditPlan? {
        let start = paragraphStart(in: text, before: caret)

        for (marker, action) in inlineDelimiters {
            let resolvedAction: NotesAction = {
                if marker == "__", !options.doubleUnderscoreMeansUnderline { return .bold }
                return action
            }()

            let length = (marker as NSString).length
            // 闭合分隔符：在段落开头到光标之间找最后一个完整的标记对。
            // 不要求它紧贴光标——用户可能敲完 `**粗体**` 又接着往下打了几个字，
            // 光标已经不在闭合标记后面了。
            let searchEnd = caret
            guard searchEnd - start >= length * 2 else { continue }
            let searchRange = NSRange(location: start, length: searchEnd - start)
            let closerStart = lastOccurrence(of: marker, in: text, within: searchRange)
            guard closerStart >= 0 else { continue }

            let closerRange = NSRange(location: closerStart, length: length)
            guard text.substring(with: closerRange) == marker else { continue }

            // 开分隔符：在段落开头到闭合分隔符之前，找最后一个
            let openerSearchRange = NSRange(location: start, length: closerStart - start)
            let openerStart = lastOccurrence(of: marker, in: text, within: openerSearchRange)
            guard openerStart >= 0 else { continue }

            let openerEnd = openerStart + length
            let innerLength = closerStart - openerEnd
            // 中间必须有内容，且不能跨段落
            guard innerLength > 0 else { continue }

            let innerRange = NSRange(location: openerEnd, length: innerLength)
            let inner = text.substring(with: innerRange)
            guard !inner.isEmpty else { continue }
            guard !inner.unicodeScalars.contains(where: isParagraphBreak) else { continue }
            // 首尾是空白的不算：`* 强调 *` 不是斜体
            guard let firstChar = inner.first, !firstChar.isWhitespace,
                  let lastChar = inner.last, !lastChar.isWhitespace else { continue }

            // 单字符分隔符的额外约束，避免在 `**粗体**` 里把内层当成 `*斜体*`
            if length == 1 {
                let markerChar = Character(marker)
                // 开分隔符前面不能还是同一个字符（`**` 的第二个星号不算开分隔符）
                if openerStart > start {
                    let before = text.substring(with: NSRange(location: openerStart - 1, length: 1))
                    if before == marker { continue }
                }
                // 中间不能含分隔符本身
                if inner.contains(markerChar) { continue }
                // 闭合分隔符后面不能紧跟同一个字符（那样说明还没输完，比如 `**a***`）
                let afterCloser = NSMaxRange(closerRange)
                if afterCloser < text.length {
                    let after = text.substring(with: NSRange(location: afterCloser, length: 1))
                    if after == marker { continue }
                }
            } else {
                // 多字符分隔符：开分隔符前面不能是同一个字符（`***` 的歧义情形）
                if openerStart > start {
                    let before = text.substring(with: NSRange(location: openerStart - 1, length: 1))
                    if before == String(marker.prefix(1)) { continue }
                }
            }

            // 反斜杠转义的不处理
            if openerStart > start {
                let before = text.substring(with: NSRange(location: openerStart - 1, length: 1))
                if before == "\\" { continue }
            }

            // 一次替换掉「开分隔符 + 内容 + 闭分隔符」，只留下内容。
            // 替换后内容的起点正好是开分隔符原来的位置。
            let whole = NSRange(location: openerStart, length: NSMaxRange(closerRange) - openerStart)
            let selection = NSRange(location: openerStart, length: innerLength)

            // 光标该去哪：闭合标记正好在光标处时，把它收到样式文本末尾，用户接着打字
            // 就是正常内容；如果语法在光标前面（用户已经往下打了），就按删掉的字符数
            // 把光标前移，保住用户当前的输入位置。
            let closerWasAtCaret = NSMaxRange(closerRange) == caret
            let caretAfter = closerWasAtCaret ? openerStart + innerLength : caret - 2 * length

            return EditPlan(
                replacement: Replacement(range: whole, text: inner),
                selection: selection,
                caretAfter: caretAfter,
                actions: [resolvedAction]
            )
        }
        return nil
    }

    // MARK: - 文本工具

    /// 光标所在段落的起点（`\n` 之后的第一个字符位置）。
    static func paragraphStart(in text: NSString, before location: Int) -> Int {
        var i = min(location, text.length)
        while i > 0 {
            if paragraphBreakScalars.contains(UInt32(text.character(at: i - 1))) { break }
            i -= 1
        }
        return i
    }

    /// 光标所在段落的完整范围，不含末尾的段落分隔符。
    public static func paragraphRange(in text: NSString, containing location: Int) -> NSRange {
        let start = paragraphStart(in: text, before: location)
        var end = min(location, text.length)
        while end < text.length, !paragraphBreakScalars.contains(UInt32(text.character(at: end))) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// 在 `range` 内找 `needle` 最后一次出现的位置，找不到返回 -1。
    static func lastOccurrence(of needle: String, in text: NSString, within range: NSRange) -> Int {
        guard range.length > 0 else { return -1 }
        let found = text.range(of: needle, options: .backwards, range: range)
        return found.location == NSNotFound ? -1 : found.location
    }
}
