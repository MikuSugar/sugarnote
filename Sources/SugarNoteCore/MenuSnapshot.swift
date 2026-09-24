import ApplicationServices
import Foundation

/// 菜单项的快捷键。
///
/// `AXMenuItemCmdModifiers` 的位含义（来自 `AXAttributeConstants.h`）：
/// bit0 ⇧、bit1 ⌥、bit2 ⌃、bit3 表示「不带 ⌘」。所以没设 bit3 时默认有 ⌘。
/// 实测：粗体 = 0（⌘B）、标题 = 1（⇧⌘T）、表格 = 2（⌥⌘T）、隐藏边栏 = 4（⌃⌘S）。
public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let control = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// 把 AX 的原始位图翻译成修饰键集合。
    public static func fromAX(_ raw: Int) -> Modifiers {
        var mods: Modifiers = []
        if raw & 0b0001 != 0 { mods.insert(.shift) }
        if raw & 0b0010 != 0 { mods.insert(.option) }
        if raw & 0b0100 != 0 { mods.insert(.control) }
        // bit3 = NoCommand，没设就是带 ⌘
        if raw & 0b1000 == 0 { mods.insert(.command) }
        return mods
    }

    public var displayString: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

public struct KeyEquivalent: Hashable, Sendable, Codable {
    /// 统一转小写后比较，这样 ⇧⌘T 和 ⌘t 不会因为大小写差异匹配不上。
    public let character: Character
    public let modifiers: Modifiers

    public init(character: Character, modifiers: Modifiers) {
        self.character = Character(character.lowercased())
        self.modifiers = modifiers
    }

    public var displayString: String {
        "\(modifiers.displayString)\(String(character).uppercased())"
    }

    // `Character` 不是 Codable，所以手写编解码，把字符存成字符串。
    private enum CodingKeys: String, CodingKey { case character, modifiers }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .character)
        guard let first = raw.first, raw.count == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .character, in: container, debugDescription: "快捷键必须正好一个字符")
        }
        self.init(character: first, modifiers: try container.decode(Modifiers.self, forKey: .modifiers))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(character), forKey: .character)
        try container.encode(modifiers, forKey: .modifiers)
    }
}

/// 一次菜单遍历得到的快照。菜单是运行时才发现的对象，快照下来之后就能脱离 AX 做匹配和测试。
/// 只支持编码（`dump-menus` 用）。快照永远是从活的 AX 树现生成的，不从 JSON 读回来，
/// 所以不需要 Decodable。
public final class MenuItemSnapshot: Encodable, @unchecked Sendable {
    public let title: String
    /// 从菜单栏顶层开始的路径，例如 `["格式", "字体", "粗体"]`
    public let path: [String]
    public let keyEquivalent: KeyEquivalent?
    public let markChar: String?
    public let enabled: Bool
    public let children: [MenuItemSnapshot]

    /// 真实的 AX 元素，触发菜单项时要用。不进 JSON——它是运行时的东西，编解码时忽略。
    public let axElement: AXUIElement

    public init(title: String, path: [String], keyEquivalent: KeyEquivalent?,
                markChar: String?, enabled: Bool, children: [MenuItemSnapshot],
                axElement: AXUIElement) {
        self.title = title
        self.path = path
        self.keyEquivalent = keyEquivalent
        self.markChar = markChar
        self.enabled = enabled
        self.children = children
        self.axElement = axElement
    }

    private enum CodingKeys: String, CodingKey {
        case title, path, keyEquivalent, markChar, enabled, children
    }

    /// 有勾选标记表示这个菜单项当前处于生效状态（例如「正文」打勾 = 光标所在段落是正文样式）。
    public var isChecked: Bool {
        !(markChar ?? "").isEmpty
    }

    public func flattened() -> [MenuItemSnapshot] {
        [self] + children.flatMap { $0.flattened() }
    }

    public var pathString: String { path.joined(separator: " > ") }
}

public enum MenuWalker {

    /// 遍历菜单栏生成快照。
    ///
    /// 关键点：菜单项装在 `AXMenu` 容器里（`AXMenuBarItem → AXMenu → AXMenuItem`），
    /// 遇到 `AXMenu` 必须继续往下展开，否则只能拿到菜单栏顶层那几项。
    public static func snapshot(of menuBar: AXUIElement) -> [MenuItemSnapshot] {
        walk(menuBar, path: [], depth: 0)
    }

    private static func walk(_ node: AXUIElement, path: [String], depth: Int) -> [MenuItemSnapshot] {
        guard depth < 8 else { return [] }
        var out: [MenuItemSnapshot] = []

        for child in AX.elements(node, AX.Attr.children) {
            let role = AX.string(child, AX.Attr.role) ?? ""

            // AXMenu 只是容器，把它的菜单项提升到当前层级
            if role == AX.Role.menu {
                out.append(contentsOf: walk(child, path: path, depth: depth + 1))
                continue
            }

            guard role == AX.Role.menuItem || role == AX.Role.menuBarItem else { continue }

            let title = AX.string(child, AX.Attr.title) ?? ""
            let keyEquivalent = readKeyEquivalent(child)
            let itemPath = path + [title]

            let item = MenuItemSnapshot(
                title: title,
                path: itemPath,
                keyEquivalent: keyEquivalent,
                markChar: AX.string(child, AX.Attr.menuItemMarkChar),
                enabled: AX.bool(child, AX.Attr.enabled) ?? true,
                children: walk(child, path: itemPath, depth: depth + 1),
                axElement: child
            )
            out.append(item)
        }
        return out
    }

    private static func readKeyEquivalent(_ element: AXUIElement) -> KeyEquivalent? {
        guard let character = AX.string(element, AX.Attr.menuItemCmdChar),
              let first = character.first,
              !first.isNewline, first != "\u{08}"   // 删除键之类不算快捷键
        else { return nil }

        let raw = AX.int(element, AX.Attr.menuItemCmdModifiers) ?? 0
        return KeyEquivalent(character: first, modifiers: Modifiers.fromAX(raw))
    }
}
