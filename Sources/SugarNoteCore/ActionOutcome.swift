import Foundation

/// 一次动作触发的完整结果。
///
/// `alreadyApplied` 是这次验证发现的「切换语义」的直接体现：目标范围本来就带着目标
/// 字符样式时，我们**不能**再触发菜单项（再按一次会把它切掉），所以这条记录表示
/// 「读状态后决定跳过」，不是失败。
public struct ActionOutcome: Sendable {
    public var action: NotesAction
    /// 实际用的触发方式。`alreadyApplied` 时是 nil——那次压根没触发菜单项。
    public var method: MenuInvoker.Method?
    public var alreadyApplied: Bool
    /// 触发后复核的结果：样式确实到位了没有。nil 表示没法判定（比如读不到富文本）。
    public var verified: Bool?

    public init(action: NotesAction, method: MenuInvoker.Method?,
                alreadyApplied: Bool, verified: Bool?) {
        self.action = action
        self.method = method
        self.alreadyApplied = alreadyApplied
        self.verified = verified
    }

    public var succeeded: Bool {
        if alreadyApplied { return true }
        if method == nil || method == .failed { return false }
        return verified ?? true
    }

    public var summary: String {
        if alreadyApplied { return "\(action.rawValue)/已是目标样式,跳过" }
        var text = "\(action.rawValue)/\(method?.rawValue ?? "未触发")"
        if let verified { text += verified ? "/已复核" : "/复核未通过" }
        return text
    }
}
