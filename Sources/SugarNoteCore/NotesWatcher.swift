import ApplicationServices
import Foundation

/// 订阅备忘录正文的 AX 变更通知。
///
/// 刻意不用 `CGEventTap` 做全局键盘监听（ProNotes 是那么干的）。监听通知的好处：
/// - 不需要看用户的按键，只看正文本身的变化，隐私面小得多；
/// - 天然兼容输入法——拼字阶段正文没变，就不会被触发；
/// - 少一个「键盘监听」的敏感权限叙事。
///
/// 需要订阅两类通知：
/// - App 级的 `AXFocusedUIElementChanged`：用户切换笔记或焦点进出正文时，
///   正文元素会换一个对象，得重新订阅；
/// - 正文元素上的 `AXValueChanged` / `AXSelectedTextChanged`：真正的文本变化。
///
/// 线程约定：AXObserver 的回调经由 run loop source 投递，`start()` 把 source 加在
/// 主 run loop 上，所以所有回调都在主线程；合并用的 `pending` 标志也只在主线程读写。
/// 这个不变式让 `@unchecked Sendable` 成立。
public final class NotesWatcher: @unchecked Sendable {

    public enum Event: Sendable {
        case textChanged
        case focusChanged
    }

    /// 静默去抖时长。
    ///
    /// 不能一有变化就动手：用户敲 `# ` 之后会紧接着敲标题文字，如果我们在这中间
    /// 改文本并回写光标，下一个字符会落到错误位置——实测敲 `# 标题` 会变成 `题标`（乱序）。
    /// 等键盘安静一下再判断，既避开了这个竞态，也少做很多无用功。
    private let debounceInterval: TimeInterval

    private let app: NotesApp
    private let onEvent: (Event) -> Void
    private var observer: AXObserver?
    private var subscribedElement: AXUIElement?
    private nonisolated(unsafe) var pendingWork: DispatchWorkItem?

    public init(app: NotesApp,
                debounceInterval: TimeInterval = 0.15,
                onEvent: @escaping (Event) -> Void) {
        self.app = app
        self.debounceInterval = debounceInterval
        self.onEvent = onEvent
    }

    deinit { stop() }

    public func start() {
        guard observer == nil else { return }

        var observerRef: AXObserver?
        let error = AXObserverCreate(app.pid, notesWatcherCallback, &observerRef)
        guard error == .success, let observerRef else {
            NSLog("[sugarnote] AXObserverCreate 失败: \(error.rawValue)")
            return
        }
        observer = observerRef
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observerRef), .defaultMode)

        addNotification(observerRef, app.element, kAXFocusedUIElementChangedNotification)
        resubscribeToNoteText()
    }

    public func stop() {
        pendingWork?.cancel()
        pendingWork = nil
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        subscribedElement = nil
    }

    // MARK: - 订阅

    private func addNotification(_ observer: AXObserver, _ element: AXUIElement, _ name: String) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let error = AXObserverAddNotification(observer, element, name as CFString, refcon)
        if error != .success && error != .notificationAlreadyRegistered {
            NSLog("[sugarnote] 订阅 \(name) 失败: \(error.rawValue)")
        }
    }

    /// 重新定位正文元素并订阅。切换笔记后必须重来一次，因为元素对象换了。
    private func resubscribeToNoteText() {
        guard let observer else { return }
        guard let note = app.focusedNoteText() else {
            subscribedElement = nil
            return
        }
        if let current = subscribedElement, CFEqual(current, note.element) { return }

        subscribedElement = note.element
        addNotification(observer, note.element, kAXValueChangedNotification)
        addNotification(observer, note.element, kAXSelectedTextChangedNotification)
    }

    // MARK: - 回调

    fileprivate func handle(notification: String, element: AXUIElement) {
        if notification == (kAXFocusedUIElementChangedNotification as String) {
            resubscribeToNoteText()
            schedule(.focusChanged)
        } else {
            schedule(.textChanged)
        }
    }

    /// 静默去抖 + 合并。
    ///
    /// 一次按键 Notes 可能连发 `AXValueChanged` + `AXSelectedTextChanged`，每次都要读
    /// 整篇文本（跨进程 IPC），不合并就是白读好几遍。更关键的是不能马上动手——
    /// 用户敲完触发字符还会继续敲内容，中间改文本会打乱输入顺序（见 `debounceInterval` 注释）。
    private func schedule(_ event: Event) {
        pendingWork?.cancel()
        let handler = onEvent
        let work = DispatchWorkItem { [weak self] in
            self?.pendingWork = nil
            handler(event)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}

/// `AXObserverCreate` 要的是 C 函数指针，不能捕获上下文，实例通过 refcon 传进来。
private let notesWatcherCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let watcher = Unmanaged<NotesWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handle(notification: notification as String, element: element)
}
