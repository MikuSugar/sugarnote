import ApplicationServices
import Foundation

/// 笔记正文元素的文本读写原语。
///
/// 重要约定：AX 的文本范围（`AXSelectedTextRange`、`AXStringForRange` 的入参等）
/// 全部是 **UTF-16 码元**偏移，和 `NSRange`/`NSString` 一致，和 Swift `String.Index`
/// 的「字符簇」计数不一致。所以这一层内部一律用 `NSString` 做切片，不碰 `String.Index`。
public struct NoteTextElement {

    public let element: AXUIElement

    /// 笔记的 UUID（从 identifier `Note[id=...]` 里解出来），拿不到就是 nil。
    public let noteID: String?

    init(element: AXUIElement, noteID: String?) {
        self.element = element
        self.noteID = noteID
    }

    /// 校验一个 AX 元素是不是备忘录正文。
    ///
    /// 主要依据是 role 是 `AXTextArea`，再加一个宽松的确认条件：identifier 形如
    /// `Note[id=...]`，或者父级滚动区 identifier 是 `Note Body Scroll View`。
    /// 这样万一 Apple 改了 identifier 的格式，还有父级这条线索兜底。
    public static func from(element: AXUIElement) -> NoteTextElement? {
        guard AX.string(element, AX.Attr.role) == AX.Role.textArea else { return nil }

        let identifier = AX.string(element, AX.Attr.identifier)
        let parentIdentifier = AX.element(element, AX.Attr.parent)
            .flatMap { AX.string($0, AX.Attr.identifier) }

        let fromIdentifier = identifier.flatMap(parseNoteID)
        let looksLikeNoteBody = fromIdentifier != nil || parentIdentifier == "Note Body Scroll View"
        guard looksLikeNoteBody else { return nil }

        return NoteTextElement(element: element, noteID: fromIdentifier)
    }

    /// `Note[id=B3A15D4A-...]` -> `B3A15D4A-...`
    static func parseNoteID(_ identifier: String) -> String? {
        let prefix = NotesApp.noteIdentifierPrefix
        guard identifier.hasPrefix(prefix), identifier.hasSuffix("]") else { return nil }
        let start = identifier.index(identifier.startIndex, offsetBy: prefix.count)
        let end = identifier.index(before: identifier.endIndex)
        let id = String(identifier[start..<end])
        return id.isEmpty ? nil : id
    }

    // MARK: - 读

    public var isSettableValue: Bool { AX.isSettable(element, AX.Attr.value) }
    public var isSettableSelectedText: Bool { AX.isSettable(element, AX.Attr.selectedText) }
    public var isSettableSelectedTextRange: Bool { AX.isSettable(element, AX.Attr.selectedTextRange) }

    /// 整篇文本（第一行是标题）。读一次是一次跨进程 IPC，长笔记要留意。
    ///
    /// 注意：**空笔记读出来是 nil，不是空串**——`AXValue` 属性还在，但取值会失败。
    /// 要判空请用 `textLength`/`isEmpty`，别拿这个的 nil 当"读失败"。
    public func text() -> String? {
        AX.string(element, AX.Attr.value)
    }

    /// 正文长度。空笔记算 0；元素真的失效了才返回 nil。
    ///
    /// 区分这两者靠 role 还读不读得出来：元素失效时连 role 都拿不到。
    public var textLength: Int? {
        if let text = text() { return (text as NSString).length }
        guard AX.string(element, AX.Attr.role) == AX.Role.textArea else { return nil }
        return 0
    }

    public var isEmpty: Bool {
        textLength == 0
    }

    public var selectedRange: NSRange? {
        AX.range(element, AX.Attr.selectedTextRange)
    }

    /// 输入法组字范围。长度大于 0 表示正在用输入法拼字（此时不要介入）。
    public var markedRange: NSRange? {
        AX.range(element, AX.Attr.textInputMarkedRange)
    }

    public var isComposing: Bool {
        (markedRange?.length ?? 0) > 0
    }

    public var selectedText: String? {
        AX.string(element, AX.Attr.selectedText)
    }

    /// 指定范围的子串。走参数化属性，只取需要的部分，不用读整篇。
    public func string(in range: NSRange) -> String? {
        guard range.length >= 0, let parameter = AX.cfRange(range) else { return nil }
        return AX.parameterizedString(element, AX.Attr.stringForRange, parameter)
    }

    /// 字符偏移 -> 视觉行号。
    public func lineNumber(at index: Int) -> Int? {
        guard let value = AX.parameterized(
            element, AX.Attr.lineForIndex, NSNumber(value: index)) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    /// 视觉行号 -> 字符范围。
    ///
    /// 注意这是**视觉行**（自动换行后的一行），不是段落。段落边界要自己在文本里找 `\n`。
    public func rangeOfLine(_ line: Int) -> NSRange? {
        guard let value = AX.parameterized(element, AX.Attr.rangeForLine, NSNumber(value: line)) else {
            return nil
        }
        return AX.range(value)
    }

    /// 光标所在视觉行的范围与文本。
    public func currentLine() -> (range: NSRange, text: String)? {
        guard let caret = selectedRange?.location else { return nil }
        guard let line = lineNumber(at: caret), let range = rangeOfLine(line) else { return nil }
        guard let text = string(in: range) else { return nil }
        return (range, text)
    }

    /// 带样式的富文本。
    ///
    /// **备忘录的 `AXAttributedStringForRange` 只认 `location == 0` 的范围**（实测：
    /// `{0,4}` 成功，`{1,3}` / `{2,2}` / `{4,1}` 一律返回 nil，而同样参数的
    /// `AXStringForRange` 是正常的）。这是它那个文本视图的实现怪癖，不是我们的用法问题。
    ///
    /// 所以这里统一「从 0 读到目标范围末尾，再在本地切出目标段」，对调用方保持
    /// 「传你要的范围」的直觉接口。参数类型必须是 `AXValue`(CFRange)——
    /// 传 `NSValue`(NSRange) 一次都读不到。
    public func attributedString(in range: NSRange) -> NSAttributedString? {
        guard range.length > 0, NSMaxRange(range) > 0 else { return nil }
        let end = NSMaxRange(range)
        guard let parameter = AX.cfRange(NSRange(location: 0, length: end)),
              let whole = AX.parameterized(
                element, AX.Attr.attributedStringForRange, parameter) as? NSAttributedString,
              whole.length >= end
        else { return nil }
        return whole.attributedSubstring(from: range)
    }

    /// 段落标题层级（1 起算，0 表示不是标题）。macOS 26 起 Notes 才暴露这个属性。
    public var headingLevel: Int? {
        AX.int(element, AX.Attr.headingLevel)
    }

    /// 块引用层级（1 起算，0 表示不是引用）。
    public var blockQuoteLevel: Int? {
        AX.int(element, AX.Attr.blockQuoteLevel)
    }

    /// 富文本属性，取**范围起点所在那一段**的属性。
    ///
    /// 只取第一段是有意的：一个范围可能横跨多个属性段（比如正文 + 末尾换行），
    /// 换行符带的是段落属性、没有字符样式，如果让后面的段覆盖前面的，
    /// 读「这段文本是不是粗体」就会读到换行的属性上去——实测踩过这个坑。
    public func attributes(in range: NSRange) -> [(key: String, value: Any)] {
        guard let attributed = attributedString(in: range) else { return [] }
        var first: [NSAttributedString.Key: Any] = [:]
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) {
            attributes, _, stop in
            first = attributes
            stop.pointee = true
        }
        return first.map { (key: $0.key.rawValue, value: $0.value) }.sorted { $0.key < $1.key }
    }

    /// 光标所在段落的样式读数。
    ///
    /// 用途是验证「样式到底有没有应用上」——只看文本变没变是不够的，
    /// 分隔符删掉了但样式没打上，文本一样是对的。
    public func paragraphStyle(at location: Int? = nil) -> ParagraphStyleReading? {
        guard let text = text(), let caret = selectedRange?.location else { return nil }
        let ns = text as NSString
        let probe = location ?? caret
        var range = MarkdownRecognizer.paragraphRange(in: ns, containing: probe)
        if range.length == 0 {
            // 段落是空的（比如刚转成列表），退一步读光标前一个字符的样式
            guard ns.length > 0 else { return nil }
            range = NSRange(location: min(max(0, caret - 1), ns.length - 1), length: 1)
        }
        return styleReading(in: range)
    }

    /// 指定范围的样式读数。判断字符样式要读选区，判断段落样式要读整段。
    public func styleReading(in range: NSRange) -> ParagraphStyleReading? {
        guard let text = text() else { return nil }
        let ns = text as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return nil }

        var attrs: [String: Any] = [:]
        for (key, value) in attributes(in: range) { attrs[key] = value }

        // `AXFont` 是字典（含 AXFontFamily / AXFontName / AXFontSize / AXVisibleName），
        // 不是 NSAttributedString——粗体和斜体就是靠字体名区分的（`.AppleSystemUIFontBold`
        // / `.AppleSystemUIFontItalic`），没有单独的 AXBold/AXItalic 标志位。
        let font = attrs["AXFont"] as? [String: Any]

        return ParagraphStyleReading(
            styleName: attrs["AXStyleName"] as? String,
            fontFamily: font?["AXFontFamily"] as? String,
            fontName: font?["AXFontName"] as? String,
            fontSize: (font?["AXFontSize"] as? NSNumber)?.doubleValue,
            bold: Self.flag(attrs["AXBold"]),
            italic: Self.flag(attrs["AXItalic"]),
            underline: Self.flag(attrs["AXUnderline"]),
            strikethrough: Self.flag(attrs["AXStrikethrough"]),
            headingLevel: headingLevel,
            blockQuoteLevel: blockQuoteLevel
        )
    }

    private static func flag(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return ["1", "true", "yes"].contains(text.lowercased()) }
        return nil
    }

    // MARK: - 写

    @discardableResult
    public func setSelectedRange(_ range: NSRange) -> Bool {
        guard let value = AX.cfRange(range) else { return false }
        return AX.set(element, AX.Attr.selectedTextRange, value) == .success
    }

    /// 把当前选区内容替换成 `text`（传空串就是删除选区）。
    ///
    /// 走的是 AppKit 的公开无障碍接口：先设 `AXSelectedTextRange` 再设 `AXSelectedText`。
    /// 比直接写 `AXValue` 好——不用重写整篇文本，也不会丢掉撤销记录。
    @discardableResult
    public func setSelectedText(_ text: String) -> Bool {
        AX.set(element, AX.Attr.selectedText, text as CFString) == .success
    }

    /// 用 `text` 替换 `range`。
    @discardableResult
    public func replace(_ range: NSRange, with text: String) -> Bool {
        guard setSelectedRange(range) else { return false }
        return setSelectedText(text)
    }

    @discardableResult
    public func delete(_ range: NSRange) -> Bool {
        replace(range, with: "")
    }

    /// 在 `location` 处插入文本，插完光标落在插入内容之后。
    @discardableResult
    public func insert(_ text: String, at location: Int) -> Bool {
        replace(NSRange(location: location, length: 0), with: text)
    }
}
