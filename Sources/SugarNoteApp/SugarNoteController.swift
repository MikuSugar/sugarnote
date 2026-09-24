import AppKit
import Combine
import Foundation
import SugarNoteCore

/// 把「备忘录的生命周期」和「引擎」接起来。
///
/// 备忘录可能被退出、重启、升级。每次都要重建 `NotesApp` / `NotesWatcher`，
/// 并在版本变化时重扫菜单（Notes 升级后菜单结构可能变）。
@MainActor
public final class SugarNoteController: ObservableObject {

    public enum Status: Equatable {
        case needsPermission
        case notesNotRunning
        case watching
        case paused
        case failed(String)

        public var label: String {
            switch self {
            case .needsPermission: return "需要辅助功能权限"
            case .notesNotRunning: return "备忘录未运行"
            case .watching: return "正在工作"
            case .paused: return "已暂停"
            case .failed(let reason): return "出错：\(reason)"
            }
        }
    }

    @Published public private(set) var status: Status = .notesNotRunning
    @Published public private(set) var notesVersion: String?
    @Published public private(set) var conversionCount = 0
    @Published public private(set) var lastSummary: String?
    /// 菜单索引里解析不到的动作。非空说明备忘录的菜单变了，需要跟进。
    @Published public private(set) var unresolvedActions: [NotesAction] = []

    /// 是否已经弹过权限请求。系统只让弹一次，重复请求没意义还会烦人。
    private var hasRequestedPermission = false

    /// 等待授权时的轮询定时器。
    ///
    /// 缺了它会出现这种情况：用户去系统设置把开关打开，回到 App 却还是显示「需要权限」——
    /// 因为 App 只在启动和手动点「刷新状态」时检查。实测就踩了这个：用户授了权、以为没生效，
    /// 实际只是没人去重查。有定时器（外加切回前台时立刻重查）就不会了。
    private var permissionPollTimer: Timer?
    private let preferences: Preferences
    private var notes: NotesApp?
    private var watcher: NotesWatcher?
    private var engine: NotesEngine?
    private var workspaceObservers: [NSObjectProtocol] = []

    public init(preferences: Preferences = .shared) {
        self.preferences = preferences
        observeWorkspace()
        refresh()
    }

    // 不做 deinit 清理：这个 controller 在 App 生命周期里只创建一次，
    // 观察者回调持有的是 weak self，不构成循环引用，随进程退出一起结束。

    // MARK: - 生命周期

    private func observeWorkspace() {
        // 从系统设置切回来时立刻重查一次权限
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !AXIsProcessTrusted() || self.status == .needsPermission else { return }
                self.refresh()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == NotesApp.bundleIdentifier
                else { return }
                Task { @MainActor in self?.refresh() }
            }
            workspaceObservers.append(observer)
        }
    }

    /// 重新检查权限、备忘录进程，按需重建监听。
    public func refresh() {
        // 这几条 guard 是出问题时唯一能定位的地方，所以每一步都记日志。
        // 排查指令：log show --predicate 'process == "sugarnote"' --last 10m
        guard preferences.isEnabled else {
            teardown()
            status = .paused
            Log.write("[sugarnote] 状态：已暂停（总开关关着）")
            return
        }
        guard AXIsProcessTrusted() else {
            teardown()
            status = .needsPermission
            // 主动请求一次，让系统弹窗把它加进辅助功能列表——不请求的话列表里可能
            // 根本没有 sugarnote，用户得手动点「+」去 Applications 里翻。
            if !hasRequestedPermission {
                hasRequestedPermission = true
                // 直接写键名而不是用 kAXTrustedCheckOptionPrompt：后者是 C 的全局 var，
                // Swift 6 严格并发下不让引用
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            Log.write("[sugarnote] 状态：缺少辅助功能权限。"
                      + "到「系统设置 > 隐私与安全性 > 辅助功能」把 sugarnote 打开。")
            startPermissionPolling()
            return
        }
        guard let running = NotesApp.running() else {
            teardown()
            status = .notesNotRunning
            Log.write("[sugarnote] 状态：备忘录未运行")
            return
        }

        // 备忘录重启过就重建
        if notes?.pid != running.pid {
            teardown()
            notes = running
        }
        guard let notes else { return }

        notesVersion = notes.versionString
        if engine == nil {
            let engine = NotesEngine(app: notes, configuration: preferences.engineConfiguration())
            engine.log = { message in
                Log.write("[sugarnote] \(message)")
            }
            self.engine = engine
        }
        engine?.configuration = preferences.engineConfiguration()

        // Notes 升级后菜单结构可能变，重扫一次
        if let version = notesVersion, version != preferences.lastNotesVersion {
            preferences.lastNotesVersion = version
            let index = engine?.refreshMenuIndex()
            unresolvedActions = index?.unresolvedActions ?? []
            Log.write("[sugarnote] 备忘录版本 \(version)，重扫菜单，"
                      + "\(unresolvedActions.count) 个动作解析不到")
        } else if unresolvedActions.isEmpty {
            unresolvedActions = engine?.currentMenuIndex().unresolvedActions ?? []
        }

        let wasWatching = watcher != nil
        startWatchingIfNeeded()
        status = .watching
        if !wasWatching {
            let index = engine?.currentMenuIndex()
            Log.write("[sugarnote] 状态：正在工作。备忘录 \(notesVersion ?? "版本未知")"
                      + " (pid \(running.pid))，菜单里 \(NotesAction.allCases.count) 个动作，"
                      + "\(index?.unresolvedActions.count ?? -1) 个解析不到")
        }
    }

    private func startWatchingIfNeeded() {
        guard watcher == nil, let notes else { return }
        let watcher = NotesWatcher(app: notes) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        watcher.start()
        self.watcher = watcher
        Log.write("[sugarnote] 已订阅备忘录正文的变化通知")
    }

    private func teardown() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        watcher?.stop()
        watcher = nil
        engine = nil
        notes = nil
    }

    /// 等待授权期间每隔 2 秒重查一次，一旦拿到权限就自动开工。
    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard AXIsProcessTrusted() else { return }
                Log.write("[sugarnote] 检测到已获得辅助功能权限，开始工作")
                self.permissionPollTimer?.invalidate()
                self.permissionPollTimer = nil
                self.refresh()
            }
        }
    }

    /// 把当前状态写进日志，供排查。菜单里的「诊断」会调它。
    @discardableResult
    public func diagnose() -> String {
        var lines: [String] = []
        lines.append("sugarnote 诊断")
        lines.append("  辅助功能权限：\(AXIsProcessTrusted() ? "有" : "没有")")
        lines.append("  总开关：\(preferences.isEnabled ? "开" : "关")")
        lines.append("  状态：\(status.label)")
        lines.append("  备忘录在运行：\(NotesApp.running() != nil)")
        if let notes = NotesApp.running() {
            lines.append("  备忘录版本：\(notes.versionString ?? "未知")  pid \(notes.pid)")
            lines.append("  备忘录在前台：\(notes.isFrontmost)")
            lines.append("  订阅了正文通知：\(watcher != nil)")
            if let note = notes.focusedNoteText() ?? notes.anyNoteText() {
                lines.append("  正文元素：\(note.noteID ?? "未知")  长度 \(note.textLength.map(String.init) ?? "读不到")")
            } else {
                lines.append("  正文元素：找不到（光标不在正文里？）")
            }
            let index = engine?.currentMenuIndex()
            lines.append("  菜单解析：\(NotesAction.allCases.count) 个动作，"
                         + "\(index?.unresolvedActions.count ?? -1) 个解析不到")
        }
        lines.append("  已转换次数：\(conversionCount)")
        if let lastSummary { lines.append("  最近一次：\(lastSummary)") }
        let report = lines.joined(separator: "\n")
        Log.write(report)
        return report
    }

    private func handle(_ event: NotesWatcher.Event) {
        guard preferences.isEnabled, event == .textChanged, let engine else { return }
        let outcome = engine.handleTextChange()
        lastSummary = outcome.summary
        if outcome.didConvert {
            conversionCount += 1
            Log.write("[sugarnote] \(outcome.summary)")
        }
    }

    // MARK: - 操作

    public func setEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
        refresh()
    }

    public var isEnabled: Bool { preferences.isEnabled }

    /// 打开「系统设置 > 隐私与安全性 > 辅助功能」。
    public func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    public func openNotes() {
        let url = URL(fileURLWithPath: "/System/Applications/Notes.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 重新扫描备忘录菜单。菜单解析出问题时可以手动重试。
    public func rescanMenus() {
        let index = engine?.refreshMenuIndex() ?? {
            guard let notes = NotesApp.running() else { return nil }
            return NotesEngine(app: notes, configuration: preferences.engineConfiguration()).refreshMenuIndex()
        }()
        unresolvedActions = index?.unresolvedActions ?? []
    }
}

extension NotesApp {
    /// 备忘录的版本号，用于判断升级。取不到返回 nil。
    var versionString: String? {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              let bundle = Bundle(url: url)
        else { return nil }
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return nil
        }
    }
}
