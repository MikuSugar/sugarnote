import ApplicationServices
import AppKit
import Foundation
import SugarNoteCore

/// 用**真实按键**往备忘录里打字，看两件事：
///
/// 1. 合成按键到底能不能把字打进正文（`CGEventKeyboardSetUnicodeString` + `postToPid`）。
///    之前只验证过它触发不了菜单快捷键，但打文本走的是另一条路。
/// 2. 备忘录自带的智能替换覆盖了哪些 Markdown 语法。`编辑 > 替换` 里「智能列表」
///    「智能破折号」默认是开的，`- `、`1. `、`---` 可能本来就会被自动转换——
///    如果属实，sugarnote 就不该重复处理这些，触发器集能小一圈。
///
/// 安全护栏：只在空白笔记里跑；每轮之间把正文截回基线（截断前校验尾部只含非字母数字，
/// 或者正好是我们打进去的那串）；绝不删笔记。
enum TypeProbe {

    /// 每个样本：先打这段，然后观察备忘录有没有自己动手。
    static let samples: [String] = [
        "- [ ] ",        // 关键：前面的 "- " 会不会先被智能列表吃掉？
        "- [x] ",
        "[] ",
        "* [ ] ",
        "- ",            // 智能列表：项目符号（已知会被转）
        "> ",
        "# ",
        "### ",
        "***",           // 备用分隔线写法：智能破折号管不管？
        "___",
    ]

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

        // 停掉自己的引擎介入：这一轮只想知道备忘录**自己**会做什么，
        // 所以不跑 handleTextChange，只观察打字后的文本。
        print("笔记 id：\(note.noteID ?? "未知")")
        print("（本轮不介入转换，只看备忘录自己的行为）")
        print("")

        print("先验证合成按键能不能打进文本：")
        guard let baseline = note.textLength else { return 1 }
        _ = note.setSelectedRange(NSRange(location: baseline, length: 0))
        usleep(120_000)
        KeySynthesizer.typeText("abc", to: app.pid)
        usleep(400_000)
        let afterType = note.text() ?? ""
        print("  打了 \"abc\"，正文变成：\(afterType.debugDescription)")
        let canType = afterType.contains("abc") || afterType.contains("abc".uppercased())
        print("  → 合成按键\(canType ? "可以" : "**不可以**")打进正文")
        print("")
        restore(note: note, to: baseline, expecting: "abc")

        print("========== 备忘录自带的输入期行为 ==========")
        print("样本".padding(toLength: 14, withPad: " ", startingAt: 0)
              + " 打完之后的正文")
        for sample in samples {
            guard let base = note.textLength else { break }
            _ = note.setSelectedRange(NSRange(location: base, length: 0))
            usleep(150_000)
            KeySynthesizer.typeText(sample, to: app.pid)
            usleep(600_000)

            let text = note.text() ?? ""
            let tail = (text as NSString).length > base
                ? (text as NSString).substring(from: base)
                : ""
            let converted = tail != sample
            let tailColumn = tail.debugDescription
                .padding(toLength: 26, withPad: " ", startingAt: 0)
            print(sample.debugDescription.padding(toLength: 14, withPad: " ", startingAt: 0)
                  + " \(tailColumn)" + (converted ? " ← 备忘录改写了" : ""))

            // 用菜单勾选状态看段落样式（文本可能被消费成空段，AXStyleName 读不到）
            let checked = checkedParagraphStyles(engine: engine)
            if !checked.isEmpty {
                print("               菜单勾选：" + checked.map(\.rawValue).sorted().joined(separator: ","))
            }
            restore(note: note, to: base, expecting: sample)
        }

        print("")
        print("测试后正文长度：\(note.textLength.map(String.init) ?? "nil")（测试前是 0）")
        return 0
    }

    /// 当前菜单里被勾选的段落样式项。勾选状态是懒验证的，读两次。
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

    /// 把正文截回基线。截断前确认尾部正好是我们打进去的内容（或只含标点空白）。
    private static func restore(note: NoteTextElement, to baseline: Int, expecting: String) {
        guard let text = note.text() as NSString? else { return }
        guard text.length > baseline else { return }
        let tail = text.substring(from: baseline)
        var normalized = tail
        while normalized.hasSuffix("\n") { normalized.removeLast() }
        let acceptable = normalized == expecting
            || tail.allSatisfy { !$0.isLetter && !$0.isNumber }
            || (expecting.allSatisfy { !$0.isLetter })
        guard acceptable else {
            print("    （跳过清理：尾部 \(tail.debugDescription) 不是本次打进去的内容）")
            return
        }
        _ = note.replace(NSRange(location: baseline, length: text.length - baseline), with: "")
        usleep(250_000)
    }
}
