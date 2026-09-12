import AppKit

/// 设置窗口里的「鼠标映射」标签页
final class MouseMappingPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let mapper: MouseMapper
    private let tableView = LauncherTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "打开系统设置…", target: nil, action: nil)
    private let enabledCheckbox = NSButton(checkboxWithTitle: "启用鼠标按键映射", target: nil, action: nil)
    private let swallowCheckbox = NSButton(checkboxWithTitle: "拦截原始鼠标点击（推荐，避免浏览器同时触发「后退」等默认动作）", target: nil, action: nil)
    private let removeButton = NSButton()
    private var learnSheet: NSWindow?

    init(mapper: MouseMapper) {
        self.mapper = mapper
        super.init(frame: .zero)
        build()
        mapper.onStateChanged = { [weak self] in self?.refreshStatus() }
        NotificationCenter.default.addObserver(self, selector: #selector(mappingsChanged), name: .mouseMappingsDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        tableView.reloadData()
        refreshStatus()
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    @objc private func mappingsChanged() { refresh() }

    private func refreshStatus() {
        enabledCheckbox.state = mapper.isEnabled ? .on : .off
        swallowCheckbox.state = mapper.swallowClicks ? .on : .off
        swallowCheckbox.isEnabled = mapper.isEnabled

        let trusted = Paster.isAccessibilityTrusted()
        permissionButton.isHidden = trusted
        if !trusted {
            statusLabel.stringValue = "⚠️ 未授予辅助功能权限，鼠标映射不会生效。"
            statusLabel.textColor = .systemOrange
        } else if !mapper.isEnabled {
            statusLabel.stringValue = "已停用。"
            statusLabel.textColor = .secondaryLabelColor
        } else if mapper.isTapActive {
            statusLabel.stringValue = "✓ 正在监听鼠标按键。"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "添加映射并录制快捷键后开始监听。"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - UI

    private func build() {
        let title = label("鼠标按键映射", size: 13, weight: .semibold)
        let desc = label("把鼠标的中键、侧键等额外按键映射为键盘快捷键，例如侧键 → ⌃⇥ 切换标签页。左键和右键不可映射。", size: 11, color: .secondaryLabelColor)
        desc.lineBreakMode = .byWordWrapping
        desc.maximumNumberOfLines = 3

        statusLabel.font = .systemFont(ofSize: 11)
        permissionButton.target = self
        permissionButton.action = #selector(openPermission)
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionButton.font = .systemFont(ofSize: 11)
        let statusRow = NSStackView(views: [statusLabel, permissionButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(toggleEnabled)
        swallowCheckbox.target = self
        swallowCheckbox.action = #selector(toggleSwallow)
        swallowCheckbox.font = .systemFont(ofSize: 12)
        swallowCheckbox.lineBreakMode = .byWordWrapping

        let buttonColumn = NSTableColumn(identifier: .init("button"))
        buttonColumn.title = "鼠标按键"
        buttonColumn.width = 330
        buttonColumn.minWidth = 200
        let keyColumn = NSTableColumn(identifier: .init("shortcut"))
        keyColumn.title = "映射为"
        keyColumn.width = 170
        keyColumn.minWidth = 150
        tableView.addTableColumn(buttonColumn)
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

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "添加")!, target: self, action: #selector(learnButton))
        addButton.bezelStyle = .smallSquare
        addButton.toolTip = "添加映射：按下要映射的鼠标按键"
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "删除")
        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.isEnabled = false
        for b in [addButton, removeButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let hint = label("点「+」后按下鼠标按键，再点击右侧录制快捷键", size: 11, color: .tertiaryLabelColor)
        let buttons = NSStackView(views: [addButton, removeButton, hint])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let root = NSStackView(views: [title, desc, statusRow, enabledCheckbox, swallowCheckbox, scroll, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        root.setCustomSpacing(4, after: title)
        root.setCustomSpacing(12, after: desc)
        root.setCustomSpacing(12, after: statusRow)
        root.setCustomSpacing(12, after: swallowCheckbox)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            desc.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            swallowCheckbox.widthAnchor.constraint(equalTo: desc.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: desc.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: desc.widthAnchor),
        ])
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    // MARK: - 动作

    @objc private func openPermission() {
        Paster.requestAccessibility()
        Paster.openAccessibilitySettings()
    }

    @objc private func toggleEnabled() {
        mapper.isEnabled = enabledCheckbox.state == .on
    }

    @objc private func toggleSwallow() {
        mapper.swallowClicks = swallowCheckbox.state == .on
    }

    /// 学习模式：弹出提示，等待用户按下鼠标额外按键
    @objc private func learnButton() {
        guard let window = window else { return }
        guard Paster.isAccessibilityTrusted() else {
            let a = NSAlert()
            a.messageText = "需要辅助功能权限"
            a.informativeText = "拦截鼠标按键需要辅助功能权限。请在 系统设置 › 隐私与安全性 › 辅助功能 中勾选 Paste，然后再试。"
            a.addButton(withTitle: "打开系统设置")
            a.addButton(withTitle: "取消")
            a.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { Paster.openAccessibilitySettings() } }
            return
        }

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        let text = NSTextField(labelWithString: "请按下要映射的鼠标按键…\n（中键、侧键等；左键和右键无法映射）")
        text.alignment = .center
        text.font = .systemFont(ofSize: 13)
        text.maximumNumberOfLines = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelLearn))
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView?.addSubview(text)
        sheet.contentView?.addSubview(cancel)
        if let c = sheet.contentView {
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: c.topAnchor, constant: 24),
                text.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 20),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -20),
                cancel.centerXAnchor.constraint(equalTo: c.centerXAnchor),
                cancel.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -16),
            ])
        }
        learnSheet = sheet
        window.beginSheet(sheet)

        mapper.learnHandler = { [weak self] button in
            guard let self = self else { return }
            self.endLearnSheet()
            if let idx = self.mapper.addMapping(button: button) {
                self.tableView.reloadData()
                self.tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                self.tableView.scrollRowToVisible(idx)
                // 直接进入快捷键录制
                DispatchQueue.main.async {
                    if let cell = self.tableView.view(atColumn: 1, row: idx, makeIfNecessary: true) as? RecorderCell {
                        self.window?.makeFirstResponder(cell.recorder)
                    }
                }
            } else {
                let a = NSAlert()
                a.messageText = "该鼠标按键已有映射"
                a.informativeText = "\(MouseMapping.buttonName(button)) · 编号 \(button) 已在列表中，直接修改它的快捷键即可。"
                if let w = self.window { a.beginSheetModal(for: w) }
            }
        }
    }

    @objc private func cancelLearn() {
        mapper.learnHandler = nil
        endLearnSheet()
    }

    private func endLearnSheet() {
        if let s = learnSheet {
            window?.endSheet(s)
            learnSheet = nil
        }
    }

    @objc private func removeSelected() {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        mapper.remove(at: rows)
        tableView.reloadData()
        removeButton.isEnabled = false
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { mapper.mappings.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let mapping = mapper.mappings[row]
        guard let column = tableColumn else { return nil }

        if column.identifier.rawValue == "button" {
            let id = NSUserInterfaceItemIdentifier("ButtonCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)
                iv.symbolConfiguration = .init(pointSize: 16, weight: .regular)
                iv.contentTintColor = .secondaryLabelColor
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(iv)
                c.addSubview(tf)
                c.imageView = iv
                c.textField = tf
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 22),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 10),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = "\(MouseMapping.buttonName(mapping.button))  ·  编号 \(mapping.button)"
            return cell
        }

        let id = NSUserInterfaceItemIdentifier("MouseKeyCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? RecorderCell) ?? {
            let c = RecorderCell()
            c.identifier = id
            c.recorder.requiresModifier = false
            c.recorder.placeholder = "点击录制快捷键"
            return c
        }()
        cell.recorder.shortcut = mapping.shortcutValue
        cell.recorder.validator = nil
        cell.recorder.onChange = { [weak self, weak cell] s in
            guard let self = self, let cell = cell else { return }
            let r = self.tableView.row(for: cell)
            guard r >= 0 else { return }
            self.mapper.setShortcut(s, at: r)
        }
        cell.recorder.onRecordingChanged = { rec in rec ? HotKeyCenter.shared.suspendAll() : HotKeyCenter.shared.resumeAll() }
        return cell
    }
}
