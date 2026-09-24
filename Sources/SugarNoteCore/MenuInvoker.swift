import ApplicationServices
import Foundation

/// 触发备忘录的菜单项。
///
/// 两条路，按可靠性排序：
/// 1. **AXPress**——直接让菜单项执行它的 action。不需要展开菜单、不依赖键盘布局，
///    对没有快捷键的项（删除线、粘贴为 Markdown、拷贝为 Markdown）同样有效。
///    实测 Notes 27 的菜单项都暴露 `AXPress`（`actions=["AXCancel","AXPress","AXPick"]`）。
/// 2. **合成快捷键**——AXPress 失败时的兜底，要求该项自带快捷键。
public struct MenuInvoker: Sendable {

    public enum Method: String, Sendable {
        case axPress
        case keyEquivalent
        case failed
    }

    public struct Result: Sendable {
        public let method: Method
        public var success: Bool { method != .failed }
    }

    public init() {}

    @discardableResult
    public func invoke(_ item: MenuItemSnapshot, in app: NotesApp) -> Result {
        if AX.perform(item.axElement, kAXPressAction as String) == .success {
            return Result(method: .axPress)
        }
        if let key = item.keyEquivalent {
            KeySynthesizer.post(key, to: app.pid)
            return Result(method: .keyEquivalent)
        }
        return Result(method: .failed)
    }
}
