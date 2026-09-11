import Carbon

/// 全局快捷键注册中心。基于 Carbon RegisterEventHotKey，不需要辅助功能权限。
/// 只安装一个事件处理器，按 EventHotKeyID.id 分发到各自的回调。
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        let shortcut: Shortcut
        var ref: EventHotKeyRef?
        let action: () -> Void
    }

    private var handlerRef: EventHandlerRef?
    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private(set) var isSuspended = false

    private init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData, let event = event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.entries[hotKeyID.id]?.action()
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
    }

    /// 注册成功返回 id，失败（系统拒绝或重复）返回 nil。
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        var entry = Entry(shortcut: shortcut, ref: nil, action: action)
        if !isSuspended {
            guard let ref = carbonRegister(shortcut, id: id) else { return nil }
            entry.ref = ref
        }
        entries[id] = entry
        return id
    }

    func unregister(_ id: UInt32) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let ref = entry.ref { UnregisterEventHotKey(ref) }
    }

    /// 录制快捷键期间暂停全部热键，避免录制时误触发。
    func suspendAll() {
        guard !isSuspended else { return }
        isSuspended = true
        for (id, entry) in entries {
            if let ref = entry.ref { UnregisterEventHotKey(ref) }
            entries[id]?.ref = nil
        }
    }

    func resumeAll() {
        guard isSuspended else { return }
        isSuspended = false
        for (id, entry) in entries where entry.ref == nil {
            entries[id]?.ref = carbonRegister(entry.shortcut, id: id)
        }
    }

    private func carbonRegister(_ shortcut: Shortcut, id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5053_5445), id: id) // "PSTE"
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        return status == noErr ? ref : nil
    }
}
