import SwiftUI
import SugarNoteCore

/// 设置窗口。
struct SettingsView: View {
    @ObservedObject var controller: SugarNoteController
    @ObservedObject var preferences = Preferences.shared

    /// 设置界面上展示的动作，按用途分组。
    private static let groups: [(String, [NotesAction])] = [
        ("段落样式", [.title, .heading, .subheading, .body, .monospaced]),
        ("列表", [.bulletedList, .dashedList, .numberedList, .checklist]),
        ("引用与分隔", [.blockQuote, .insertDivider]),
        ("字符样式", [.bold, .italic, .underline, .strikethrough, .highlight]),
        ("其它", [.table, .addLink, .pasteAsMarkdown, .copyAsMarkdown]),
    ]

    /// 每个动作对应的触发语法，显示在设置里让用户知道能敲什么。
    private static let syntax: [NotesAction: String] = [
        .title: "# ", .heading: "## ", .subheading: "### ", .body: "（无，用于取消）",
        .monospaced: "```", .bulletedList: "- ", .dashedList: "- ", .numberedList: "1. ",
        .checklist: "- [ ] ", .blockQuote: "> ", .insertDivider: "---",
        .bold: "**文本**", .italic: "*文本* / _文本_", .underline: "__文本__",
        .strikethrough: "~~文本~~", .highlight: "==文本==",
        .table: "（未实现）", .addLink: "（未实现）",
        .pasteAsMarkdown: "（未实现）", .copyAsMarkdown: "（未实现）",
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("状态", value: controller.status.label)
                if let version = controller.notesVersion {
                    LabeledContent("备忘录版本", value: version)
                }
                Toggle("启用 Markdown 快捷输入", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                ))
                if case .needsPermission = controller.status {
                    Button("打开辅助功能设置…") { controller.openAccessibilitySettings() }
                }
                if !controller.unresolvedActions.isEmpty {
                    Label("\(controller.unresolvedActions.count) 个动作在备忘录菜单里找不到，"
                          + "可能是备忘录升级后改了菜单。",
                          systemImage: "exclamationmark.triangle")
                    Button("重新扫描菜单") { controller.rescanMenus() }
                }
            }

            Section("识别规则") {
                Toggle("把 __文本__ 转成下划线（而不是 Markdown 标准的粗体）",
                       isOn: $preferences.doubleUnderscoreMeansUnderline)
                Toggle("把 --- 转成插入分隔线", isOn: $preferences.recognizesDivider)
                Toggle("应用样式后复核（多几次读取，但能自愈）",
                       isOn: $preferences.verifyCharacterStyles)
            }

            ForEach(Self.groups, id: \.0) { title, actions in
                Section(title) {
                    ForEach(actions, id: \.rawValue) { action in
                        Toggle(isOn: Binding(
                            get: { preferences.isEnabled(action) },
                            set: { preferences.setEnabled($0, for: action) }
                        )) {
                            HStack {
                                Text(label(for: action))
                                Spacer()
                                Text(Self.syntax[action] ?? "")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.disabledActions) { _, _ in
            controller.refresh()
        }
        .onChange(of: preferences.doubleUnderscoreMeansUnderline) { _, _ in
            controller.refresh()
        }
        .onChange(of: preferences.recognizesDivider) { _, _ in
            controller.refresh()
        }
    }

    private func label(for action: NotesAction) -> String {
        switch action {
        case .title: return "标题"
        case .heading: return "小标题"
        case .subheading: return "副标题"
        case .body: return "正文"
        case .monospaced: return "等宽样式"
        case .bulletedList: return "项目符号列表"
        case .dashedList: return "短划线列表"
        case .numberedList: return "编号列表"
        case .checklist: return "核对清单"
        case .blockQuote: return "块引用"
        case .insertDivider: return "插入分隔线"
        case .bold: return "粗体"
        case .italic: return "斜体"
        case .underline: return "下划线"
        case .strikethrough: return "删除线"
        case .highlight: return "高亮标记"
        case .table: return "表格"
        case .addLink: return "添加链接"
        case .pasteAsMarkdown: return "粘贴为 Markdown"
        case .copyAsMarkdown: return "拷贝为 Markdown"
        case .newNote: return "新建备忘录"
        case .markChecked: return "标记为已勾选"
        case .alignLeft: return "左对齐"
        case .alignRight: return "右对齐"
        case .alignCenter: return "居中"
        case .alignJustify: return "两端对齐"
        }
    }
}
