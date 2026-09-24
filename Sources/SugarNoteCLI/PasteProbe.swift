import ApplicationServices
import AppKit
import Foundation
import SugarNoteCore

/// 实验：能不能用备忘录自己的「粘贴为 Markdown」做转换。
///
/// 动机：现在的做法是「删两处分隔符 + 应用样式」，那是好几个独立的 AX 改写，
/// 撤销栈里散成一堆，用户按 ⌘Z 退不回 Markdown 原文（实测会在一串中间状态之间振荡）。
/// 「粘贴为 Markdown」是一次粘贴，理论上是一步撤销，而且 Markdown → 富文本的语义
/// 完全交给 Apple 的解析器（嵌套列表、表格、代码块都不需要我们自己实现）。
///
/// 顺便验证它能不能处理**行内**语法（`**粗体**`），而不只是整块的 Markdown。
///
/// 安全护栏：只在空白笔记里跑；会临时占用剪贴板，跑完恢复原内容；只删自己插入的内容；绝不删笔记。
enum PasteProbe {

    static func run() -> Int32 {
        guard AXIsProcessTrusted() else { print("没有辅助功能权限。"); return 1 }
        guard let app = NotesApp.running() else { print("备忘录没在运行。"); return 1 }
        guard app.activate() else { print("备忘录没能切到前台，放弃。"); return 1 }
        guard let note = app.focusNoteBody() else { print("找不到笔记正文。"); return 1 }
        guard note.isEmpty else {
            print("⛔️ 目标笔记不是空的（\(note.textLength ?? -1) 字），拒绝运行。请换一条空白笔记。")
            return 1
        }

        let engine = NotesEngine(app: app)
        _ = engine.refreshMenuIndex()
        print("笔记 id：\(note.noteID ?? "未知")")
        print("")

        // 保存剪贴板，跑完恢复
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict.isEmpty ? nil : dict
        } ?? []
        let savedTypes = pasteboard.types ?? []
        defer {
            pasteboard.clearContents()
            if !saved.isEmpty {
                let items = saved.map { dict -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in dict { item.setData(data, forType: type) }
                    return item
                }
                pasteboard.writeObjects(items)
            } else {
                _ = savedTypes
            }
            print("")
            print("剪贴板已恢复")
        }

        let samples = ["**粗体**", "*斜体*", "`行内代码`", "- 项目一\n- 项目二", "# 标题行"]

        for sample in samples {
            print("========== 样本：\(sample.debugDescription) ==========")
            guard let baseline = note.textLength else { break }

            // 1. 先把样本当纯文本插进去
            guard note.insert(sample, at: baseline) else { print("  插入失败"); continue }
            usleep(200_000)
            let target = NSRange(location: baseline, length: (sample as NSString).length)
            _ = note.setSelectedRange(target)
            usleep(120_000)
            print("  选中范围 {\(target.location),\(target.length)}，选中文本 "
                  + "\(note.string(in: target)?.debugDescription ?? "nil")")

            // 2. 剪贴板放样本，触发「粘贴为 Markdown」
            pasteboard.clearContents()
            pasteboard.setString(sample, forType: .string)
            usleep(80_000)

            guard let pasteItem = engine.currentMenuIndex().resolve(.pasteAsMarkdown) else {
                print("  ⛔️ 解析不到「粘贴为 Markdown」")
                clean(note: note, from: baseline)
                continue
            }
            print("  触发：\(pasteItem.item.pathString)（\(pasteItem.method.rawValue)）"
                  + " 启用=\(pasteItem.item.enabled)")
            _ = MenuInvoker().invoke(pasteItem.item, in: app)
            usleep(450_000)

            let afterText = note.text() ?? ""
            print("  粘贴后正文：\(afterText.debugDescription)")
            if let after = note.textLength, after > 0 {
                let probe = NSRange(location: 0, length: after)
                if let reading = note.styleReading(in: probe) {
                    print("  样式读数：\(reading.summary)")
                }
            }

            // 3. 按一次 ⌘Z，看能不能退回 Markdown 原文
            if let undo = engine.currentMenuIndex().item(
                withKeyEquivalent: KeyEquivalent(character: "z", modifiers: [.command])) {
                _ = MenuInvoker().invoke(undo, in: app)
                usleep(400_000)
                let undone = note.text() ?? ""
                let restored = undone.contains(sample)
                print("  一次 ⌘Z 后：\(undone.debugDescription)  "
                      + (restored ? "→ ✓ 退回 Markdown 原文" : "→ ✗ 没退回"))
            } else {
                print("  找不到 ⌘Z")
            }
            print("")
            clean(note: note, from: baseline)
        }

        print("测试后正文长度：\(note.textLength.map(String.init) ?? "nil")（测试前是 0）")
        return 0
    }

    /// 把正文截回基线。截断前确认尾部不含字母（只有本次插入的标点和空白），否则跳过。
    private static func clean(note: NoteTextElement, from baseline: Int) {
        guard let text = note.text() as NSString? else { return }
        guard text.length > baseline else { return }
        let tail = text.substring(from: baseline)
        guard tail.allSatisfy({ !$0.isLetter && !$0.isNumber }) else {
            print("  （跳过清理：尾部 \(tail.debugDescription) 含字母数字）")
            return
        }
        _ = note.replace(NSRange(location: baseline, length: text.length - baseline), with: "")
        usleep(200_000)
    }
}
