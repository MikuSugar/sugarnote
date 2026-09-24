import ApplicationServices
import AppKit
import Foundation

/// 备忘录 App 的 AX 句柄。
///
/// 只负责「找到 Notes」和「找到正文元素」，不做文本读写（那是 `NoteTextElement` 的事）。
///
/// 线程约定：AX 客户端是线程安全的，但为了避免在多个隔离域之间传递 CF 类型，
/// 这里标 `@unchecked Sendable`，调用方保证同一实例的顺序使用。
public final class NotesApp: @unchecked Sendable {

    public static let bundleIdentifier = "com.apple.Notes"

    /// 正文元素的 AX identifier 形如 `Note[id=B3A15D4A-BB70-4E23-8000-CB1DBC5AE43D]`。
    public static let noteIdentifierPrefix = "Note[id="

    public let pid: pid_t
    public let element: AXUIElement

    private init(pid: pid_t, element: AXUIElement) {
        self.pid = pid
        self.element = element
    }

    /// 备忘录没在运行就返回 nil。
    public static func running() -> NotesApp? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first
        else { return nil }
        return make(pid: app.processIdentifier)
    }

    public static func make(pid: pid_t) -> NotesApp {
        let el = AXUIElementCreateApplication(pid)
        // AX 调用是跨进程同步 IPC，Notes 卡住时不能让调用方无限等
        AXUIElementSetMessagingTimeout(el, 2.0)
        return NotesApp(pid: pid, element: el)
    }

    public var isFrontmost: Bool {
        NSRunningApplication(processIdentifier: pid)?.isActive ?? false
    }

    /// 把备忘录切到前台。
    ///
    /// 主路径是辅助功能的 `AXFrontmost`：从后台进程调 `NSRunningApplication.activate()`
    /// 在 macOS 14+ 会被忽略（实测拿着辅助功能权限也提不起来），而 `AXFrontmost`
    /// 正是辅助类 App 把目标 App 提到前台的接口。两条路都试、反复试，因为切换有几帧延迟。
    ///
    /// 为什么一定要前台：备忘录的菜单项在它不活跃时是禁用的，AXPress 会失败。
    @discardableResult
    public func activate(timeout: TimeInterval = 5) -> Bool {
        let running = NSRunningApplication(processIdentifier: pid)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running?.isActive == true { return true }
            AX.set(element, kAXFrontmostAttribute as String, kCFBooleanTrue)
            running?.activate()
            // 窗口也提一下：AXFrontmost 有时只改了标志位，窗口还压在别的 App 后面
            if let window = AX.element(element, AX.Attr.focusedWindow) {
                AX.perform(window, kAXRaiseAction as String)
            }
            usleep(150_000)
        }
        return running?.isActive ?? false
    }

    public var localizedName: String? {
        AX.string(element, AX.Attr.title)
    }

    // MARK: - 正文元素

    /// 当前正在编辑的笔记正文。没有聚焦在正文里（比如光标在搜索框、侧边栏）就返回 nil。
    public func focusedNoteText() -> NoteTextElement? {
        if let focused = AX.element(element, AX.Attr.focusedUIElement),
           let note = NoteTextElement.from(element: focused) {
            return note
        }
        return nil
    }

    /// 遍历窗口找正文元素，用于「焦点不在正文但窗口里有笔记」的场景（例如读状态）。
    public func anyNoteText() -> NoteTextElement? {
        if let focused = focusedNoteText() { return focused }

        var roots = AX.elements(element, AX.Attr.windows)
        if let focusedWindow = AX.element(element, AX.Attr.focusedWindow) {
            roots.insert(focusedWindow, at: 0)
        }
        for root in roots {
            if let found = Self.firstNoteText(in: root, depth: 0) { return found }
        }
        return nil
    }

    /// 把键盘焦点移到笔记正文。焦点可能停在侧边栏或搜索框上，写文本前需要先回到正文。
    ///
    /// 只移动焦点，不改内容。
    @discardableResult
    public func focusNoteBody() -> NoteTextElement? {
        if let focused = focusedNoteText() { return focused }
        guard let note = anyNoteText() else { return nil }
        AX.set(note.element, kAXFocusedAttribute as String, kCFBooleanTrue)
        // 焦点变更要过一轮 run loop 才生效
        usleep(200_000)
        return focusedNoteText() ?? note
    }

    private static func firstNoteText(in node: AXUIElement, depth: Int) -> NoteTextElement? {
        guard depth < 40 else { return nil }
        if AX.string(node, AX.Attr.role) == AX.Role.textArea,
           let note = NoteTextElement.from(element: node) {
            return note
        }
        for child in AX.elements(node, AX.Attr.children) {
            if let found = firstNoteText(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - 菜单栏

    /// 取菜单栏快照。
    ///
    /// 必须先打开 `AXEnhancedUserInterface`：AppKit 默认不填充没被展开过的子菜单，
    /// 不开的话只能拿到菜单栏顶层那几项。
    public func menuBarSnapshot() -> [MenuItemSnapshot] {
        let key = AX.Attr.enhancedUserInterface
        let original = AX.raw(element, key)
        AX.set(element, key, kCFBooleanTrue)
        defer {
            if let original {
                AX.set(element, key, original)
            } else {
                AX.set(element, key, kCFBooleanFalse)
            }
        }

        guard let bar = AX.element(element, AX.Attr.menuBar) else { return [] }
        return MenuWalker.snapshot(of: bar)
    }

    // MARK: - 辅助

    /// 新建一条笔记（⌘N）。用于测试，不会碰用户已有的内容。
    public func openNewNote() {
        NSRunningApplication(processIdentifier: pid)?.activate()
        // 让 Notes 拿到前台后再发 ⌘N，否则按键会落到别的 App
        usleep(250_000)
        KeySynthesizer.postCommandKey("n", to: pid)
        usleep(250_000)
    }
}
