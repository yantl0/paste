import AppKit

/// 无边框、非激活式面板：可以接收键盘输入，但不会把我们的 App 切到前台，
/// 这样关闭后焦点仍停留在原来的输入框，模拟 Cmd+V 就能粘进去。
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let store: Store
    private let panel: KeyPanel
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "暂无记录")
    private let footerLabel = NSTextField(labelWithString: "")

    private var items: [ClipItem] = []
    private var previousApp: NSRunningApplication?
    private var searchDebounce: DispatchWorkItem?
    private var didPromptAccessibility = false
    private let thumbCache = NSCache<NSNumber, NSImage>()

    /// 面板一次最多加载多少条，避免把 2000 条全部读进内存。
    private let pageSize = 200
    private let panelSize = NSSize(width: 580, height: 440)

    /// 写入剪贴板后通知外部（用于让监视器忽略这次变更）。
    var onDidWritePasteboard: (() -> Void)?

    init(store: Store) {
        self.store = store
        panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        thumbCache.countLimit = 60
        setupPanel()
        setupViews()
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - 显示 / 隐藏

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front?.processIdentifier == ProcessInfo.processInfo.processIdentifier) ? nil : front

        searchField.stringValue = ""
        reload(query: nil)
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        selectRow(0)
    }

    func hide() {
        // orderOut 会触发 didResignKey → 再次进入 hide，这里挡掉重入
        guard panel.isVisible else { return }
        searchDebounce?.cancel()
        panel.orderOut(nil)
        items = []
        thumbCache.removeAllObjects()
        tableView.reloadData()
    }

    /// 剪贴板有新内容且面板可见时刷新列表。
    func refreshIfVisible() {
        guard panel.isVisible else { return }
        reload(query: searchField.stringValue)
    }

    // MARK: - 数据

    private func reload(query: String?) {
        items = store.fetch(query: query, limit: pageSize)
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        let total = store.count()
        let shown = items.count
        let countText = (query?.isEmpty ?? true) ? "共 \(total) 条" : "匹配 \(shown) 条"
        footerLabel.stringValue = "↑↓ 选择   ⏎ 粘贴   ⌘⌫ 删除   Esc 关闭      \(countText)"
        selectRow(0)
    }

    private func selectRow(_ row: Int) {
        guard !items.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        let r = max(0, min(row, items.count - 1))
        tableView.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        tableView.scrollRowToVisible(r)
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = tableView.selectedRow
        let next = current < 0 ? 0 : current + delta
        selectRow(next)
    }

    private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        store.delete(id: items[row].id)
        thumbCache.removeObject(forKey: NSNumber(value: items[row].id))
        reload(query: searchField.stringValue)
        selectRow(row)
    }

    // MARK: - 粘贴

    private func pasteSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        paste(items[row])
    }

    private func paste(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            guard let text = store.fullText(id: item.id) else { return }
            pb.setString(text, forType: .string)
        case .image:
            guard let data = store.imageData(id: item.id) else { return }
            pb.setData(data, forType: .png)
            // 同时写一份 TIFF，兼容只认 TIFF 的老应用
            if let img = NSImage(data: data), let tiff = img.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        }
        onDidWritePasteboard?()
        store.touch(id: item.id)

        let target = previousApp
        hide()

        guard Paster.isAccessibilityTrusted() else {
            // 没有辅助功能权限就只复制，不模拟按键；系统授权提示每次启动只弹一次
            if !didPromptAccessibility {
                didPromptAccessibility = true
                Paster.requestAccessibility()
            }
            return
        }
        if let target = target, !target.isActive {
            if #available(macOS 14.0, *) {
                target.activate()
            } else {
                target.activate(options: [.activateIgnoringOtherApps])
            }
        }
        // 给目标应用一点时间恢复焦点
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Paster.sendCommandV()
        }
    }

    // MARK: - UI 搭建

    private func setupPanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onCancel = { [weak self] in self?.hide() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResignKey),
            name: NSWindow.didResignKeyNotification, object: panel
        )
    }

    @objc private func panelDidResignKey() {
        hide()
    }

    private func setupViews() {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect

        // 搜索框
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 18, weight: .regular)
        searchField.placeholderString = "搜索剪贴板记录…"
        searchField.delegate = self
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator

        // 列表
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 50
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked)
        tableView.refusesFirstResponder = true
        if #available(macOS 11.0, *) { tableView.style = .fullWidth }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let footerDivider = NSBox()
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        footerDivider.boxType = .separator

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail

        [icon, searchField, divider, scrollView, emptyLabel, footerDivider, footerLabel].forEach { effect.addSubview($0) }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),

            searchField.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -6),

            footerLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            footerLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            footerLabel.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
        ])
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - panelSize.width / 2
        let y = frame.midY - panelSize.height / 2 + frame.height * 0.1
        panel.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: false)
    }

    @objc private func tableClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        paste(items[row])
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        searchDebounce?.cancel()
        let text = searchField.stringValue
        let work = DispatchWorkItem { [weak self] in self?.reload(query: text) }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.insertNewline(_:)):
            pasteSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            deleteSelected(); return true
        default:
            return false
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ItemCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ItemCell) ?? {
            let c = ItemCell()
            c.identifier = id
            return c
        }()
        let item = items[row]
        cell.configure(item: item, thumb: item.kind == .image ? thumbImage(for: item) : nil)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("Row")
        if let v = tableView.makeView(withIdentifier: id, owner: nil) as? RoundedRowView { return v }
        let v = RoundedRowView()
        v.identifier = id
        return v
    }

    private func thumbImage(for item: ClipItem) -> NSImage? {
        let key = NSNumber(value: item.id)
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let data = store.thumb(id: item.id), let img = NSImage(data: data) else { return nil }
        thumbCache.setObject(img, forKey: key)
        return img
    }
}

// MARK: - 行视图

final class RoundedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 8, dy: 2)
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

final class ItemCell: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        f.dateTimeStyle = .numeric
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.layer?.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(item: ClipItem, thumb: NSImage?) {
        titleLabel.stringValue = item.preview.isEmpty ? " " : item.preview
        let time = ItemCell.timeText(item.createdAt)
        switch item.kind {
        case .text:
            iconView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            iconView.symbolConfiguration = .init(pointSize: 18, weight: .regular)
            iconView.contentTintColor = .secondaryLabelColor
            subtitleLabel.stringValue = "\(item.charCount) 字符 · \(time)"
        case .image:
            iconView.symbolConfiguration = nil
            iconView.image = thumb ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            subtitleLabel.stringValue = "图片 \(item.width)×\(item.height) · \(time)"
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            titleLabel.textColor = emphasized ? .white : .labelColor
            subtitleLabel.textColor = emphasized ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
            if iconView.symbolConfiguration != nil {
                iconView.contentTintColor = emphasized ? .white : .secondaryLabelColor
            }
        }
    }

    private static func timeText(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
