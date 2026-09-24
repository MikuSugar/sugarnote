import Foundation
import SugarNoteCore

/// 应用设置。存在 `UserDefaults` 里，键名前缀统一，避免和别的 App 撞。
///
/// 刻意不引入第三方 Defaults 库：设置项就这几个，直接用 `UserDefaults` 更省事，
/// 也少一个依赖。属性用 `@Published` 包一层，这样设置窗口改动能直接驱动界面刷新。
@MainActor
public final class Preferences: ObservableObject {

    public static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        static let enabled = "sugarnote.enabled"
        static let disabledActions = "sugarnote.disabledActions"
        static let doubleUnderscoreMeansUnderline = "sugarnote.doubleUnderscoreMeansUnderline"
        static let recognizesDivider = "sugarnote.recognizesDivider"
        static let verifyCharacterStyles = "sugarnote.verifyCharacterStyles"
        static let lastNotesVersion = "sugarnote.lastNotesVersion"
    }

    /// 总开关。
    @Published public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    /// 被关掉的单个动作。
    @Published public var disabledActions: Set<NotesAction> {
        didSet { defaults.set(disabledActions.map(\.rawValue).sorted(), forKey: Key.disabledActions) }
    }

    /// `__文本__` 映射到「下划线」而不是 Markdown 标准的「粗体」。
    /// 默认 true：备忘录有原生下划线样式，Markdown 没有，按 ProNotes 的习惯走。
    @Published public var doubleUnderscoreMeansUnderline: Bool {
        didSet { defaults.set(doubleUnderscoreMeansUnderline, forKey: Key.doubleUnderscoreMeansUnderline) }
    }

    /// 是否把 `---` 识别为插入分隔线。
    @Published public var recognizesDivider: Bool {
        didSet { defaults.set(recognizesDivider, forKey: Key.recognizesDivider) }
    }

    /// 应用字符样式后是否复核。复核会多几次跨进程读，但能在判断错时自愈。
    @Published public var verifyCharacterStyles: Bool {
        didSet { defaults.set(verifyCharacterStyles, forKey: Key.verifyCharacterStyles) }
    }

    /// 上次见到的备忘录版本。变了就说明 Notes 升级了，菜单结构可能要重扫。
    public var lastNotesVersion: String? {
        get { defaults.string(forKey: Key.lastNotesVersion) }
        set { defaults.set(newValue, forKey: Key.lastNotesVersion) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        let raw = defaults.stringArray(forKey: Key.disabledActions) ?? []
        self.disabledActions = Set(raw.compactMap(NotesAction.init(rawValue:)))
        self.doubleUnderscoreMeansUnderline =
            defaults.object(forKey: Key.doubleUnderscoreMeansUnderline) as? Bool ?? true
        self.recognizesDivider = defaults.object(forKey: Key.recognizesDivider) as? Bool ?? true
        self.verifyCharacterStyles = defaults.object(forKey: Key.verifyCharacterStyles) as? Bool ?? true
    }

    public func isEnabled(_ action: NotesAction) -> Bool {
        !disabledActions.contains(action)
    }

    public func setEnabled(_ enabled: Bool, for action: NotesAction) {
        var set = disabledActions
        if enabled { set.remove(action) } else { set.insert(action) }
        disabledActions = set
    }

    // MARK: - 组装成引擎配置

    public func recognizerOptions() -> RecognizerOptions {
        var options = RecognizerOptions()
        options.doubleUnderscoreMeansUnderline = doubleUnderscoreMeansUnderline
        options.recognizesDivider = recognizesDivider
        return options
    }

    public func engineConfiguration() -> NotesEngine.Configuration {
        var config = NotesEngine.Configuration()
        config.disabledActions = disabledActions
        config.recognizer = recognizerOptions()
        config.verifyCharacterStyles = verifyCharacterStyles
        return config
    }
}
