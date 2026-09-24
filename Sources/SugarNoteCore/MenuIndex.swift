import Foundation

/// 把语义动作解析到当前 Notes 版本、当前系统语言下的真实菜单项。
///
/// 这是 sugarnote 相对 ProNotes 最关键的一处改进。ProNotes 把「菜单标题路径」按
/// macOS 版本硬编码成 4 个 JSON（13.5 / 14.6 / 15.5 / 26.0），Notes 一改名就废
/// ——macOS 27 上它就是因为 `格式 > 文本` 被改名成 `格式 > 对齐` 而挂掉的。
///
/// 这里改成运行时遍历菜单栏现学：
/// 1. 先用**快捷键**认（与语言无关）；
/// 2. 再用**标题别名**兜底（没有快捷键的项）；
/// 3. 用「父菜单锚点」消歧——先结构性地认出字体子菜单/对齐子菜单/格式菜单，
///    再在锚点范围内匹配，避免同名项误伤。
public final class MenuIndex {

    public enum Method: String, Sendable {
        case keyEquivalent
        case titleAlias
    }

    public struct Match: Sendable {
        public let item: MenuItemSnapshot
        public let method: Method
    }

    /// 扁平化后的全部菜单项，顺序与菜单顺序一致。
    public let items: [MenuItemSnapshot]

    /// 结构性锚点：从菜单里现学出来的父菜单标题。
    public let formatMenuTitle: String?
    public let fontMenuTitle: String?
    public let alignmentMenuTitle: String?
    public let editMenuTitle: String?

    public init(menuBarSnapshot: [MenuItemSnapshot]) {
        self.items = menuBarSnapshot.flatMap { $0.flattened() }

        // 格式菜单 = 含「项目符号列表」(⇧⌘7) 的那个顶层菜单
        self.formatMenuTitle = Self.anchor(
            in: items, shortcut: NotesAction.bulletedList.keyEquivalent, component: .topLevel)
        // 字体子菜单 = 含「粗体」(⌘B) 的那个子菜单
        self.fontMenuTitle = Self.anchor(
            in: items, shortcut: NotesAction.bold.keyEquivalent, component: .parent)
        // 对齐子菜单 = 含「左对齐」(⌘{) 的那个子菜单
        self.alignmentMenuTitle = Self.anchor(
            in: items, shortcut: NotesAction.alignLeft.keyEquivalent, component: .parent)
        // 编辑菜单 = 含「添加链接…」(⌘K) 的那个顶层菜单
        self.editMenuTitle = Self.anchor(
            in: items, shortcut: NotesAction.addLink.keyEquivalent, component: .topLevel)
    }

    private enum Component { case topLevel, parent }

    private static func anchor(in items: [MenuItemSnapshot],
                               shortcut: KeyEquivalent?,
                               component: Component) -> String? {
        guard let shortcut else { return nil }
        guard let item = items.first(where: { $0.keyEquivalent == shortcut }) else { return nil }
        switch component {
        case .topLevel: return item.path.first
        case .parent: return item.path.count >= 2 ? item.path[item.path.count - 2] : nil
        }
    }

    // MARK: - 解析

    /// 解析一个动作。解析不到返回 nil——上层应当跳过这个动作而不是猜。
    public func resolve(_ action: NotesAction) -> Match? {
        let scoped = scope(for: action)

        // 1. 快捷键
        if let shortcut = action.keyEquivalent {
            let hits = scoped.filter { $0.keyEquivalent == shortcut }
            if let hit = hits.first { return Match(item: hit, method: .keyEquivalent) }
        }

        // 2. 标题别名
        let aliases = MenuAliases.titles(for: action.rawValue)
        if !aliases.isEmpty {
            let hits = scoped.filter { aliases.contains($0.title) }
            if let hit = hits.first { return Match(item: hit, method: .titleAlias) }
        }

        // 3. 别名没命中时，用「父菜单别名」再试一次
        if let parentAlias = action.parentAlias {
            let parentTitles = MenuAliases.titles(for: parentAlias)
            if !parentTitles.isEmpty {
                let hits = scoped.filter { $0.path.contains(where: parentTitles.contains) }
                if let hit = hits.first { return Match(item: hit, method: .titleAlias) }
            }
        }

        return nil
    }

    /// 把搜索范围收敛到该动作应该在的菜单里。范围收得越准，同名项误匹配的机会越小。
    private func scope(for action: NotesAction) -> [MenuItemSnapshot] {
        switch action {
        case .bold, .italic, .underline, .strikethrough, .highlight:
            if let fontMenuTitle {
                let scoped = items.filter { $0.path.contains(fontMenuTitle) && $0.children.isEmpty }
                if !scoped.isEmpty { return scoped }
            }
            return items.filter { $0.children.isEmpty }

        case .alignLeft, .alignRight, .alignCenter, .alignJustify:
            if let alignmentMenuTitle {
                let scoped = items.filter { $0.path.contains(alignmentMenuTitle) && $0.children.isEmpty }
                if !scoped.isEmpty { return scoped }
            }
            return items.filter { $0.children.isEmpty }

        case .pasteAsMarkdown, .copyAsMarkdown, .addLink, .insertDivider:
            if let editMenuTitle {
                let scoped = items.filter { $0.path.first == editMenuTitle && $0.children.isEmpty }
                if !scoped.isEmpty { return scoped }
            }
            return items.filter { $0.children.isEmpty }

        case .newNote:
            // 新建备忘录在文件菜单里，⌘N 全局唯一，不需要额外收窄范围
            return items.filter { $0.children.isEmpty }

        case .title, .heading, .subheading, .body, .monospaced,
             .bulletedList, .dashedList, .numberedList, .checklist, .markChecked,
             .blockQuote, .table:
            if let formatMenuTitle {
                let scoped = items.filter { $0.path.first == formatMenuTitle && $0.children.isEmpty }
                if !scoped.isEmpty { return scoped }
            }
            return items.filter { $0.children.isEmpty }
        }
    }

    // MARK: - 报告

    /// 全部动作的解析结果，用于诊断（CLI `sugarnote-cli menus`）。
    public func report() -> [(action: NotesAction, match: Match?)] {
        NotesAction.allCases.map { ($0, resolve($0)) }
    }

    /// 按快捷键找菜单项。
    ///
    /// 给不属于 `NotesAction` 目录的命令用（撤销、重做这类编辑命令）。按快捷键匹配
    /// 与语言无关，比按标题稳。
    public func item(withKeyEquivalent key: KeyEquivalent) -> MenuItemSnapshot? {
        items.first { $0.keyEquivalent == key && $0.children.isEmpty }
    }

    /// 解析不到的动作。非空表示 Notes 的菜单变了，需要跟进。
    public var unresolvedActions: [NotesAction] {
        report().compactMap { $0.match == nil ? $0.action : nil }
    }
}
