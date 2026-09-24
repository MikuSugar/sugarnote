import AppKit
import SwiftUI
import SugarNoteCore

/// 菜单栏下拉菜单。
struct StatusMenu: View {
    @ObservedObject var controller: SugarNoteController
    @ObservedObject var preferences = Preferences.shared

    var body: some View {
        Text(statusLine)

        if case .needsPermission = controller.status {
            Button("打开辅助功能设置…") { controller.openAccessibilitySettings() }
        }
        if case .notesNotRunning = controller.status {
            Button("打开备忘录") { controller.openNotes() }
        }

        Divider()

        Toggle("启用 Markdown 快捷输入", isOn: Binding(
            get: { controller.isEnabled },
            set: { controller.setEnabled($0) }
        ))

        if !controller.unresolvedActions.isEmpty {
            Text("⚠️ \(controller.unresolvedActions.count) 个动作在菜单里找不到")
        }

        Divider()

        Text(controller.conversionCount == 0
             ? "还没有转换过"
             : "已转换 \(controller.conversionCount) 次")

        Divider()

        Button("重新扫描备忘录菜单") { controller.rescanMenus() }
        Button("刷新状态") { controller.refresh() }
        Button("诊断（结果写进日志）") {
            let report = controller.diagnose()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(report, forType: .string)
        }

        SettingsLink { Text("设置…") }

        Divider()

        Button("退出 sugarnote") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        var line = controller.status.label
        if let version = controller.notesVersion {
            line += " · 备忘录 \(version)"
        }
        return line
    }
}
