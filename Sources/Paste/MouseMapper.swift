import AppKit
import ApplicationServices

extension Notification.Name {
    static let mouseMappingsDidChange = Notification.Name("PasteMouseMappingsDidChange")
}

/// 一条「鼠标按键 → 键盘快捷键」映射。button 是 CGEvent 的按键编号：2 中键，3 / 4 侧键，更多为扩展键。
struct MouseMapping: Codable, Equatable {
    var button: Int
    var shortcut: String

    var shortcutValue: Shortcut? { shortcut.isEmpty ? nil : Shortcut(thorString: shortcut) }

    static func buttonName(_ button: Int) -> String {
        switch button {
        case 2: return "中键"
        case 3: return "侧键（后退）"
        case 4: return "侧键（前进）"
        default: return "扩展键"
        }
    }
}

/// 用 CGEventTap 拦截鼠标额外按键，按下时合成键盘快捷键。需要辅助功能权限。
final class MouseMapper {
    private(set) var mappings: [MouseMapping] = []
    private(set) var isTapActive = false
    /// 状态变化（监听开始 / 停止、映射列表变动）时回调，供设置界面刷新
    var onStateChanged: (() -> Void)?

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: MouseMapper.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: MouseMapper.enabledKey); updateTapState() }
    }
    /// 映射生效时是否吞掉原始鼠标点击，避免浏览器同时触发「后退」等默认行为
    var swallowClicks: Bool {
        get { UserDefaults.standard.object(forKey: MouseMapper.swallowKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: MouseMapper.swallowKey) }
    }

    /// 学习模式：设置后，下一次鼠标额外按键按下会被吞掉并回调按键编号
    var learnHandler: ((Int) -> Void)? {
        get { pendingLearn }
        set { pendingLearn = newValue; updateTapState() }
    }
    private var pendingLearn: ((Int) -> Void)?

    private let fileURL: URL
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lookup: [Int64: Shortcut] = [:]
    private var swallowedButtons: Set<Int64> = []
    private var retryTimer: Timer?
    private var lastUserInputReenable: CFAbsoluteTime = 0

    private static let enabledKey = "mouseMappingEnabled"
    private static let swallowKey = "mouseSwallowClicks"

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("mouse_mappings.json")
        load()
    }

    deinit { stopTap() }

    func start() { updateTapState() }

    // MARK: - 映射增删改

    func hasMapping(for button: Int) -> Bool { mappings.contains { $0.button == button } }

    /// 返回新增的下标；该按键已存在则返回 nil
    func addMapping(button: Int) -> Int? {
        guard !hasMapping(for: button) else { return nil }
        mappings.append(MouseMapping(button: button, shortcut: ""))
        save()
        return mappings.count - 1
    }

    func setShortcut(_ shortcut: Shortcut?, at index: Int) {
        guard mappings.indices.contains(index) else { return }
        mappings[index].shortcut = shortcut?.thorString ?? ""
        save()
    }

    func remove(at indexes: IndexSet) {
        for i in indexes.sorted(by: >) where mappings.indices.contains(i) {
            mappings.remove(at: i)
        }
        save()
    }

    // MARK: - 事件监听

    var needsTap: Bool {
        pendingLearn != nil || (isEnabled && mappings.contains { $0.shortcutValue != nil })
    }

    private func updateTapState() {
        rebuildLookup()
        if needsTap {
            if tap == nil, !createTap() { scheduleRetry() }
        } else {
            stopTap()
        }
        onStateChanged?()
    }

    private func rebuildLookup() {
        lookup = [:]
        for m in mappings {
            if let s = m.shortcutValue { lookup[Int64(m.button)] = s }
        }
    }

    /// 没有辅助功能权限时 tapCreate 返回 nil；用户授权后由定时器重试，成功即停止
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.needsTap || self.tap != nil || self.createTap() {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
                self.onStateChanged?()
            }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    private func createTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo -> Unmanaged<CGEvent>? in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let mapper = Unmanaged<MouseMapper>.fromOpaque(userInfo).takeUnretainedValue()
            return mapper.handle(type: type, event: event)
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        isTapActive = true
        NSLog("鼠标映射：事件监听已启动")
        return true
    }

    private func stopTap() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            tap = nil
        }
        swallowedButtons = []
        if isTapActive { NSLog("鼠标映射：事件监听已停止") }
        isTapActive = false
    }

    /// 在主线程 RunLoop 上回调，必须尽快返回。返回 nil 表示吞掉事件。
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastUserInputReenable > 2, let t = tap {
                lastUserInputReenable = now
                CGEvent.tapEnable(tap: t, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        switch type {
        case .otherMouseDown:
            if let learn = pendingLearn {
                // 不在事件回调里改动监听器状态，延后到主线程下一轮处理
                pendingLearn = nil
                swallowedButtons.insert(button)
                DispatchQueue.main.async { [weak self] in
                    learn(Int(button))
                    self?.updateTapState()
                }
                return nil
            }
            guard isEnabled, let shortcut = lookup[button] else { return Unmanaged.passUnretained(event) }
            MouseMapper.postKeystroke(shortcut)
            if swallowClicks {
                swallowedButtons.insert(button)
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .otherMouseUp:
            if swallowedButtons.remove(button) != nil { return nil }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// 修饰键的虚拟键码与对应标志位，按「按下顺序」排列
    private static let modifierKeys: [(flag: CGEventFlags, keyCode: CGKeyCode)] = [
        (.maskControl, 59),    // kVK_Control
        (.maskAlternate, 58),  // kVK_Option
        (.maskShift, 56),      // kVK_Shift
        (.maskCommand, 55),    // kVK_Command
    ]

    /// 合成完整的按键序列：依次按下修饰键 → 主键按下/松开 → 逆序松开修饰键。
    /// 只发主键并附带 flags 的话，Chrome 等靠监听 Ctrl 松开来结束「标签切换」状态的应用会一直卡在那个状态。
    private static func postKeystroke(_ shortcut: Shortcut) {
        let source = CGEventSource(stateID: .hidSystemState)
        let target = shortcut.cgFlags
        let pressed = modifierKeys.filter { target.contains($0.flag) }

        var flags = CGEventFlags()
        for m in pressed {
            flags.insert(m.flag)
            post(source, key: m.keyCode, down: true, flags: flags)
        }

        let key = CGKeyCode(shortcut.keyCode)
        post(source, key: key, down: true, flags: flags)
        post(source, key: key, down: false, flags: flags)

        for m in pressed.reversed() {
            flags.remove(m.flag)
            post(source, key: m.keyCode, down: false, flags: flags)
        }
    }

    private static func post(_ source: CGEventSource?, key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MouseMapping].self, from: data) else { return }
        mappings = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(mappings) {
            try? data.write(to: fileURL, options: .atomic)
        }
        updateTapState()
        NotificationCenter.default.post(name: .mouseMappingsDidChange, object: self)
    }
}
