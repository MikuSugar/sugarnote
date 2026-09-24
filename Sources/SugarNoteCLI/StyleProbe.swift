import ApplicationServices
import AppKit
import Foundation
import SugarNoteCore

/// 隔离实验：逐个样式单独应用，把几个候选的「样式可观测信号」一起读出来，
/// 看哪个能当可靠断言用。
///
/// 动机：自检里 `## `、`> `、`- [ ] ` 用菜单勾选状态判定时都读成了上一个样式，
/// 怀疑勾选状态是懒验证的。这里把 AXStyleName / AXHeadingLevel / AXBlockQuoteLevel /
/// 菜单勾选（读两次，间隔 250ms）摆在一起对比。
///
/// 安全护栏与 `SelfTest` 一致：只在空白笔记里跑；每轮结束把正文截回本轮基线长度，
/// 截断前先校验前缀没变，绝不碰用户已有内容；绝不删笔记。
enum StyleProbe {

    static let paragraphCases: [NotesAction] = [
        .title, .heading, .subheading, .body, .monospaced,
        .bulletedList, .dashedList, .numberedList, .checklist, .blockQuote,
    ]

    static let characterCases: [NotesAction] = [.bold, .italic, .underline, .strikethrough, .highlight]

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
        var problems: [String] = []

        print("目标笔记 id：\(note.noteID ?? "未知")")
        print("")

        print("========== 段落样式 ==========")
        for action in paragraphCases {
            guard let baseline = note.textLength else { problems.append("读不到基线"); break }
            guard note.insert("abc", at: baseline) else { problems.append("插入失败"); break }
            usleep(150_000)
            _ = note.setSelectedRange(NSRange(location: baseline, length: 3))
            usleep(100_000)

            guard let match = engine.currentMenuIndex().resolve(action) else {
                problems.append("\(action.rawValue) 解析不到")
                restore(note: note, to: baseline)
                continue
            }
            _ = MenuInvoker().invoke(match.item, in: app)
            usleep(300_000)
            _ = note.setSelectedRange(NSRange(location: baseline, length: 3))
            usleep(100_000)

            let reading = note.paragraphStyle(at: baseline)
            let checked1 = checkedParagraphActions(engine: engine)
            usleep(250_000)
            let checked2 = checkedParagraphActions(engine: engine)

            print("\(action.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0))"
                  + " style=\((reading?.styleName ?? "nil").padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + " heading=\((reading?.headingLevel.map(String.init) ?? "nil").padding(toLength: 5, withPad: " ", startingAt: 0))"
                  + " quote=\((reading?.blockQuoteLevel.map(String.init) ?? "nil").padding(toLength: 5, withPad: " ", startingAt: 0))"
                  + " 勾选#1=\(checked1.map(\.rawValue).joined(separator: ","))"
                  + " 勾选#2=\(checked2.map(\.rawValue).joined(separator: ","))")
            restore(note: note, to: baseline)
        }

        print("")
        print("========== 字符样式 ==========")
        for action in characterCases {
            guard let baseline = note.textLength else { break }
            guard note.insert("abc", at: baseline) else { break }
            usleep(150_000)
            let target = NSRange(location: baseline, length: 3)
            _ = note.setSelectedRange(target)
            usleep(100_000)

            guard let match = engine.currentMenuIndex().resolve(action) else {
                problems.append("\(action.rawValue) 解析不到")
                restore(note: note, to: baseline)
                continue
            }
            let before = note.styleReading(in: target)
            _ = MenuInvoker().invoke(match.item, in: app)
            usleep(300_000)
            let after = note.styleReading(in: target)

            print("\(action.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0))"
                  + " \(match.method.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))"
                  + " \(match.item.pathString)")
            print("    前 font=\(before?.fontName ?? "nil")"
                  + " underline=\(before?.underline.map(String.init) ?? "nil")"
                  + " strike=\(before?.strikethrough.map(String.init) ?? "nil")"
                  + " style=\(before?.styleName ?? "nil")")
            print("    后 font=\(after?.fontName ?? "nil")"
                  + " underline=\(after?.underline.map(String.init) ?? "nil")"
                  + " strike=\(after?.strikethrough.map(String.init) ?? "nil")"
                  + " style=\(after?.styleName ?? "nil")")
            print("    hasCharacterStyle=\(String(describing: after?.hasCharacterStyle(action)))")
            restore(note: note, to: baseline)
        }

        let finalLength = note.textLength ?? -1
        print("")
        print("测试后正文长度：\(finalLength)（测试前是 0）")
        if finalLength != 0 { problems.append("正文残留 \(finalLength) 字") }
        if !problems.isEmpty {
            print("问题：")
            for problem in problems { print("  - \(problem)") }
        }
        return problems.isEmpty ? 0 : 1
    }

    /// 把正文截回基线长度。截断前先确认前缀没变，变了就什么都不做。
    private static func restore(note: NoteTextElement, to baseline: Int) {
        guard let text = note.text() as NSString? else { return }
        guard text.length > baseline else { return }
        let prefix = text.substring(with: NSRange(location: 0, length: baseline))
        guard prefix.allSatisfy({ $0 == "\n" || $0 == " " }) else {
            print("    （跳过清理：前缀 \(prefix.debugDescription) 不是本次插入的内容）")
            return
        }
        _ = note.replace(NSRange(location: baseline, length: text.length - baseline), with: "")
        usleep(150_000)
    }

    /// 当前菜单里被勾选的段落样式项。
    private static func checkedParagraphActions(engine: NotesEngine) -> [NotesAction] {
        let fresh = engine.refreshMenuIndex()
        return paragraphCases.filter { fresh.resolve($0)?.item.isChecked == true }
    }
}
