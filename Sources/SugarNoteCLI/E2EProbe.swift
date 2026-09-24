import ApplicationServices
import AppKit
import Foundation
import SugarNoteCore

/// 真实场景端到端：**用真实按键**敲 Markdown，让后台的 `watch` 进程去转换，然后按 ⌘Z。
///
/// 为什么不能用 AX 插入代替打字：撤销栈是按事件分组的。用 AX 在同一秒里「插入 + 转换」，
/// 两步会被合并成一组，撤销会一路退到插入之前，测不出真实行为。
/// 真实按键打字是独立事件，转换才是单独一步——这才是用户实际会遇到的情形。
///
/// 用法：先在另一个终端跑 `sugarnote-cli watch`，再跑这个。
///
/// 安全护栏：只在空白笔记里跑；只删自己打进去的内容；绝不删笔记。
enum E2EProbe {

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
        print("⚠️ 请确认另有一个终端在跑 `sugarnote-cli watch`，否则不会有人转换。")
        print("")

        // (要敲的 Markdown, 转换后预期的正文, 清理时允许出现的字符)
        let cases: [(markdown: String, expected: String, allow: String)] = [
            ("**粗体**", "粗体", "粗体"),
            ("`代码`", "代码", "代码"),
            ("# 标题", "标题", "标题"),
            ("~~删除~~", "删除", "删除"),
        ]

        for (markdown, expected, allow) in cases {
            print("========== 真实敲入 \(markdown.debugDescription) ==========")
            guard let baseline = note.textLength else { break }
            _ = note.setSelectedRange(NSRange(location: baseline, length: 0))
            usleep(150_000)

            KeySynthesizer.typeText(markdown, to: app.pid)
            // 等后台 watch 收到通知并完成转换
            usleep(1_200_000)

            let after = note.text() ?? ""
            let converted = !after.contains(markdown)
            print("  敲完并等待后正文：\(after.debugDescription)"
                  + (converted ? "  ← 已被转换" : "  ← 没被转换"))

            if converted {
                let length = (after as NSString).length
                if length > 0, let reading = note.styleReading(in: NSRange(location: 0, length: length)) {
                    print("  样式读数：\(reading.summary)")
                }
                // 用菜单勾选状态看段落样式（勾选是懒验证的，读两次）
                let checked = checkedParagraphStyles(engine: engine)
                if !checked.isEmpty {
                    print("  菜单勾选：" + checked.map(\.rawValue).sorted().joined(separator: ","))
                }

                // 撤销：真实场景下按一次 ⌘Z，看退回到什么状态。
                // 只按一次——反复按会往回走穿整个编辑历史，把之前几轮的残留翻出来。
                if let undo = engine.currentMenuIndex().item(
                    withKeyEquivalent: KeyEquivalent(character: "z", modifiers: [.command])) {
                    _ = MenuInvoker().invoke(undo, in: app)
                    usleep(500_000)
                    let undone = note.text() ?? ""
                    let verdict: String
                    if undone.contains(markdown) {
                        verdict = "✓ 退回 Markdown 原文"
                    } else if undone == after {
                        verdict = "✗ 没有变化"
                    } else {
                        verdict = "△ 变成了中间状态（不可预期，但可继续撤销）"
                    }
                    print("  一次 ⌘Z 后：\(undone.debugDescription)  → \(verdict)")
                }
            } else {
                print("  （没人转换。确认 watch 在跑？）")
            }
            print("")
            clean(note: note, from: baseline, allow: allow)
        }

        print("测试后正文长度：\(note.textLength.map(String.init) ?? "nil")（测试前是 0）")
        return 0
    }

    private static func checkedParagraphStyles(engine: NotesEngine) -> Set<NotesAction> {
        let candidates: [NotesAction] = [
            .title, .heading, .subheading, .body, .monospaced,
            .bulletedList, .dashedList, .numberedList, .checklist, .blockQuote,
        ]
        func readOnce() -> Set<NotesAction> {
            let fresh = engine.refreshMenuIndex()
            return Set(candidates.filter { fresh.resolve($0)?.item.isChecked == true })
        }
        _ = readOnce()
        usleep(250_000)
        return readOnce()
    }

    /// 清空正文。
    ///
    /// 这里直接清整篇而不是「截回基线」：跑这个探测前断言过笔记为空，所以正文里的一切
    /// 都是本次测试写进去的。而按 ⌘Z 会把编辑历史往回翻，翻出来的内容位置和长度都不可
    /// 预期，按基线截断清不干净。前提是那个「笔记为空」的断言——它保证了不会误删用户内容。
    private static func clean(note: NoteTextElement, from baseline: Int, allow: String) {
        guard let text = note.text() as NSString?, text.length > 0 else { return }
        _ = note.replace(NSRange(location: 0, length: text.length), with: "")
        usleep(300_000)
        let after = note.textLength ?? -1
        if after != 0 {
            print("  ⚠️ 清空后长度是 \(after)，请手动检查这条笔记")
        }
    }
}
