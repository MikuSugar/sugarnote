import ApplicationServices
import CoreGraphics
import Foundation

/// 往目标进程合成按键。
///
/// 只作为 `MenuInvoker` 的兜底：优先用 AXPress 直接触发菜单项，AXPress 不可用时
/// 才退回「合成菜单项自带的快捷键」。合成按键的麻烦在于要处理键盘布局，
/// 所以能不用就不用。
public enum KeySynthesizer {

    /// 按字符 + 修饰键发一次按键。字符通过 `CGEventKeyboardSetUnicodeString` 附带，
    /// 这样不依赖 US 布局的键码表。
    public static func post(_ key: KeyEquivalent, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .privateState) else { return }

        var flags: CGEventFlags = []
        if key.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if key.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if key.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if key.modifiers.contains(.control) { flags.insert(.maskControl) }

        let text = String(key.character)
        let utf16 = Array(text.utf16)

        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: 0,
                                      keyDown: isDown) else { continue }
            event.flags = flags
            utf16.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.postToPid(pid)
        }
    }

    /// 便捷方法：`postCommandKey("n", to: pid)`
    public static func postCommandKey(_ character: Character, to pid: pid_t) {
        post(KeyEquivalent(character: character, modifiers: [.command]), to: pid)
    }

    /// 逐字符往目标进程打字。
    ///
    /// 和 `post(_:to:)` 的区别：这个不带修饰键，是**真实输入**，会走备忘录正常的
    /// 文本输入路径——所以智能列表、智能破折号这类「输入期行为」同样会触发。
    /// 用来测「用户打字时备忘录自己会做什么」时，这是最接近真实按键的手段。
    ///
    /// 注意它**触发不了菜单快捷键**：合成事件配 `CGEventKeyboardSetUnicodeString`
    /// 只能传达字符，AppKit 的菜单快捷键匹配不认（实测 ⌘N 这样发是无效的）。
    /// 菜单操作请走 `MenuInvoker` 的 AXPress。
    public static func typeText(_ text: String,
                                to pid: pid_t,
                                interKeyDelayMicroseconds: UInt32 = 14_000) {
        guard let source = CGEventSource(stateID: .privateState) else { return }

        for scalar in text.unicodeScalars {
            let utf16 = Array(String(scalar).utf16)
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source,
                                          virtualKey: 0,
                                          keyDown: isDown) else { continue }
                event.flags = []
                utf16.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count,
                                                   unicodeString: buffer.baseAddress)
                }
                event.postToPid(pid)
            }
            usleep(interKeyDelayMicroseconds)
        }
    }
}
