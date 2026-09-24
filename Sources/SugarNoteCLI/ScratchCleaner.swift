import ApplicationServices
import AppKit
import Foundation
import SugarNoteCore

/// 清理自检/探测在草稿笔记里留下的残留。
///
/// **只用于清理测试自己写进去的东西**，不是通用清空工具。所以校验很硬：
/// 正文的每一个字符都必须落在允许集合里（默认是 `abc`、换行、空格），
/// 否则拒绝执行。这样即使用户往草稿笔记里敲了东西，也不会被误清。
///
/// 刻意不做的事：不删笔记、不移动笔记、不碰废纸篓。
enum ScratchCleaner {

    static func run(allowed: String, expectedNoteID: String?) -> Int32 {
        guard AXIsProcessTrusted() else { print("没有辅助功能权限。"); return 1 }
        guard let app = NotesApp.running() else { print("备忘录没在运行。"); return 1 }
        guard app.activate() else { print("备忘录没能切到前台，放弃。"); return 1 }
        guard let note = app.focusNoteBody() else { print("找不到笔记正文。"); return 1 }

        guard let text = note.text(), !text.isEmpty else {
            print("目标笔记已经是空的（id \(note.noteID ?? "未知")），无需清理。")
            return 0
        }

        // `--allow "*"` 是无条件清空，必须配 `--id <笔记UUID>` 指定目标。
        //
        // 为什么要这道锁：无条件清空不校验内容，光靠「当前打开的笔记就是草稿」这个假设。
        // 我实际踩过——用户往草稿笔记里敲了测试内容，我照样整篇清掉了。指定 id 至少保证
        // 只能清到事先确认过的那一条草稿，不会因为焦点漂移清错笔记。
        if allowed.contains("*") {
            guard let expectedID = expectedNoteID, !expectedID.isEmpty else {
                print("""
                ⛔️ --allow "*" 是无条件清空，必须同时用 --id <笔记UUID> 指定目标笔记。

                先用 `sugarnote-cli read` 看当前笔记 id，确认它确实是自己的草稿笔记，
                再执行：sugarnote-cli clear-scratch --allow "*" --id <那个 UUID>
                """)
                return 1
            }
            guard let actualID = note.noteID, actualID.caseInsensitiveCompare(expectedID) == .orderedSame else {
                print("⛔️ 当前笔记是 \(note.noteID ?? "未知")，与 --id 指定的 \(expectedID) 不符，拒绝清空。")
                return 1
            }
            print("笔记 id：\(actualID)（与 --id 一致）")
            print("无条件清空内容：\(text.debugDescription)")
            let length = (text as NSString).length
            _ = note.replace(NSRange(location: 0, length: length), with: "")
            usleep(250_000)
            let after = note.textLength ?? -1
            print("清理后长度：\(after)\(after == 0 ? "（空）" : "")")
            return after == 0 ? 0 : 1
        }
        let charset = Set(allowed)
        let extra = Set("\n\r ")
        let offenders = text.filter { !charset.contains($0) && !extra.contains($0) }
        guard offenders.isEmpty else {
            let sample = String(offenders.prefix(20))
            print("""
            ⛔️ 拒绝清理：正文里有非测试内容。

            笔记 id：\(note.noteID ?? "未知")
            正文长度：\((text as NSString).length)
            不允许出现的字符（前 20 个）：\(sample.debugDescription)

            这个命令只用来清理测试自己写进去的残留，正文里出现别的字符就一律不动。
            """)
            return 1
        }

        print("笔记 id：\(note.noteID ?? "未知")")
        print("待清理内容：\(text.debugDescription)")
        let length = (text as NSString).length
        guard note.replace(NSRange(location: 0, length: length), with: "") else {
            print("清理失败。")
            return 1
        }
        usleep(250_000)
        let after = note.textLength ?? -1
        print("清理后长度：\(after)\(after == 0 ? "（空）" : "")")
        return after == 0 ? 0 : 1
    }
}
