import AppKit
import Carbon.HIToolbox

/// 一个全局快捷键：按键码 + 修饰键。字符串格式与 Thor 兼容，如 "alt+a"、"shift+cmd+f"。
struct Shortcut: Hashable {
    let keyCode: Int
    private let modifierRaw: UInt

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierRaw = modifiers.intersection([.command, .option, .control, .shift]).rawValue
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRaw) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// 合成键盘事件时用的修饰键标志
    var cgFlags: CGEventFlags {
        var f = CGEventFlags()
        if modifiers.contains(.command) { f.insert(.maskCommand) }
        if modifiers.contains(.option) { f.insert(.maskAlternate) }
        if modifiers.contains(.control) { f.insert(.maskControl) }
        if modifiers.contains(.shift) { f.insert(.maskShift) }
        return f
    }

    var isFunctionKey: Bool { keyCode >= kVK_F1 && Shortcut.functionKeyCodes.contains(keyCode) }

    /// 至少包含 ⌘ ⌥ ⌃ 之一，或者本身是 F1–F20 功能键
    var hasUsableModifier: Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty || isFunctionKey
    }

    // MARK: Thor 字符串格式

    /// 顺序与 Thor 一致：shift, ctrl, alt, cmd, key
    var thorString: String? {
        guard let key = Shortcut.keyNames[keyCode] else { return nil }
        var parts: [String] = []
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    init?(thorString: String) {
        var mods = NSEvent.ModifierFlags()
        var code: Int?
        for part in thorString.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            switch String(part) {
            case "shift": mods.insert(.shift)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "option": mods.insert(.option)
            case "cmd", "command": mods.insert(.command)
            default:
                guard code == nil, let c = Shortcut.keyCodes[String(part)] else { return nil }
                code = c
            }
        }
        guard let k = code else { return nil }
        self.init(keyCode: k, modifiers: mods)
    }

    // MARK: 显示

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Shortcut.displayName(forKeyCode: keyCode)
    }

    static func displayName(forKeyCode code: Int) -> String {
        guard let name = keyNames[code] else { return "?" }
        if let special = specialDisplayNames[name] { return special }
        if name.hasPrefix("numpad") {
            return "Num " + name.dropFirst("numpad".count).replacingOccurrences(of: "_", with: " ").capitalized
        }
        return name.uppercased()
    }

    /// 单字符按键名（用于 NSMenuItem.keyEquivalent 展示），非字母数字符号返回 nil
    var menuKeyEquivalent: String? {
        guard let name = Shortcut.keyNames[keyCode], name.count == 1 else { return nil }
        return name
    }

    // MARK: 系统保留快捷键（拒绝录入）

    static let systemReserved: Set<String> = [
        "cmd+space", "alt+cmd+space", "ctrl+cmd+space", "cmd+tab", "shift+cmd+tab",
        "cmd+q", "alt+cmd+escape", "ctrl+cmd+q",
        "shift+cmd+3", "shift+cmd+4", "shift+cmd+5",
        "ctrl+up", "ctrl+down", "ctrl+left", "ctrl+right",
        "cmd+`", "shift+cmd+`",
        "cmd+h", "alt+cmd+h", "cmd+m",
        "cmd+c", "cmd+v", "cmd+x", "cmd+a", "cmd+z", "shift+cmd+z", "cmd+s", "cmd+w", "cmd+n", "cmd+o", "cmd+p", "cmd+f",
    ]

    // MARK: 按键表（与 Thor 的 keycodeMap 一致）

    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static let keyNames: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_S: "s", kVK_ANSI_D: "d", kVK_ANSI_F: "f", kVK_ANSI_H: "h", kVK_ANSI_G: "g",
        kVK_ANSI_Z: "z", kVK_ANSI_X: "x", kVK_ANSI_C: "c", kVK_ANSI_V: "v", kVK_ANSI_B: "b", kVK_ANSI_Q: "q",
        kVK_ANSI_W: "w", kVK_ANSI_E: "e", kVK_ANSI_R: "r", kVK_ANSI_Y: "y", kVK_ANSI_T: "t", kVK_ANSI_O: "o",
        kVK_ANSI_U: "u", kVK_ANSI_I: "i", kVK_ANSI_P: "p", kVK_ANSI_L: "l", kVK_ANSI_J: "j", kVK_ANSI_K: "k",
        kVK_ANSI_N: "n", kVK_ANSI_M: "m",
        kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
        kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_RightBracket: "]", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_Quote: "\"", kVK_ANSI_Semicolon: ";", kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",",
        kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Grave: "`",
        kVK_ANSI_KeypadDecimal: "numpad_decimal", kVK_ANSI_KeypadMultiply: "numpad_multiply",
        kVK_ANSI_KeypadPlus: "numpad_add", kVK_ANSI_KeypadDivide: "numpad_divide",
        kVK_ANSI_KeypadMinus: "numpad_subtract", kVK_ANSI_KeypadClear: "numpad_clear",
        kVK_ANSI_KeypadEnter: "numpad_enter", kVK_ANSI_KeypadEquals: "numpad_equals",
        kVK_ANSI_Keypad0: "numpad0", kVK_ANSI_Keypad1: "numpad1", kVK_ANSI_Keypad2: "numpad2",
        kVK_ANSI_Keypad3: "numpad3", kVK_ANSI_Keypad4: "numpad4", kVK_ANSI_Keypad5: "numpad5",
        kVK_ANSI_Keypad6: "numpad6", kVK_ANSI_Keypad7: "numpad7", kVK_ANSI_Keypad8: "numpad8",
        kVK_ANSI_Keypad9: "numpad9",
        kVK_Return: "return", kVK_End: "end", kVK_Home: "home", kVK_Tab: "tab", kVK_Escape: "escape",
        kVK_Space: "space", kVK_Delete: "delete", kVK_CapsLock: "capslock", kVK_PageDown: "pagedown",
        kVK_PageUp: "pageup",
        kVK_LeftArrow: "left", kVK_RightArrow: "right", kVK_DownArrow: "down", kVK_UpArrow: "up",
        kVK_F1: "f1", kVK_F2: "f2", kVK_F3: "f3", kVK_F4: "f4", kVK_F5: "f5", kVK_F6: "f6", kVK_F7: "f7",
        kVK_F8: "f8", kVK_F9: "f9", kVK_F10: "f10", kVK_F11: "f11", kVK_F12: "f12", kVK_F13: "f13",
        kVK_F14: "f14", kVK_F15: "f15", kVK_F16: "f16", kVK_F17: "f17", kVK_F18: "f18", kVK_F19: "f19",
        kVK_F20: "f20",
    ]

    static let keyCodes: [String: Int] = {
        var m: [String: Int] = [:]
        for (code, name) in keyNames { m[name] = code }
        return m
    }()

    private static let specialDisplayNames: [String: String] = [
        "return": "↩", "tab": "⇥", "escape": "⎋", "space": "Space", "delete": "⌫",
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟", "capslock": "⇪",
    ]
}
