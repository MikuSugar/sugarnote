import ApplicationServices
import AppKit
import Foundation
import SugarNoteCore

/// 聚焦探测：跑一次行内转换（`**bold**`），然后在不同时机、用新旧两种元素引用去读
/// 富文本属性，定位「引擎做过 AX 文本改写之后读不到样式」的原因。
///
/// 安全护栏与 `SelfTest` 一致：只在空白笔记里跑，只删自己插入的内容，绝不删笔记。
enum InlineProbe {

    static func run() -> Int32 {
        guard AXIsProcessTrusted() else { print("没有辅助功能权限。"); return 1 }
        guard let app = NotesApp.running() else { print("备忘录没在运行。"); return 1 }
        guard app.activate() else { print("备忘录没能切到前台，放弃。"); return 1 }
        guard let note = app.focusNoteBody() else { print("找不到笔记正文。"); return 1 }
        guard note.isEmpty else {
            print("⛔️ 目标笔记不是空的（\(note.textLength ?? -1) 字），拒绝运行。")
            return 1
        }

        let engine = NotesEngine(app: app)
        _ = engine.refreshMenuIndex()
        print("笔记 id：\(note.noteID ?? "未知")")
        print("")

        // 1. 先把段落基线归零，排除继承样式的干扰
        if let body = engine.currentMenuIndex().resolve(.body) {
            _ = MenuInvoker().invoke(body.item, in: app)
            usleep(120_000)
        }

        // 2. 插入 Markdown 原文
        guard note.insert("**bold**", at: 0) else { print("插入失败"); return 1 }
        usleep(160_000)
        dump("插入后（原始 Markdown）", note: note, app: app, range: NSRange(location: 2, length: 4))

        // 3. 走引擎的完整转换流程
        let outcome = engine.handleTextChange()
        print("")
        print("引擎结果：\(outcome.summary)")
        print("")

        // 4. 立刻用旧元素引用读
        dump("转换后立刻（旧元素引用）", note: note, app: app, range: NSRange(location: 0, length: 4))

        // 5. 等一等再用旧引用读
        usleep(400_000)
        dump("等 400ms（旧元素引用）", note: note, app: app, range: NSRange(location: 0, length: 4))

        // 6. 重新解析元素再读
        if let fresh = app.focusNoteBody() {
            dump("重新解析元素后", note: fresh, app: app, range: NSRange(location: 0, length: 4))
        }

        // 7. 用整段范围（而不是精确子范围）读一次
        if let fresh = app.focusNoteBody(), let text = fresh.text() {
            let whole = NSRange(location: 0, length: (text as NSString).length)
            dump("整段范围（length=\(whole.length)）", note: fresh, app: app, range: whole)
        }

        // 清理：只删自己插入的内容
        if let fresh = app.focusNoteBody(), let text = fresh.text(), text == "bold" {
            _ = fresh.replace(NSRange(location: 0, length: 4), with: "")
            usleep(150_000)
        } else {
            print("")
            print("⚠️ 正文不是预期的 \"bold\"（实际 \(String(describing: app.focusNoteBody()?.text()))），跳过清理")
        }
        print("")
        print("清理后长度：\(app.focusNoteBody()?.textLength.map(String.init) ?? "nil")")
        return 0
    }

    private static func dump(_ label: String, note: NoteTextElement, app: NotesApp, range: NSRange) {
        print("【\(label)】")
        let text = note.text() ?? ""
        print("    正文=\(text.debugDescription)  光标=\(note.selectedRange.map { "{\($0.location),\($0.length)}" } ?? "nil")")
        print("    探测范围={\(range.location),\(range.length)}")
        if let sub = note.string(in: range) {
            print("    AXStringForRange → \(sub.debugDescription)")
        } else {
            print("    AXStringForRange → 读不到")
        }
        if let attributed = note.attributedString(in: range) {
            print("    AXAttributedStringForRange → 长度 \(attributed.length)，属性：")
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) {
                attributes, attrRange, _ in
                let keys = attributes.keys.map(\.rawValue).sorted().joined(separator: ",")
                print("        {\(attrRange.location),\(attrRange.length)} \(keys)")
            }
        } else {
            print("    AXAttributedStringForRange → 读不到（nil）")
        }
        if let reading = note.styleReading(in: range) {
            print("    styleReading → \(reading.summary)")
        } else {
            print("    styleReading → nil")
        }
    }
}
