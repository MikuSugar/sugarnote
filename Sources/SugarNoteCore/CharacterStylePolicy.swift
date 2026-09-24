import Foundation

/// 字符样式的应用策略。
///
/// 备忘录的字体菜单项（粗体 ⌘B、斜体 ⌘I、下划线 ⌘U、删除线、高亮）是**切换**语义：
/// 目标范围已经带着该样式时再触发一次会把它**切掉**。
///
/// 而刚敲进来的 Markdown 文本会继承光标处的打字属性——用户如果正在粗体里打字，
/// `**x**` 里的 x 本来就是粗的，我们无脑按一次 ⌘B 反而把粗体取消了。
/// ProNotes 二进制里那两句 `Style was not applied properly.` /
/// `Style was not removed properly.` 就是这个坑留下的痕迹。
///
/// 所以字符样式必须**先读状态再决定**。这个策略单独抽出来，是为了能脱离 AX 单测——
/// 它是这条链路上最容易出错、也最难在界面上复现的一环。
public enum CharacterStylePolicy {

    /// 该不该触发这个动作的菜单项。
    ///
    /// - `action` 是字符样式动作；
    /// - `current` 是目标范围当前的样式读数，读不到就传 nil。
    ///
    /// 返回 true 表示需要触发；false 表示已经是目标样式，触发反而会切掉它。
    /// 段落样式动作不走这套（它们是单选语义），调用方应先按 `isParagraphLevel` 分流。
    public static func shouldInvoke(_ action: NotesAction, current: ParagraphStyleReading?) -> Bool {
        guard !action.isParagraphLevel else { return true }
        guard let current else { return true }
        // 读数不足以判断时保守地触发：宁可多按一次（有复核兜底），也不要漏掉
        guard let isOn = current.hasCharacterStyle(action) else { return true }
        return !isOn
    }

    /// 触发后复核：样式是不是真的到位了。读不到返回 nil。
    public static func isSatisfied(_ action: NotesAction, after reading: ParagraphStyleReading?) -> Bool? {
        guard let reading else { return nil }
        return reading.hasCharacterStyle(action)
    }
}
