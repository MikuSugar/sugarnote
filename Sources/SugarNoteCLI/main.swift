import ApplicationServices
import AppKit
import Foundation
import SugarNoteCore

// sugarnote-cli —— 开发调试用的命令行外壳。
//
// 为什么单独做一个 CLI：TCC 的辅助功能权限归因到最外层的「负责进程」。
// 从终端里跑这个 CLI，权限归终端（或 ZCode）；跑 .app 则要单独授权。
// 开发期用 CLI 迭代，改完代码直接 `swift run` 就能试，不用反复重新授权。

// 输出改成行缓冲。默认 stdout 重定向到文件时是块缓冲的，`watch` 这类长驻命令
// 被 kill 掉时缓冲区会整个丢掉，日志一片空白——排查问题时很误导人。
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func requireAccessibility() {
    guard AXIsProcessTrusted() else {
        fail("""
        没有辅助功能权限。

        请到「系统设置 > 隐私与安全性 > 辅助功能」，把运行本命令的程序打开，然后重试。
        """)
    }
}

func requireNotes() -> NotesApp {
    guard let app = NotesApp.running() else {
        fail("备忘录没在运行。请先打开「备忘录」，并把光标点进一条笔记的正文。")
    }
    return app
}

let usage = """
sugarnote-cli —— 调试工具

用法：
  sugarnote-cli read              读当前笔记正文的状态（笔记 id、光标、段落、输入法状态）
  sugarnote-cli menus             打印菜单索引：每个动作解析到哪个菜单项、用什么方式触发
  sugarnote-cli watch             订阅正文变化并执行转换（会给备忘录改内容）
  sugarnote-cli expand <文本>     离线跑识别器：把文本当作文本、光标在末尾，打印识别出的转换计划
  sugarnote-cli selftest          端到端自检（只在**空白笔记**里跑，绝不删笔记）
                                  --undo  额外跑撤销检查（会动撤销栈顶，谨慎）
  sugarnote-cli e2e-probe       真实按键端到端（需另开一个终端跑 watch）+ 撤销行为
  sugarnote-cli type-probe      用真实按键打字，测备忘录自带的输入期行为（智能列表等）
  sugarnote-cli paste-probe     实验：用备忘录自己的「粘贴为 Markdown」做转换 + 撤销行为
  sugarnote-cli inline-probe     聚焦探测：一次行内转换后，在不同时机/引用下读富文本属性
  sugarnote-cli clear-scratch    清理草稿笔记里的测试残留（正文只含指定字符时才清）
                                  --allow <字符集>  --id <UUID>（无条件清空时必须指定目标）
  sugarnote-cli style-probe       隔离实验：逐个字符样式单独应用，确认样式真的打上了（只在空白笔记里跑）
  sugarnote-cli dump-menus        把完整菜单树写成 JSON（调试用）
"""

switch arguments.first {
case "read":
    requireAccessibility()
    let app = requireNotes()
    guard let note = app.focusNoteBody() else {
        fail("找不到笔记正文元素。请打开备忘录、确认窗口里有一条笔记。")
    }
    print("笔记 id          : \(note.noteID ?? "未知")")
    print("备忘录在前台     : \(app.isFrontmost)")
    print("AXValue 可写     : \(note.isSettableValue)")
    print("AXSelectedText 可写: \(note.isSettableSelectedText)")
    print("选区可写         : \(note.isSettableSelectedTextRange)")
    if let marked = note.markedRange {
        print("输入法组字范围   : {\(marked.location), \(marked.length)}\(note.isComposing ? "  ← 正在组字" : "")")
    }
    if let caret = note.selectedRange {
        print("光标             : {\(caret.location), \(caret.length)}")
    }
    if let text = note.text() {
        print("正文长度         : \(text.count) 字符")
    }
    if let line = note.currentLine() {
        print("光标所在视觉行   : {\(line.range.location), \(line.range.length)}  \(line.text.debugDescription)")
    }
    if let text = note.text(), let caret = note.selectedRange?.location {
        let range = MarkdownRecognizer.paragraphRange(in: text as NSString, containing: caret)
        let paragraph = (text as NSString).substring(with: range)
        print("光标所在段落     : {\(range.location), \(range.length)}  \(paragraph.debugDescription)")
    }

case "menus":
    requireAccessibility()
    let app = requireNotes()
    let index = MenuIndex(menuBarSnapshot: app.menuBarSnapshot())
    print("结构性锚点：")
    print("  格式菜单   : \(index.formatMenuTitle ?? "未识别")")
    print("  字体子菜单 : \(index.fontMenuTitle ?? "未识别")")
    print("  对齐子菜单 : \(index.alignmentMenuTitle ?? "未识别")")
    print("  编辑菜单   : \(index.editMenuTitle ?? "未识别")")
    print("")
    print("动作解析（共 \(NotesAction.allCases.count) 项）：")
    for (action, match) in index.report() {
        let expected = action.keyEquivalent?.displayString ?? "无快捷键"
        if let match {
            let key = match.item.keyEquivalent?.displayString ?? "—"
            let state = match.item.enabled ? "" : " [菜单里当前禁用]"
            print("  \(action.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0))"
                  + " 期望 \(expected.padding(toLength: 6, withPad: " ", startingAt: 0))"
                  + " → \(key.padding(toLength: 5, withPad: " ", startingAt: 0))"
                  + " \(match.method.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0))"
                  + " \(match.item.pathString)\(state)")
        } else {
            print("  \(action.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0))"
                  + " 期望 \(expected.padding(toLength: 6, withPad: " ", startingAt: 0))"
                  + " → 解析不到 ✗")
        }
    }

case "watch":
    requireAccessibility()
    let app = requireNotes()
    let engine = NotesEngine(app: app)
    engine.refreshMenuIndex()
    engine.log = { print("  [engine] \($0)") }

    print("正在监听并**执行转换**（会在备忘录里改内容）。切到备忘录、把光标放进正文，然后打字。⌃C 退出。")
    let watcher = NotesWatcher(app: app) { event in
        switch event {
        case .focusChanged:
            print("· 焦点变化")
        case .textChanged:
            let outcome = engine.handleTextChange()
            let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
            print("· \(stamp)  \(outcome.summary)")
        }
    }
    watcher.start()
    RunLoop.main.run()

case "expand":
    guard arguments.count >= 2 else { fail("用法：sugarnote-cli expand <文本>") }
    let text = arguments[1]
    let ns = text as NSString
    // 支持用 | 标记光标位置，方便测中间插入的情况；没写就默认在末尾
    let caret: Int
    let subject: NSString
    if let bar = text.firstIndex(of: "|") {
        let offset = text.distance(from: text.startIndex, to: bar)
        let stripped = text.replacingOccurrences(of: "|", with: "")
        subject = stripped as NSString
        caret = offset
    } else {
        subject = ns
        caret = ns.length
    }
    if let plan = MarkdownRecognizer.recognize(text: subject, caret: caret) {
        let range = plan.replacement.range
        print("识别到转换计划：")
        print("  一次改写            : {\(range.location),\(range.length)}"
              + " 把 \(subject.substring(with: range).debugDescription)"
              + " 换成 \(plan.replacement.text.debugDescription)")
        print("  之后设置选区        : \(plan.selection.map { "{\($0.location),\($0.length)}" } ?? "不设置")")
        print("  触发动作            : \(plan.actions.map(\.rawValue).joined(separator: " → "))")
        if let selection = plan.selection {
            print("  样式将作用于        : \(subject.substring(with: selection).debugDescription)")
        }
    } else {
        print("没有识别到语法")
    }

case "selftest":
    requireAccessibility()
    exit(SelfTest.run(runUndoCheck: arguments.contains("--undo")))

case "style-probe":
    requireAccessibility()
    exit(StyleProbe.run())

case "e2e-probe":
    requireAccessibility()
    exit(E2EProbe.run())

case "type-probe":
    requireAccessibility()
    exit(TypeProbe.run())

case "paste-probe":
    requireAccessibility()
    exit(PasteProbe.run())

case "inline-probe":
    requireAccessibility()
    exit(InlineProbe.run())

case "clear-scratch":
    requireAccessibility()
    // 允许的残留字符：默认是全角/半角测试文本 + 换行空格；可用 --allow 覆盖
    let allowIndex = arguments.firstIndex(of: "--allow").map { $0 + 1 }
    let allowed = allowIndex.flatMap { $0 < arguments.count ? arguments[$0] : nil } ?? "abcABC"
    let idIndex = arguments.firstIndex(of: "--id").map { $0 + 1 }
    let expectedNoteID = idIndex.flatMap { $0 < arguments.count ? arguments[$0] : nil }
    exit(ScratchCleaner.run(allowed: allowed, expectedNoteID: expectedNoteID))

case "dump-menus":
    requireAccessibility()
    let app = requireNotes()
    let snapshot = app.menuBarSnapshot()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(snapshot) {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("menudump.json")
        try? data.write(to: url)
        print("已写入 \(url.path)（\(snapshot.flatMap { $0.flattened() }.count) 个菜单项）")
    }

case "-h", "--help", nil:
    print(usage)

default:
    print(usage)
    fail("未知子命令：\(arguments[0])")
}
