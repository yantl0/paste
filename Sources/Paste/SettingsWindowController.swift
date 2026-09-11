import AppKit
import UniformTypeIdentifiers

/// 设置窗口：剪贴板面板快捷键 + 应用快捷启动列表（增删、录制、导入导出）。
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let manager: LauncherManager
    private let tableView = LauncherTableView()
    private let panelRecorder = ShortcutRecorderView()
    private let removeButton = NSButton()
    private let iconCache = NSCache<NSString, NSImage>()

    init(manager: LauncherManager) {
        self.manager = manager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Paste 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        iconCache.countLimit = 100
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(launchersChanged), name: .launchersDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func launchersChanged() {
        refresh()
    }

    private func refresh() {
        panelRecorder.shortcut = manager.panelShortcut
        tableView.reloadData()
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // 面板快捷键
        let panelTitle = label("剪贴板面板快捷键", size: 13, weight: .semibold)
        let panelDesc = label("按下后打开或关闭剪贴板历史面板", size: 11, color: .secondaryLabelColor)
        let panelText = NSStackView(views: [panelTitle, panelDesc])
        panelText.orientation = .vertical
        panelText.alignment = .leading
        panelText.spacing = 2

        panelRecorder.translatesAutoresizingMaskIntoConstraints = false
        panelRecorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
        panelRecorder.heightAnchor.constraint(equalToConstant: 26).isActive = true
        panelRecorder.validator = { [weak self] s in self?.manager.conflict(for: s, ignoringPanel: true) }
        panelRecorder.onChange = { [weak self] s in
            guard let self = self else { return }
            guard let s = s else {
                // 面板快捷键不允许清空，恢复原值
                self.panelRecorder.shortcut = self.manager.panelShortcut
                return
            }
            if let err = self.manager.setPanelShortcut(s) {
                self.panelRecorder.shortcut = self.manager.panelShortcut
                self.alert("无法使用该快捷键", err)
            }
        }
        panelRecorder.onRecordingChanged = { rec in rec ? HotKeyCenter.shared.suspendAll() : HotKeyCenter.shared.resumeAll() }

        let panelRow = NSStackView(views: [panelText, panelRecorder])
        panelRow.orientation = .horizontal
        panelRow.alignment = .centerY
        panelRow.distribution = .fill
        panelText.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator

        // 启动器
        let launcherTitle = label("应用快捷启动", size: 13, weight: .semibold)
        let launcherDesc = label("按快捷键切换到该应用；应用已在前台时再按一次将其隐藏。点击快捷键列录制。", size: 11, color: .secondaryLabelColor)
        launcherDesc.lineBreakMode = .byWordWrapping
        launcherDesc.maximumNumberOfLines = 2

        let appColumn = NSTableColumn(identifier: .init("app"))
        appColumn.title = "应用"
        appColumn.width = 330
        appColumn.minWidth = 200
        let keyColumn = NSTableColumn(identifier: .init("shortcut"))
        keyColumn.title = "快捷键"
        keyColumn.width = 170
        keyColumn.minWidth = 150
        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(keyColumn)
        tableView.rowHeight = 36
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        if #available(macOS 11.0, *) { tableView.style = .inset }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // 底部按钮
        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "添加")!, target: self, action: #selector(addApps))
        addButton.bezelStyle = .smallSquare
        addButton.toolTip = "添加应用"
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "删除")
        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.toolTip = "删除选中"
        removeButton.isEnabled = false
        for b in [addButton, removeButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let importButton = NSButton(title: "导入…", target: self, action: #selector(importItems))
        let exportButton = NSButton(title: "导出…", target: self, action: #selector(exportItems))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [addButton, removeButton, spacer, importButton, exportButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let root = NSStackView(views: [panelRow, separator, launcherTitle, launcherDesc, scroll, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        root.setCustomSpacing(16, after: panelRow)
        root.setCustomSpacing(16, after: separator)
        root.setCustomSpacing(4, after: launcherTitle)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panelRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            separator.widthAnchor.constraint(equalTo: panelRow.widthAnchor),
            launcherDesc.widthAnchor.constraint(equalTo: panelRow.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: panelRow.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: panelRow.widthAnchor),
        ])
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    // MARK: - 动作

    @objc private func addApps() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application, .applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK else { return }
            let added = self.manager.addApps(panel.urls)
            self.tableView.reloadData()
            if let first = added.first {
                self.tableView.selectRowIndexes(IndexSet(added), byExtendingSelection: false)
                self.tableView.scrollRowToVisible(first)
            }
        }
    }

    @objc private func removeSelected() {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        manager.remove(at: rows)
        tableView.reloadData()
        removeButton.isEnabled = false
    }

    @objc private func importItems() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.title = "导入快捷键配置"
        panel.message = "支持 Paste 和 Thor 导出的 JSON 文件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            do {
                let report = try self.manager.importItems(from: url)
                self.tableView.reloadData()
                let a = NSAlert()
                a.messageText = "导入完成"
                a.informativeText = report.summary
                a.alertStyle = .informational
                a.beginSheetModal(for: window)
            } catch {
                self.alert("导入失败", "文件格式无法识别：\(error.localizedDescription)")
            }
        }
    }

    @objc private func exportItems() {
        guard let window = window else { return }
        let panel = NSSavePanel()
        panel.title = "导出快捷键配置"
        panel.nameFieldStringValue = "paste_shortcuts.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            do {
                try self.manager.export(to: url)
            } catch {
                self.alert("导出失败", error.localizedDescription)
            }
        }
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { manager.items.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = manager.items[row]
        guard let column = tableColumn else { return nil }

        if column.identifier.rawValue == "app" {
            let id = NSUserInterfaceItemIdentifier("AppCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeAppCell(id)
            cell.imageView?.image = icon(for: item)
            if item.exists {
                cell.textField?.stringValue = item.appDisplayName
                cell.textField?.textColor = .labelColor
            } else {
                cell.textField?.stringValue = "\(item.appDisplayName)（未找到应用）"
                cell.textField?.textColor = .secondaryLabelColor
            }
            cell.toolTip = item.path
            return cell
        }

        let id = NSUserInterfaceItemIdentifier("KeyCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? RecorderCell) ?? {
            let c = RecorderCell()
            c.identifier = id
            return c
        }()
        cell.recorder.shortcut = item.shortcutValue
        cell.recorder.isEnabled = item.exists
        cell.recorder.validator = { [weak self, weak cell] s in
            guard let self = self, let cell = cell else { return nil }
            let r = self.tableView.row(for: cell)
            guard r >= 0 else { return nil }
            return self.manager.conflict(for: s, ignoringPath: self.manager.items[r].path)
        }
        cell.recorder.onChange = { [weak self, weak cell] s in
            guard let self = self, let cell = cell else { return }
            let r = self.tableView.row(for: cell)
            guard r >= 0 else { return }
            if let err = self.manager.setShortcut(s, forItemAt: r) {
                cell.recorder.shortcut = self.manager.items[r].shortcutValue
                self.alert("无法使用该快捷键", err)
            }
        }
        cell.recorder.onRecordingChanged = { rec in rec ? HotKeyCenter.shared.suspendAll() : HotKeyCenter.shared.resumeAll() }
        return cell
    }

    private func makeAppCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        cell.addSubview(iv)
        cell.addSubview(tf)
        cell.imageView = iv
        cell.textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 26),
            iv.heightAnchor.constraint(equalToConstant: 26),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func icon(for item: LauncherItem) -> NSImage {
        let key = item.path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let img = NSWorkspace.shared.icon(forFile: item.path)
        img.size = NSSize(width: 26, height: 26)
        iconCache.setObject(img, forKey: key)
        return img
    }
}

/// 让表格把点击事件交给行内的录制控件
final class LauncherTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is ShortcutRecorderView { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

final class RecorderCell: NSTableCellView {
    let recorder = ShortcutRecorderView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        recorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recorder)
        NSLayoutConstraint.activate([
            recorder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            recorder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            recorder.centerYAnchor.constraint(equalTo: centerYAnchor),
            recorder.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
