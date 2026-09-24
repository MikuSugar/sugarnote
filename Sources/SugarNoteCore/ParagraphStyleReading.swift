import Foundation

/// 段落样式的可观测读数。
///
/// AX 侧的样式信号有好几种，可靠性不一：`AXStyleName` 是段落样式的名字（最直接），
/// `AXHeadingLevel` / `AXBlockQuoteLevel` 是 macOS 26 起新增的结构化属性，
/// 字符样式（粗体/斜体等）则藏在 `AXAttributedStringForRange` 的私有属性键里。
/// 全记下来是为了在没搞清楚哪个最可靠之前先观察，再挑出能当断言用的那个。
public struct ParagraphStyleReading: Equatable, Sendable {
    public var styleName: String?
    public var fontFamily: String?
    public var fontName: String?
    public var fontSize: Double?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var headingLevel: Int?
    public var blockQuoteLevel: Int?

    public init(styleName: String? = nil, fontFamily: String? = nil, fontName: String? = nil,
                fontSize: Double? = nil, bold: Bool? = nil, italic: Bool? = nil,
                underline: Bool? = nil, strikethrough: Bool? = nil,
                headingLevel: Int? = nil, blockQuoteLevel: Int? = nil) {
        self.styleName = styleName
        self.fontFamily = fontFamily
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.headingLevel = headingLevel
        self.blockQuoteLevel = blockQuoteLevel
    }

    /// 字体名里带 Bold / Emphasized / Italic / Oblique 之类的字样。
    ///
    /// 备忘录没有 `AXBold` / `AXItalic` 这样的标志位，粗体斜体只能从字体名认。
    /// 系统字体在粗体+斜体时叫 `.AppleSystemUIFontEmphasizedItalic`（用 Emphasized
    /// 表示粗），所以两个词都得认。
    public var looksBold: Bool {
        let name = (fontName ?? "").lowercased()
        return name.contains("bold") || name.contains("emphasized")
    }

    public var looksItalic: Bool {
        let name = (fontName ?? "").lowercased()
        return name.contains("italic") || name.contains("oblique")
    }

    /// 目标范围是不是已经带上了某个字符样式。
    ///
    /// 这是「切换语义」防呆的关键：判断为 true 就不该再触发菜单项，否则会把样式切掉。
    /// 返回 nil 表示这个动作不是字符样式，或者读数不足以判断。
    public func hasCharacterStyle(_ action: NotesAction) -> Bool? {
        switch action {
        case .bold: return looksBold
        case .italic: return looksItalic
        case .underline: return underline
        case .strikethrough: return strikethrough
        case .highlight:
            // 高亮在 AX 里没有独立标志位，只体现在 AXStyleName 变成了复合样式名
            // （普通段落是「正文」，加了高亮是「正文, 紫色高亮标记」）。
            guard let styleName, !styleName.isEmpty else { return nil }
            return styleName.contains(",")
        default:
            return nil
        }
    }

    /// 一行可读的样式摘要，用于测试输出。
    public var summary: String {
        var parts: [String] = []
        if let styleName { parts.append("style=\(styleName)") }
        if let fontName { parts.append("font=\(fontName)") }
        if let fontSize { parts.append("size=\(fontSize)") }
        if bold == true { parts.append("bold") }
        if italic == true { parts.append("italic") }
        if underline == true { parts.append("underline") }
        if strikethrough == true { parts.append("strike") }
        if let headingLevel, headingLevel > 0 { parts.append("headingLevel=\(headingLevel)") }
        if let blockQuoteLevel, blockQuoteLevel > 0 { parts.append("quoteLevel=\(blockQuoteLevel)") }
        return parts.isEmpty ? "（无样式信号）" : parts.joined(separator: " ")
    }
}
