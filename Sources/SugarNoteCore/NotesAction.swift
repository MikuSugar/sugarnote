import Foundation

/// sugarnote 需要触发的备忘录动作。
///
/// 定位一个动作有两把钥匙，按可靠性排序：
/// 1. **快捷键**——和语言无关，最稳。比如粗体在中文/英文/日文系统下都是 ⌘B。
/// 2. **标题别名**——少数动作没有快捷键（删除线、粘贴为 Markdown、拷贝为 Markdown），
///    只能靠标题。别名表由 `Tools/gen-menu-aliases.py` 从 Notes 自带的
///    `MainMenu.loctable` 里把 40 多种语言的标题全捞出来生成。
public enum NotesAction: String, CaseIterable, Codable, Sendable {

    // 段落样式
    case title
    case heading
    case subheading
    case body
    case monospaced

    // 列表
    case bulletedList
    case dashedList
    case numberedList
    case checklist
    case markChecked
    case blockQuote

    // 字符样式
    case bold
    case italic
    case underline
    case strikethrough
    case highlight

    // 其它
    case newNote
    case table
    case insertDivider
    case addLink
    case pasteAsMarkdown
    case copyAsMarkdown

    // 对齐
    case alignLeft
    case alignRight
    case alignCenter
    case alignJustify

    /// 已知快捷键。菜单里读到的快捷键优先，这里只是「期望值」，用于在菜单里认出对应项。
    ///
    /// 取值来自 2026-09 macOS 27 中文界面实测（见 Tools/menudump.swift 的输出）。
    /// 菜单改名、换语言都不影响；只有 Apple 主动改快捷键时才需要动这里，
    /// 而那时 `MenuIndex` 会报告「解析不到」，不会静默用错。
    public var keyEquivalent: KeyEquivalent? {
        let cmd: Modifiers = [.command]
        let shiftCmd: Modifiers = [.shift, .command]
        let optCmd: Modifiers = [.option, .command]

        switch self {
        case .title:        return KeyEquivalent(character: "t", modifiers: shiftCmd)
        case .heading:      return KeyEquivalent(character: "h", modifiers: shiftCmd)
        case .subheading:   return KeyEquivalent(character: "j", modifiers: shiftCmd)
        case .body:         return KeyEquivalent(character: "b", modifiers: shiftCmd)
        case .monospaced:   return KeyEquivalent(character: "m", modifiers: shiftCmd)

        case .bulletedList: return KeyEquivalent(character: "7", modifiers: shiftCmd)
        case .dashedList:   return KeyEquivalent(character: "8", modifiers: shiftCmd)
        case .numberedList: return KeyEquivalent(character: "9", modifiers: shiftCmd)
        case .checklist:    return KeyEquivalent(character: "l", modifiers: shiftCmd)
        case .markChecked:  return KeyEquivalent(character: "u", modifiers: shiftCmd)

        case .blockQuote:   return KeyEquivalent(character: "'", modifiers: cmd)

        case .bold:         return KeyEquivalent(character: "b", modifiers: cmd)
        case .italic:       return KeyEquivalent(character: "i", modifiers: cmd)
        case .underline:    return KeyEquivalent(character: "u", modifiers: cmd)
        case .highlight:    return KeyEquivalent(character: "e", modifiers: shiftCmd)

        case .newNote:       return KeyEquivalent(character: "n", modifiers: cmd)
        case .table:         return KeyEquivalent(character: "t", modifiers: optCmd)
        case .insertDivider: return KeyEquivalent(character: "l", modifiers: cmd)
        case .addLink:       return KeyEquivalent(character: "k", modifiers: cmd)

        case .alignLeft:     return KeyEquivalent(character: "{", modifiers: cmd)
        case .alignCenter:   return KeyEquivalent(character: "|", modifiers: cmd)
        case .alignRight:    return KeyEquivalent(character: "}", modifiers: cmd)

        // 以下四项 Notes 没给快捷键，只能靠标题别名匹配
        case .strikethrough, .pasteAsMarkdown, .copyAsMarkdown, .alignJustify:
            return nil
        }
    }

    /// 所在父菜单的别名（用于消歧：比如「对齐」子菜单里有「左对齐」，
    /// 而表格的右键菜单里也可能有同名项）。
    public var parentAlias: String? {
        switch self {
        case .bold, .italic, .underline, .strikethrough, .highlight:
            return "fontMenu"
        case .alignLeft, .alignRight, .alignCenter, .alignJustify:
            return "alignmentMenu"
        default:
            return nil
        }
    }

    /// 段落级动作会作用到整个段落；字符级动作作用到选区。
    public var isParagraphLevel: Bool {
        switch self {
        case .title, .heading, .subheading, .body, .monospaced,
             .bulletedList, .dashedList, .numberedList, .checklist,
             .blockQuote, .table, .insertDivider, .alignLeft, .alignRight,
             .alignCenter, .alignJustify:
            return true
        case .bold, .italic, .underline, .strikethrough, .highlight,
             .addLink, .pasteAsMarkdown, .copyAsMarkdown, .markChecked,
             .newNote:
            return false
        }
    }
}

/// 标题别名表，数据来自 `Resources/menu-aliases.json`。
public enum MenuAliases {

    private static let table: [String: Set<String>] = load()

    /// 某个语义名（别名表的键）对应的所有语言标题。
    public static func titles(for name: String) -> Set<String> {
        table[name] ?? []
    }

    /// 判断标题是否属于某个语义名。
    public static func matches(_ title: String, _ name: String) -> Bool {
        titles(for: name).contains(title)
    }

    public static var allNames: [String] { table.keys.sorted() }

    private static func load() -> [String: Set<String>] {
        guard let url = Bundle.module.url(forResource: "menu-aliases", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aliases = root["aliases"] as? [String: [String]]
        else {
            return [:]
        }
        return aliases.mapValues(Set.init)
    }
}
