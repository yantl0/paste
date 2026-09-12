import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var monitor: ClipboardMonitor!
    private var launcher: LauncherManager!
    private var mouseMapper: MouseMapper!
    private var panelController: PanelController!
    private var settingsController: SettingsWindowController?
    private var statusItem: NSStatusItem!
    private var showPanelItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!

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

        // 剪贴板面板快捷键 + 应用快捷启动
        launcher = LauncherManager(directory: store.baseDir)
        launcher.onPanelHotKey = { [weak self] in self?.panelController.toggle() }
        let failures = launcher.start()
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "部分快捷键无法注册"
            alert.informativeText = "可能已被其他应用占用：\n" + failures.joined(separator: "\n") + "\n\n可在「设置」中更换。"
            alert.runModal()
        }

        // 鼠标按键映射（需要辅助功能权限，未授权时会在授权后自动启动）
        mouseMapper = MouseMapper(directory: store.baseDir)
        mouseMapper.start()

        setupStatusItem()

        if !Paster.isAccessibilityTrusted() {
            Paster.requestAccessibility()
        }

        handleCommandLine()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    /// 调试 / 脚本用参数：
    ///   --show               启动后直接打开剪贴板面板
    ///   --settings           启动后直接打开设置窗口
    ///   --import <文件路径>   导入快捷键配置（Paste / Thor 格式），结果写入系统日志
    ///   --export <文件路径>   导出快捷键配置（Thor 兼容格式）
    private func handleCommandLine() {
        let args = CommandLine.arguments
        if args.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.panelController.show()
            }
        }
        if args.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showSettings()
            }
        }
        if let i = args.firstIndex(of: "--export"), i + 1 < args.count {
            do {
                try launcher.export(to: URL(fileURLWithPath: args[i + 1]))
                NSLog("导出快捷键配置完成: %@", args[i + 1])
            } catch {
                NSLog("导出快捷键配置失败: %@", error.localizedDescription)
            }
        }
        if let i = args.firstIndex(of: "--import"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            do {
                let report = try launcher.importItems(from: url)
                NSLog("导入快捷键配置完成: %@", report.summary.replacingOccurrences(of: "\n", with: " | "))
            } catch {
                NSLog("导入快捷键配置失败: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        showPanelItem = NSMenuItem(title: "显示剪贴板记录", action: #selector(showPanel), keyEquivalent: "")
        showPanelItem.target = self
        menu.addItem(showPanelItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        accessibilityItem = NSMenuItem(title: "辅助功能权限", action: #selector(openAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "清空所有记录…", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "退出 Paste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func showPanel() {
        // 从菜单触发时我们的 App 已被激活，稍等菜单收起再显示
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.panelController.show()
        }
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(manager: launcher, mapper: mouseMapper)
        }
        settingsController?.show()
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
            panelController.refreshIfVisible()
        }
    }

    @objc private func toggleLaunchAtLogin() {
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
        let shortcut = launcher.panelShortcut
        showPanelItem.title = "显示剪贴板记录"
        if let key = shortcut.menuKeyEquivalent {
            showPanelItem.keyEquivalent = key
            showPanelItem.keyEquivalentModifierMask = shortcut.modifiers
        } else {
            showPanelItem.keyEquivalent = ""
            showPanelItem.title = "显示剪贴板记录  \(shortcut.display)"
        }
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        accessibilityItem.title = Paster.isAccessibilityTrusted() ? "辅助功能权限：已授权" : "辅助功能权限：未授权（点击设置）…"
    }
}
