// menudump — 导出 Apple Notes 的完整菜单树（含每项快捷键与勾选状态）。
//
// AppKit 默认不填充未打开的子菜单，需要先给目标 App 打开 AXEnhancedUserInterface，
// 否则只能拿到菜单栏的顶层项。
//
// 运行： swift Tools/menudump.swift            # 打印可读树
//       swift Tools/menudump.swift --json     # 额外写 menudump.json

import ApplicationServices
import AppKit
import Foundation

func asAXElement(_ v: CFTypeRef) -> AXUIElement? {
    guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(v, to: AXUIElement.self)
}

func asCFArray(_ v: CFTypeRef) -> CFArray? {
    guard CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
    return unsafeBitCast(v, to: CFArray.self)
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &out) == .success else { return nil }
    return out
}

func str(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
    guard let v = attr(el, name), let arr = asCFArray(v) else { return [] }
    var out: [AXUIElement] = []
    for i in 0..<CFArrayGetCount(arr) {
        guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
        if let e = asAXElement(unsafeBitCast(raw, to: CFTypeRef.self)) { out.append(e) }
    }
    return out
}

// MARK: - 菜单遍历

final class MenuNode: Encodable {
    var title: String
    var role: String
    var cmdChar: String?
    var cmdModifiers: Int?
    var cmdGlyph: String?
    var markChar: String?
    var enabled: Bool?
    var children: [MenuNode] = []

    init(title: String, role: String, cmdChar: String?, cmdModifiers: Int?,
         cmdGlyph: String?, markChar: String?, enabled: Bool?) {
        self.title = title
        self.role = role
        self.cmdChar = cmdChar
        self.cmdModifiers = cmdModifiers
        self.cmdGlyph = cmdGlyph
        self.markChar = markChar
        self.enabled = enabled
    }
}

func modifierString(_ raw: Int) -> String {
    // AXMenuItemCmdModifiers: 0 = ⌘；bit0 ⇧，bit1 ⌥，bit2 ⌃，bit3 表示无修饰键
    if raw & 0b1000 != 0 { return "" }
    var s = "⌘"
    if raw & 0b0100 != 0 { s = "⌃" + s }
    if raw & 0b0010 != 0 { s = "⌥" + s }
    if raw & 0b0001 != 0 { s = "⇧" + s }
    return s
}

func shortcut(_ node: MenuNode) -> String? {
    guard let c = node.cmdChar, !c.isEmpty, let m = node.cmdModifiers else { return nil }
    return modifierString(m) + c.uppercased()
}

func walk(_ el: AXUIElement, depth: Int) -> [MenuNode] {
    guard depth < 8 else { return [] }
    var out: [MenuNode] = []
    for child in elements(el, kAXChildrenAttribute as String) {
        let role = str(child, kAXRoleAttribute as String) ?? ""
        // AXMenu 只是容器，把它的菜单项提升到当前层级
        if role == (kAXMenuRole as String) {
            out.append(contentsOf: walk(child, depth: depth + 1))
            continue
        }
        guard role == (kAXMenuItemRole as String) || role == (kAXMenuBarItemRole as String) else { continue }
        let node = MenuNode(
            title: str(child, kAXTitleAttribute as String) ?? "",
            role: role,
            cmdChar: str(child, kAXMenuItemCmdCharAttribute as String),
            cmdModifiers: (attr(child, kAXMenuItemCmdModifiersAttribute as String) as? NSNumber)?.intValue,
            cmdGlyph: str(child, kAXMenuItemCmdGlyphAttribute as String),
            markChar: str(child, kAXMenuItemMarkCharAttribute as String),
            enabled: (attr(child, kAXEnabledAttribute as String) as? NSNumber)?.boolValue
        )
        node.children = walk(child, depth: depth + 1)
        out.append(node)
    }
    return out
}

func printTree(_ nodes: [MenuNode], indent: String = "") {
    for n in nodes {
        var line = indent + (n.title.isEmpty ? "<空标题>" : n.title)
        if let s = shortcut(n) { line += "   [\(s)]" }
        if let mk = n.markChar, !mk.isEmpty { line += "  ✓" }
        if n.enabled == false { line += "  (禁用)" }
        print(line)
        printTree(n.children, indent: indent + "    ")
    }
}

// MARK: - main

guard AXIsProcessTrusted() else {
    print("没有辅助功能权限。请到「系统设置 > 隐私与安全性 > 辅助功能」授权后重试。")
    exit(1)
}
guard let notes = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first else {
    print("备忘录未运行。")
    exit(1)
}

let app = AXUIElementCreateApplication(notes.processIdentifier)
AXUIElementSetMessagingTimeout(app, 10.0)

// 关键：让 AppKit 把菜单树完整填充出来，否则子菜单是空的
let enhancedKey = "AXEnhancedUserInterface" as CFString
let before = attr(app, enhancedKey as String)
AXUIElementSetAttributeValue(app, enhancedKey, kCFBooleanTrue)
defer {
    if before == nil {
        AXUIElementSetAttributeValue(app, enhancedKey, kCFBooleanFalse)
    } else if let b = before {
        AXUIElementSetAttributeValue(app, enhancedKey, b)
    }
}

guard let rawMenuBar = attr(app, kAXMenuBarAttribute as String),
      let menuBar = asAXElement(rawMenuBar) else {
    print("拿不到菜单栏。")
    exit(1)
}

let tree = walk(menuBar, depth: 0)
printTree(tree)

if CommandLine.arguments.contains("--json") {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("menudump.json")
    if let data = try? enc.encode(tree) {
        try? data.write(to: url)
        print("\n已写入 \(url.path)")
    }
}
