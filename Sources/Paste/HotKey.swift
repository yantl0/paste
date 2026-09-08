import Carbon

/// 基于 Carbon RegisterEventHotKey 的全局快捷键，不需要辅助功能权限。
final class HotKey {
    var onPress: (() -> Void)?

    private let keyCode: UInt32
    private let modifiers: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    deinit { unregister() }

    @discardableResult
    func register() -> Bool {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            me.onPress?()
            return noErr
        }
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard installed == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5053_5445), id: 1) // "PSTE"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = handlerRef { RemoveEventHandler(ref); handlerRef = nil }
    }
}
