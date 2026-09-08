import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var monitor: ClipboardMonitor!
    private var hotKey: HotKey!
    private var panelController: PanelController!
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store(maxItems: 2000)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Paste 无法启动"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        panelController = PanelController(store: store)

        monitor = ClipboardMonitor()
        monitor.onText = { [weak self] text in
            guard let self = self else { return }
            self.store.saveText(text)
            self.panelController.refreshIfVisible()
        }
        monitor.onImage = { [weak self] png, thumb, w, h in
            guard let self = self else { return }
            self.store.saveImage(png: png, thumb: thumb, width: w, height: h)
            self.panelController.refreshIfVisible()
        }
        panelController.onDidWritePasteboard = { [weak self] in
            self?.monitor.ignoreCurrentChange()
        }
        monitor.start()

        // Option + X
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(optionKey))
        hotKey.onPress = { [weak self] in self?.panelController.toggle() }
        if !hotKey.register() {
            NSLog("注册全局快捷键 Option+X 失败")
        }

        setupStatusItem()

        if !Paster.isAccessibilityTrusted() {
            Paster.requestAccessibility()
        }

        // 调试用：`Paste --show` 启动后直接打开面板
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.panelController.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        hotKey?.unregister()
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste")
            button.image?.isTemplate = true
            button.toolTip = "Paste — Option+X 打开剪贴板记录"
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "显示剪贴板记录", action: #selector(showPanel), keyEquivalent: "x")
        showItem.keyEquivalentModifierMask = [.option]
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        let axItem = NSMenuItem(title: "辅助功能权限设置…", action: #selector(openAccessibility), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)
        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "清空所有记录…", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Paste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func showPanel() {
        // 从菜单触发时我们的 App 已被激活，稍等菜单收起再显示
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.panelController.show()
        }
    }

    @objc private func openAccessibility() {
        Paster.openAccessibilitySettings()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "确定要清空所有剪贴板记录吗？"
        alert.informativeText = "此操作不可撤销，包括已保存的图片。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearAll()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置开机启动失败"
            alert.informativeText = "\(error.localizedDescription)\n\n提示：需要以 .app 形式运行（执行 ./build.sh 生成）。"
            alert.runModal()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if #available(macOS 13.0, *) {
            launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        let ax = menu.items.first { $0.action == #selector(openAccessibility) }
        ax?.title = Paster.isAccessibilityTrusted() ? "辅助功能权限：已授权" : "辅助功能权限：未授权（点击设置）…"
    }
}
