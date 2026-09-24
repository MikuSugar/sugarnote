import ApplicationServices
import AppKit
import Foundation

/// AX API 的薄封装。
///
/// 存在的理由只有一个：`AXUIElement` 是 CoreFoundation 类型，Swift 6 里
/// `as? AXUIElement` 这类桥接转换会被判定为「必然成功」而报错，必须走
/// `CFGetTypeID` + `unsafeBitCast`。把这些噪音集中在这一层，上层代码才能干净。
public enum AX {

    // MARK: - CF 桥接

    public static func element(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    public static func array(_ value: CFTypeRef) -> CFArray? {
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        return unsafeDowncast(value, to: CFArray.self)
    }

    public static func axValue(_ value: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    public static func range(_ value: CFTypeRef) -> NSRange? {
        guard let av = axValue(value) else { return nil }
        var cf = CFRange()
        guard AXValueGetValue(av, .cfRange, &cf) else { return nil }
        return NSRange(location: cf.location, length: cf.length)
    }

    public static func cfRange(_ range: NSRange) -> AXValue? {
        var cf = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &cf)
    }

    // MARK: - 读属性

    public static func raw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else {
            return nil
        }
        return out
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        raw(element, attribute) as? String
    }

    public static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        (raw(element, attribute) as? NSNumber)?.intValue
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (raw(element, attribute) as? NSNumber)?.boolValue
    }

    public static func range(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        guard let v = raw(element, attribute) else { return nil }
        return range(v)
    }

    public static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = raw(element, attribute) else { return nil }
        return self.element(v)
    }

    public static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let v = raw(element, attribute), let list = array(v) else { return [] }
        var out: [AXUIElement] = []
        out.reserveCapacity(CFArrayGetCount(list))
        for i in 0..<CFArrayGetCount(list) {
            guard let rawChild = CFArrayGetValueAtIndex(list, i) else { continue }
            let child = unsafeBitCast(rawChild, to: CFTypeRef.self)
            if let el = AX.element(child) { out.append(el) }
        }
        return out
    }

    public static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    public static func parameterizedAttributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    public static func parameterized(_ element: AXUIElement,
                                     _ attribute: String,
                                     _ parameter: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, attribute as CFString, parameter, &out)
        guard err == .success else { return nil }
        return out
    }

    public static func parameterizedString(_ element: AXUIElement,
                                           _ attribute: String,
                                           _ parameter: CFTypeRef) -> String? {
        parameterized(element, attribute, parameter) as? String
    }

    // MARK: - 写属性

    @discardableResult
    public static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    public static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var out: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &out) == .success else {
            return false
        }
        return out.boolValue
    }

    @discardableResult
    public static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    // MARK: - 常用属性名
    //
    // 一律用字符串而不是 AppKit 的 `NSAccessibility.Attribute` 常量：
    // 一是那些常量在 Swift 里被重命名/废弃过好几轮，写起来啰嗦；
    // 二是 macOS 26 新增的 `AXHeadingLevel` / `AXBlockQuoteLevel` 带可用性标注，
    // 直接写字符串就不用为它们加 `if #available` 分支。

    public enum Attr {
        public static let role = kAXRoleAttribute as String
        public static let subrole = kAXSubroleAttribute as String
        public static let title = kAXTitleAttribute as String
        public static let description = kAXDescriptionAttribute as String
        public static let identifier = kAXIdentifierAttribute as String
        public static let enabled = kAXEnabledAttribute as String
        public static let children = kAXChildrenAttribute as String
        public static let parent = kAXParentAttribute as String
        public static let window = kAXWindowAttribute as String
        public static let windows = kAXWindowsAttribute as String
        public static let menuBar = kAXMenuBarAttribute as String
        public static let focusedUIElement = kAXFocusedUIElementAttribute as String
        public static let focusedWindow = kAXFocusedWindowAttribute as String
        public static let value = kAXValueAttribute as String
        public static let selectedText = kAXSelectedTextAttribute as String
        public static let selectedTextRange = kAXSelectedTextRangeAttribute as String
        public static let enhancedUserInterface = "AXEnhancedUserInterface"
        public static let menuItemCmdChar = kAXMenuItemCmdCharAttribute as String
        public static let menuItemCmdModifiers = kAXMenuItemCmdModifiersAttribute as String
        public static let menuItemCmdGlyph = kAXMenuItemCmdGlyphAttribute as String
        public static let menuItemMarkChar = kAXMenuItemMarkCharAttribute as String
        public static let menuItemPrimaryUIElement = kAXMenuItemPrimaryUIElementAttribute as String

        /// 输入法组字范围（`NSValue` 包 `NSRange`）。长度 > 0 表示正在拼字。
        public static let textInputMarkedRange = "AXTextInputMarkedRange"
        /// macOS 26 起可用：段落标题层级，1 起算。
        public static let headingLevel = "AXHeadingLevel"
        /// macOS 26 起可用：块引用层级，1 起算。
        public static let blockQuoteLevel = "AXBlockQuoteLevel"

        public static let lineForIndex = "AXLineForIndex"
        public static let rangeForLine = "AXRangeForLine"
        public static let stringForRange = "AXStringForRange"
        public static let styleRangeForIndex = "AXStyleRangeForIndex"
        public static let attributedStringForRange = "AXAttributedStringForRange"
        public static let rangeForIndex = "AXRangeForIndex"
        public static let boundsForRange = "AXBoundsForRange"
    }

    public enum Role {
        public static let menuBar = kAXMenuBarRole as String
        public static let menuBarItem = kAXMenuBarItemRole as String
        public static let menu = kAXMenuRole as String
        public static let menuItem = kAXMenuItemRole as String
        public static let textArea = kAXTextAreaRole as String
        public static let textField = kAXTextFieldRole as String
        public static let window = kAXWindowRole as String
    }
}
