import AppKit
import Carbon.HIToolbox

/// 快捷键录制控件：点击进入录制，按下组合键完成；Esc 取消，⌫ 清除。
final class ShortcutRecorderView: NSControl {
    var shortcut: Shortcut? {
        didSet { needsDisplay = true; toolTip = shortcut?.display }
    }
    var placeholder = "点击录制"
    /// 返回错误信息则拒绝本次录入
    var validator: ((Shortcut) -> String?)?
    var onChange: ((Shortcut?) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            needsDisplay = true
            onRecordingChanged?(isRecording)
        }
    }
    private var liveModifiers: NSEvent.ModifierFlags = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

    // MARK: 交互

    private var clearRect: NSRect {
        NSRect(x: bounds.maxX - 24, y: bounds.midY - 8, width: 16, height: 16)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !isRecording, shortcut != nil, clearRect.contains(p) {
            apply(nil)
            return
        }
        if isRecording {
            endRecording()
            return
        }
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        liveModifiers = []
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        liveModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return false }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        if mods.isEmpty && code == kVK_Escape { endRecording(); return }
        if mods.isEmpty && (code == kVK_Delete || code == kVK_ForwardDelete) { apply(nil); return }

        let candidate = Shortcut(keyCode: code, modifiers: mods)
        guard candidate.thorString != nil else { reject("不支持这个按键"); return }
        guard candidate.hasUsableModifier else { reject("请至少包含 ⌘、⌥、⌃ 中的一个修饰键，或使用 F1–F20 功能键"); return }

        // 先结束录制（恢复全局热键），再校验并应用，保证校验时热键注册状态是真实的
        endRecording()
        if let reason = validator?(candidate) { reject(reason); return }
        shortcut = candidate
        onChange?(candidate)
    }

    private func endRecording() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        isRecording = false
    }

    private func apply(_ s: Shortcut?) {
        endRecording()
        shortcut = s
        onChange?(s)
    }

    private func reject(_ message: String) {
        endRecording()
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "无法使用该快捷键"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            var mods = ""
            if liveModifiers.contains(.control) { mods += "⌃" }
            if liveModifiers.contains(.option) { mods += "⌥" }
            if liveModifiers.contains(.shift) { mods += "⇧" }
            if liveModifiers.contains(.command) { mods += "⌘" }
            text = mods.isEmpty ? "按下快捷键…" : mods
            color = .controlAccentColor
        } else if let s = shortcut {
            text = s.display
            color = .labelColor
        } else {
            text = placeholder
            color = .tertiaryLabelColor
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isRecording ? .medium : .regular),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let textRect = NSRect(x: bounds.midX - size.width / 2 - (shortcut != nil && !isRecording ? 8 : 0),
                              y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        (text as NSString).draw(in: textRect, withAttributes: attrs)

        if shortcut != nil, !isRecording {
            let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "清除")
            x?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))?
                .draw(in: clearRect, from: .zero, operation: .sourceOver, fraction: 0.5)
        }
    }
}
