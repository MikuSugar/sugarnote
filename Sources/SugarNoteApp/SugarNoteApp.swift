import AppKit
import SwiftUI
import SugarNoteCore

@main
struct SugarNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SugarNoteController()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(controller: controller)
        } label: {
            // 状态一目了然：正常工作时是带勾的文本图标，其它情况是带叉的
            Image(systemName: controller.status == .watching
                  ? "text.badge.checkmark"
                  : "text.badge.xmark")
                // 不设的话状态栏项的可访问性名字会是 SF Symbol 的描述（「带X标记的文本」），
                // 用 VoiceOver 或辅助功能查这个 App 时会一头雾水
                .accessibilityLabel("sugarnote")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(controller: controller)
                .frame(width: 460)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 直接从命令行跑（没套 .app bundle）时，LSUIElement 不生效，
        // 这里兜一下，保证开发期 `swift run sugarnote-app` 也不会跳进 Dock。
        if Bundle.main.bundleIdentifier == nil
            || !Bundle.main.bundlePath.hasSuffix(".app") {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
