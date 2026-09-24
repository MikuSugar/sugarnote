// axprobe — 验证 Apple Notes 在本机 macOS 上暴露的 Accessibility 接口。
//
// 用途：确定 sugarnote 的核心可行性。需要先给运行它的宿主（Terminal / ZCode）授予
// 「系统设置 > 隐私与安全性 > 辅助功能」权限，否则只会打印一行 false。
//
// 运行： swift Tools/axprobe.swift
//       swift Tools/axprobe.swift --dump-menus   # 额外导出完整菜单树到 axprobe-menus.json
//
// 只读：不会修改任何笔记内容。

import ApplicationServices
import AppKit
import Foundation

// MARK: - CF 类型安全转换

func asAXElement(_ v: CFTypeRef) -> AXUIElement? {
    guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(v, to: AXUIElement.self)
}

func asAXValue(_ v: CFTypeRef) -> AXValue? {
    guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    return unsafeBitCast(v, to: AXValue.self)
}

func asCFArray(_ v: CFTypeRef) -> CFArray? {
    guard CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
    return unsafeBitCast(v, to: CFArray.self)
}

// MARK: - 基础工具

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &out) == .success else { return nil }
    return out
}

func str(_ el: AXUIElement, _ name: String) -> String? {
    attr(el, name) as? String
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    guard let v = attr(el, kAXChildrenAttribute as String), let arr = asCFArray(v) else { return [] }
    var out: [AXUIElement] = []
    for i in 0..<CFArrayGetCount(arr) {
        guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
        let obj = unsafeBitCast(raw, to: CFTypeRef.self)
        if let el = asAXElement(obj) { out.append(el) }
    }
    return out
}

func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
    guard let v = attr(el, name), let arr = asCFArray(v) else { return [] }
    var out: [AXUIElement] = []
    for i in 0..<CFArrayGetCount(arr) {
        guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
        let obj = unsafeBitCast(raw, to: CFTypeRef.self)
        if let e = asAXElement(obj) { out.append(e) }
    }
    return out
}

func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
    guard let v = attr(el, name) else { return nil }
    return asAXElement(v)
}

func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
    var out: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(el, name as CFString, &out) == .success else { return false }
    return out.boolValue
}

func describe(_ el: AXUIElement) -> String {
    let role = str(el, kAXRoleAttribute as String) ?? "?"
    let sub = str(el, kAXSubroleAttribute as String) ?? ""
    let ident = str(el, kAXIdentifierAttribute as String) ?? ""
    let title = str(el, kAXTitleAttribute as String) ?? ""
    let desc = str(el, kAXDescriptionAttribute as String) ?? ""
    return "role=\(role) subrole=\(sub) id=\(ident) title=\(title) desc=\(desc)"
}

// MARK: - 菜单树

final class MenuItemInfo: Encodable {
    var title: String
    var cmdChar: String?
    var cmdModifiers: Int?
    var markChar: String?
    var enabled: Bool?
    var children: [MenuItemInfo]?

    init(title: String, cmdChar: String?, cmdModifiers: Int?, markChar: String?, enabled: Bool?) {
        self.title = title
        self.cmdChar = cmdChar
        self.cmdModifiers = cmdModifiers
        self.markChar = markChar
        self.enabled = enabled
    }
}

func modifierString(_ raw: Int) -> String {
    // AXMenuItemCmdModifiers: 0 = ⌘；bit0 ⇧，bit1 ⌥，bit2 ⌃，bit3 表示无修饰键
    if raw & 0b1000 != 0 { return "none" }
    var s = "cmd"
    if raw & 0b0001 != 0 { s = "shift+" + s }
    if raw & 0b0010 != 0 { s = "opt+" + s }
    if raw & 0b0100 != 0 { s = "ctrl+" + s }
    return s
}

func walkMenu(_ el: AXUIElement, depth: Int, maxDepth: Int) -> [MenuItemInfo] {
    var out: [MenuItemInfo] = []
    for child in children(el) {
        let role = str(child, kAXRoleAttribute as String) ?? ""
        guard role == (kAXMenuItemRole as String) || role == (kAXMenuBarItemRole as String) else { continue }
        let title = str(child, kAXTitleAttribute as String) ?? ""
        let cmdChar = str(child, kAXMenuItemCmdCharAttribute as String)
        let cmdMods = (attr(child, kAXMenuItemCmdModifiersAttribute as String) as? NSNumber)?.intValue
        let markChar = str(child, kAXMenuItemMarkCharAttribute as String)
        let enabled = (attr(child, kAXEnabledAttribute as String) as? NSNumber)?.boolValue
        let info = MenuItemInfo(title: title, cmdChar: cmdChar,
                                cmdModifiers: cmdMods, markChar: markChar, enabled: enabled)
        if depth < maxDepth {
            let sub = walkMenu(child, depth: depth + 1, maxDepth: maxDepth)
            if !sub.isEmpty { info.children = sub }
        }
        out.append(info)
    }
    return out
}

func printMenuTree(_ items: [MenuItemInfo], indent: String = "") {
    for item in items {
        var line = indent + item.title
        if let c = item.cmdChar, let m = item.cmdModifiers, !c.isEmpty {
            line += "   [\(modifierString(m)) \(c.uppercased())]"
        }
        if let mk = item.markChar, !mk.isEmpty { line += "  mark=\(mk)" }
        if item.enabled == false { line += "  (disabled)" }
        print(line)
        if let sub = item.children { printMenuTree(sub, indent: indent + "    ") }
    }
}

// MARK: - 文本区探测

func findTextAreas(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 40 else { return [] }
    var found: [AXUIElement] = []
    let role = str(root, kAXRoleAttribute as String) ?? ""
    if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) {
        found.append(root)
    }
    for child in children(root) {
        found.append(contentsOf: findTextAreas(child, depth: depth + 1))
    }
    return found
}

func probeTextArea(_ el: AXUIElement) {
    print("  \(describe(el))")

    var names: CFArray?
    if AXUIElementCopyAttributeNames(el, &names) == .success, let list = names as? [String] {
        let interesting = list.filter {
            $0.contains("Value") || $0.contains("Selected") || $0.contains("Range")
                || $0.contains("String") || $0.contains("Marker")
        }
        print("  可读属性(节选): \(interesting.sorted().joined(separator: ", "))")
        for a in [kAXValueAttribute as String, kAXSelectedTextAttribute as String,
                  kAXSelectedTextRangeAttribute as String] {
            print("   settable[\(a)] = \(isSettable(el, a))")
        }
    } else {
        print("  拿不到属性名列表")
    }

    if let v = attr(el, kAXValueAttribute as String) as? String {
        print("  AXValue 长度 = \(v.count) 字符")
        print("  AXValue 尾部 120 字符 = \(String(v.suffix(120)).debugDescription)")
    } else {
        print("  AXValue 不可读（或不是 String）")
    }

    if let sel = attr(el, kAXSelectedTextAttribute as String) as? String {
        print("  AXSelectedText = \(sel.debugDescription)")
    } else {
        print("  AXSelectedText 不可读")
    }

    if let r = attr(el, kAXSelectedTextRangeAttribute as String), let av = asAXValue(r) {
        var range = CFRange()
        if AXValueGetValue(av, .cfRange, &range) {
            print("  AXSelectedTextRange = {\(range.location), \(range.length)}")
        }
    } else {
        print("  AXSelectedTextRange 不可读")
    }

    // 参数化属性：只读光标附近的一小段文本，避免每次按键都读整篇笔记
    var pnames: CFArray?
    if AXUIElementCopyParameterizedAttributeNames(el, &pnames) == .success,
       let list = pnames as? [String] {
        print("  参数化属性: \(list.sorted().joined(separator: ", "))")
        if list.contains(kAXStringForRangeParameterizedAttribute as String) {
            var testRange = CFRange(location: 0, length: 40)
            if let rv = AXValueCreate(.cfRange, &testRange) {
                var out: CFTypeRef?
                let err = AXUIElementCopyParameterizedAttributeValue(
                    el, kAXStringForRangeParameterizedAttribute as CFString, rv, &out)
                print("  AXStringForRange(0,40) -> err=\(err.rawValue) value=\(String(describing: out).prefix(80))")
            }
        }
    }
}

// MARK: - main

let trusted = AXIsProcessTrusted()
print("AXIsProcessTrusted = \(trusted)")
guard trusted else {
    print("""

    ⚠️  没有辅助功能权限，无法探测。
    请到「系统设置 > 隐私与安全性 > 辅助功能」把运行本命令的程序（Terminal / iTerm / ZCode）打开，
    然后重新运行。
    """)
    exit(1)
}

guard let notes = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first else {
    print("Apple Notes 未运行，请先打开「备忘录」。")
    exit(1)
}
print("Notes pid = \(notes.processIdentifier)\n")

let app = AXUIElementCreateApplication(notes.processIdentifier)
AXUIElementSetMessagingTimeout(app, 5.0)

print("========== 菜单栏 ==========")
if let menuBar = element(app, kAXMenuBarAttribute as String) {
    let tree = walkMenu(menuBar, depth: 0, maxDepth: 4)
    printMenuTree(tree)
    if CommandLine.arguments.contains("--dump-menus") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("axprobe-menus.json")
        if let data = try? enc.encode(tree) {
            try? data.write(to: url)
            print("\n菜单树已写入 \(url.path)")
        }
    }
} else {
    print("拿不到菜单栏")
}

print("\n========== 窗口里的文本区 ==========")
for (i, w) in elements(app, kAXWindowsAttribute as String).enumerated() {
    print("窗口 #\(i): \(describe(w))")
    for ta in findTextAreas(w) { probeTextArea(ta) }
}

print("\n========== 当前焦点元素 ==========")
if let focused = element(app, kAXFocusedUIElementAttribute as String) {
    print(describe(focused))
    print("  父链：")
    var cur: AXUIElement? = focused
    var hops = 0
    while let c = cur, hops < 12 {
        print("    \(String(repeating: "  ", count: hops))\(describe(c))")
        cur = element(c, kAXParentAttribute as String)
        hops += 1
    }
} else {
    print("拿不到焦点元素（先把光标点进一条笔记的正文里再跑一次）")
}
