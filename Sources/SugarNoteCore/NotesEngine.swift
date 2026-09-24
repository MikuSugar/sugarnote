import ApplicationServices
import Foundation

/// 把「读文本 → 识别 → 改写 → 应用样式」串起来。
///
/// 一次转换的完整流程：
/// 1. 确认备忘录在前台、焦点在正文、输入法没在组字、光标是插入点而不是选区；
/// 2. 读整篇文本与光标位置；
/// 3. `MarkdownRecognizer` 判断是否刚敲完一个语法；
/// 4. 按降序删掉触发用的分隔符（先删后面的，前面的索引才不失效）；
/// 5. 设置选区（行内语法要选中中间内容，段落语法把光标放到段首）；
/// 6. 调 `MenuInvoker` 触发对应的备忘录菜单项；
/// 7. 行内语法把光标收到样式文本末尾，方便继续打字。
public final class NotesEngine {

    public struct Configuration: Sendable {
        /// 关掉某些动作（设置界面用）。
        public var disabledActions: Set<NotesAction> = []
        public var recognizer = RecognizerOptions()
        /// 应用样式后是否复核（关掉少几次跨进程读，但就没法自愈了）。
        /// 复核也能兜住「菜单项元素失活导致 AXPress 空转」这种间歇性失效。
        public var verifyCharacterStyles = true
        public init() {}
    }

    public enum Outcome: Sendable {
        case ignored(String)
        case converted(plan: EditPlan, outcomes: [ActionOutcome])
        case failed(String)

        public var didConvert: Bool {
            if case .converted = self { return true }
            return false
        }

        public var summary: String {
            switch self {
            case .ignored(let reason):
                return "跳过：\(reason)"
            case .failed(let reason):
                return "失败：\(reason)"
            case .converted(let plan, let outcomes):
                let actions = outcomes.map(\.summary).joined(separator: ", ")
                let range = plan.replacement.range
                return "转换：改写 {\(range.location),\(range.length)} → "
                    + "\(plan.replacement.text.debugDescription) → \(actions)"
            }
        }
    }

    public var configuration: Configuration
    public var log: ((String) -> Void)?

    private let app: NotesApp
    private let invoker = MenuInvoker()
    private var menuIndex: MenuIndex?

    /// 我们自己改完文本后，Notes 会再发一轮通知。记下预期状态，
    /// 下一条与之完全相符的通知就是自己造成的，跳过。
    /// 比单纯用时间窗好——不会把用户在 350ms 内敲的下一个字符一起吃掉。
    private var selfEditExpectation: (text: String, caret: Int)?

    public init(app: NotesApp, configuration: Configuration = Configuration()) {
        self.app = app
        self.configuration = configuration
    }

    // MARK: - 菜单索引

    /// 重新扫描 Notes 菜单。Notes 重启或升级后要调。
    @discardableResult
    public func refreshMenuIndex() -> MenuIndex {
        let index = MenuIndex(menuBarSnapshot: app.menuBarSnapshot())
        menuIndex = index
        if !index.unresolvedActions.isEmpty {
            let names = index.unresolvedActions.map(\.rawValue).joined(separator: ", ")
            log?("菜单里没找到这些动作：\(names)")
        }
        return index
    }

    public func currentMenuIndex() -> MenuIndex {
        menuIndex ?? refreshMenuIndex()
    }

    // MARK: - 主流程

    /// 处理一次「正文可能变了」。由 `NotesWatcher` 在收到 AX 通知时调用。
    @discardableResult
    public func handleTextChange() -> Outcome {
        guard app.isFrontmost else { return .ignored("备忘录不在前台") }
        guard let note = app.focusedNoteText() else { return .ignored("焦点不在笔记正文") }
        guard !note.isComposing else { return .ignored("输入法正在组字") }
        guard let caretRange = note.selectedRange else { return .ignored("读不到光标位置") }
        guard caretRange.length == 0 else { return .ignored("当前是选区不是插入点") }
        let text = note.text() ?? ""

        let caret = caretRange.location

        if let expected = selfEditExpectation {
            if expected.text == text && expected.caret == caret {
                selfEditExpectation = nil
                return .ignored("自触发")
            }
            selfEditExpectation = nil
        }

        let nsText = text as NSString
        guard let plan = MarkdownRecognizer.recognize(
            text: nsText, caret: caret, options: configuration.recognizer)
        else { return .ignored("没有匹配的语法") }

        if let blocked = plan.actions.first(where: configuration.disabledActions.contains) {
            return .ignored("动作 \(blocked.rawValue) 已被禁用")
        }

        return apply(plan, to: note)
    }

    /// 执行一次转换。公开出来是为了让 CLI 能在受控测试里直接调用。
    @discardableResult
    public func apply(_ plan: EditPlan, to note: NoteTextElement) -> Outcome {
        let index = currentMenuIndex()

        // 1. 一次原子替换。只做一次是为了撤销步数可控——拆成多次改写会留下中间状态。
        guard note.replace(plan.replacement.range, with: plan.replacement.text) else {
            return .failed("改写 {\(plan.replacement.range.location),"
                           + "\(plan.replacement.range.length)} 失败")
        }

        // 2. 选区。只在和现状不同时才写，避免多余回写抢用户下一个字符的位置。
        if let selection = plan.selection, note.selectedRange != selection {
            guard note.setSelectedRange(selection) else { return .failed("设置选区失败") }
        }

        // 3. 依次触发菜单项
        var outcomes: [ActionOutcome] = []
        for action in plan.actions {
            guard let match = index.resolve(action) else {
                outcomes.append(ActionOutcome(action: action, method: .failed,
                                              alreadyApplied: false, verified: nil))
                log?("菜单里找不到 \(action.rawValue)，跳过")
                continue
            }
            outcomes.append(apply(action, using: match, to: note))
        }

        // 4. 光标归位。只在确实不在这儿时才写——多余的回写会和用户正在敲的下一个字符
        //    抢位置（实测会把 `标题` 变成 `题标`）。
        if let caretAfter = plan.caretAfter {
            let target = NSRange(location: caretAfter, length: 0)
            if note.selectedRange != target {
                note.setSelectedRange(target)
            }
        }

        // 5. 记下预期状态，用来识别下一轮通知是不是自己造成的
        if let after = note.text(), let caretAfter = note.selectedRange?.location {
            selfEditExpectation = (after, caretAfter)
        }

        return .converted(plan: plan, outcomes: outcomes)
    }

    // MARK: - 单个动作

    /// 触发一个动作。字符样式和段落样式的语义不同，分开处理。
    private func apply(_ action: NotesAction,
                       using match: MenuIndex.Match,
                       to note: NoteTextElement) -> ActionOutcome {
        // 段落样式（标题/小标题/正文/等宽/各种列表/引用）是**单选**语义：
        // 选中的样式替换掉原来的，再选一次不会切回正文，所以不需要「已应用就跳过」。
        // 但仍然要复核：菜单项元素可能失活导致 AXPress 空转。
        guard !action.isParagraphLevel else {
            let result = invoker.invoke(match.item, in: app)
            if !result.success {
                log?("触发 \(action.rawValue)（\(match.item.pathString)）失败")
                return ActionOutcome(action: action, method: result.method,
                                     alreadyApplied: false, verified: false)
            }
            guard configuration.verifyCharacterStyles else {
                return ActionOutcome(action: action, method: result.method,
                                     alreadyApplied: false, verified: nil)
            }
            usleep(120_000)
            if paragraphStyleMatches(action, engine: self) {
                return ActionOutcome(action: action, method: result.method,
                                     alreadyApplied: false, verified: true)
            }
            log?("\(action.rawValue) 复核未通过，重扫菜单后补触发一次")
            let retryItem = refreshMenuIndex().resolve(action)?.item ?? match.item
            _ = invoker.invoke(retryItem, in: app)
            usleep(120_000)
            return ActionOutcome(action: action, method: result.method,
                                 alreadyApplied: false,
                                 verified: paragraphStyleMatches(action, engine: self))
        }

        // 字符样式是**切换**语义：目标已经是该样式时再触发一次会把它切掉。
        // 刚敲进来的 Markdown 文本会继承光标处的打字属性，所以「本来就是粗体」是常见情况，
        // 不能无脑按。先读状态。
        let target = currentSelectionRange(of: note)
        let current = target.flatMap { note.styleReading(in: $0) }
        guard CharacterStylePolicy.shouldInvoke(action, current: current) else {
            return ActionOutcome(action: action, method: nil,
                                 alreadyApplied: true, verified: true)
        }

        let result = invoker.invoke(match.item, in: app)
        if !result.success {
            log?("触发 \(action.rawValue)（\(match.item.pathString)）失败")
            return ActionOutcome(action: action, method: result.method,
                                 alreadyApplied: false, verified: false)
        }

        guard configuration.verifyCharacterStyles, let target else {
            return ActionOutcome(action: action, method: result.method,
                                 alreadyApplied: false, verified: nil)
        }

        // 复核。判断错了的话（把原本就有的样式切掉了）补按一次，让它自愈。
        usleep(120_000)
        guard let isOn = CharacterStylePolicy.isSatisfied(
            action, after: note.styleReading(in: target)) else {
            return ActionOutcome(action: action, method: result.method,
                                 alreadyApplied: false, verified: nil)
        }
        if isOn {
            return ActionOutcome(action: action, method: result.method,
                                 alreadyApplied: false, verified: true)
        }

        // 补触发。这次重新扫一遍菜单拿**新的** AX 元素——`MenuItemSnapshot` 里存的是
        // 快照时刻的元素引用，菜单项重新验证过之后旧引用会失活，
        // 表现是 AXPress 返回成功但什么都没发生（实测过这种间歇性失效）。
        log?("\(action.rawValue) 复核未通过，重扫菜单后补触发一次")
        let freshIndex = refreshMenuIndex()
        let retryItem = freshIndex.resolve(action)?.item ?? match.item
        _ = invoker.invoke(retryItem, in: app)
        usleep(120_000)
        let final = CharacterStylePolicy.isSatisfied(action, after: note.styleReading(in: target))
        return ActionOutcome(action: action, method: result.method,
                             alreadyApplied: false, verified: final)
    }

    /// 段落样式是否已生效——读菜单项的勾选状态。
    ///
    /// **必须读两次**：勾选状态是懒验证的，紧跟应用之后那次读到的是上一个样式
    /// （实测 `dashedList` 读成 `bulletedList`、`checklist` 读成 `numberedList`）。
    ///
    /// 只做「目标样式是否被勾上」这一个判断，不断言「没有别的样式被勾上」——
    /// 块引用可以和标题共存，而懒验证会让别的项短暂地还勾着。
    private func paragraphStyleMatches(_ action: NotesAction, engine: NotesEngine) -> Bool {
        let fresh = refreshMenuIndex()
        if fresh.resolve(action)?.item.isChecked == true { return true }
        usleep(250_000)
        return refreshMenuIndex().resolve(action)?.item.isChecked == true
    }

    /// 当前选区。复核样式要按同一个范围读，所以抽出来。
    private func currentSelectionRange(of note: NoteTextElement) -> NSRange? {
        guard let range = note.selectedRange, range.length > 0 else { return nil }
        return range
    }

    // MARK: - 诊断

    /// 光标所在段落的文本，用于调试面板。
    public func currentParagraph() -> String? {
        guard let note = app.focusedNoteText() ?? app.anyNoteText() else { return nil }
        guard let text = note.text(), let caret = note.selectedRange?.location else { return nil }
        let ns = text as NSString
        let range = MarkdownRecognizer.paragraphRange(in: ns, containing: caret)
        guard range.length >= 0, NSMaxRange(range) <= ns.length else { return nil }
        return ns.substring(with: range)
    }
}
