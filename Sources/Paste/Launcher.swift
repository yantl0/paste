import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let launchersDidChange = Notification.Name("PasteLaunchersDidChange")
}

/// 一条「应用 + 快捷键」记录。字段名与 Thor 导出格式完全一致，可以互相导入导出。
struct LauncherItem: Codable, Equatable {
    var appBundleIdentifier: String
    var appBundleURL: String
    var appDisplayName: String
    var shortcut: String
    var appIconData: String?

    var url: URL? { URL(string: appBundleURL) }
    /// 标准化后的路径，用来判断是否是同一个应用
    var path: String { url?.standardizedFileURL.path ?? appBundleURL }
    var shortcutValue: Shortcut? { shortcut.isEmpty ? nil : Shortcut(thorString: shortcut) }
    var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    init?(appURL: URL) {
        guard let bundle = Bundle(url: appURL) else { return nil }
        appBundleIdentifier = bundle.bundleIdentifier ?? ""
        appBundleURL = appURL.standardizedFileURL.absoluteString
        var name = FileManager.default.displayName(atPath: appURL.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        appDisplayName = name
        shortcut = ""
    }

    private enum CodingKeys: String, CodingKey {
        case appBundleIdentifier, appBundleURL, appDisplayName, shortcut, appIconData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appBundleURL = try c.decode(String.self, forKey: .appBundleURL)
        appDisplayName = try c.decodeIfPresent(String.self, forKey: .appDisplayName) ?? ""
        appBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .appBundleIdentifier) ?? ""
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut) ?? ""
        appIconData = try c.decodeIfPresent(String.self, forKey: .appIconData)
    }
}

struct ImportReport {
    var added = 0
    var updated = 0
    var missing: [String] = []
    var conflicts: [String] = []
    var invalid: [String] = []

    var summary: String {
        var lines = ["新增 \(added) 个，更新 \(updated) 个。"]
        if !missing.isEmpty { lines.append("应用不存在，已跳过：" + missing.joined(separator: "、")) }
        if !conflicts.isEmpty { lines.append("快捷键冲突，已跳过：\n" + conflicts.joined(separator: "\n")) }
        if !invalid.isEmpty { lines.append("快捷键无法识别，已跳过：" + invalid.joined(separator: "、")) }
        return lines.joined(separator: "\n")
    }
}

/// 管理应用快捷启动列表和剪贴板面板快捷键，负责持久化与热键注册。
final class LauncherManager {
    private(set) var items: [LauncherItem] = []
    private(set) var panelShortcut: Shortcut
    var onPanelHotKey: (() -> Void)?

    private var registrations: [String: UInt32] = [:]   // path -> hotkey id
    private var panelRegistration: UInt32?
    private let fileURL: URL
    private let hotKeys = HotKeyCenter.shared

    private static let panelDefaultsKey = "panelShortcut"
    static let defaultPanelShortcut = Shortcut(keyCode: kVK_ANSI_X, modifiers: .option)

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("launchers.json")
        if let s = UserDefaults.standard.string(forKey: LauncherManager.panelDefaultsKey),
           let sc = Shortcut(thorString: s) {
            panelShortcut = sc
        } else {
            panelShortcut = LauncherManager.defaultPanelShortcut
        }
        load()
    }

    /// 注册全部热键。返回注册失败的描述列表（空表示全部成功）。
    @discardableResult
    func start() -> [String] {
        var failures: [String] = []
        if !registerPanel() { failures.append("剪贴板面板 \(panelShortcut.display)") }
        for item in items where item.shortcutValue != nil {
            if !registerItem(item) { failures.append("\(item.appDisplayName) \(item.shortcutValue!.display)") }
        }
        return failures
    }

    // MARK: - 冲突检查

    /// 返回 nil 表示可用，否则是拒绝原因。
    func conflict(for shortcut: Shortcut, ignoringPath: String? = nil, ignoringPanel: Bool = false) -> String? {
        if let s = shortcut.thorString, Shortcut.systemReserved.contains(s) {
            return "\(shortcut.display) 是系统保留的快捷键"
        }
        if !ignoringPanel, shortcut == panelShortcut {
            return "\(shortcut.display) 已被「剪贴板面板」使用"
        }
        for item in items where item.path != ignoringPath && item.shortcutValue == shortcut {
            return "\(shortcut.display) 已被「\(item.appDisplayName)」使用"
        }
        return nil
    }

    // MARK: - 修改

    /// 返回 nil 表示成功，否则是错误信息。
    func setShortcut(_ shortcut: Shortcut?, forItemAt index: Int) -> String? {
        guard items.indices.contains(index) else { return nil }
        if let s = shortcut, let reason = conflict(for: s, ignoringPath: items[index].path) { return reason }
        let old = items[index].shortcut
        items[index].shortcut = shortcut?.thorString ?? ""
        if !registerItem(items[index]) {
            items[index].shortcut = old
            registerItem(items[index])
            return "\(shortcut!.display) 已被系统或其他应用占用，无法注册"
        }
        save()
        return nil
    }

    func setPanelShortcut(_ shortcut: Shortcut) -> String? {
        if let reason = conflict(for: shortcut, ignoringPanel: true) { return reason }
        let old = panelShortcut
        panelShortcut = shortcut
        if !registerPanel() {
            panelShortcut = old
            registerPanel()
            return "\(shortcut.display) 已被系统或其他应用占用，无法注册"
        }
        UserDefaults.standard.set(shortcut.thorString, forKey: LauncherManager.panelDefaultsKey)
        notify()
        return nil
    }

    /// 添加应用（未设置快捷键），已存在的跳过。返回新增的下标。
    func addApps(_ urls: [URL]) -> [Int] {
        var added: [Int] = []
        for url in urls {
            guard let item = LauncherItem(appURL: url) else { continue }
            if items.contains(where: { $0.path == item.path }) { continue }
            items.append(item)
            added.append(items.count - 1)
        }
        if !added.isEmpty { save() }
        return added
    }

    func remove(at indexes: IndexSet) {
        for i in indexes.sorted(by: >) where items.indices.contains(i) {
            unregisterItem(items[i])
            items.remove(at: i)
        }
        save()
    }

    // MARK: - 导入 / 导出（Thor 兼容格式）

    func importItems(from url: URL) throws -> ImportReport {
        let data = try Data(contentsOf: url)
        let incoming = try JSONDecoder().decode([LauncherItem].self, from: data)
        var report = ImportReport()

        for var item in incoming {
            item.appIconData = nil
            let name = item.appDisplayName.isEmpty ? item.path : item.appDisplayName
            guard let appURL = item.url, item.exists, let bundle = Bundle(url: appURL) else {
                report.missing.append(name)
                continue
            }
            if item.appBundleIdentifier.isEmpty { item.appBundleIdentifier = bundle.bundleIdentifier ?? "" }
            if item.appDisplayName.isEmpty, let fresh = LauncherItem(appURL: appURL) { item.appDisplayName = fresh.appDisplayName }

            var shortcut: Shortcut?
            if !item.shortcut.isEmpty {
                guard let s = Shortcut(thorString: item.shortcut), s.hasUsableModifier else {
                    report.invalid.append("\(name)（\(item.shortcut)）")
                    continue
                }
                if let reason = conflict(for: s, ignoringPath: item.path) {
                    report.conflicts.append("\(name)：\(reason)")
                    continue
                }
                shortcut = s
            }

            if let idx = items.firstIndex(where: { $0.path == item.path }) {
                unregisterItem(items[idx])
                items[idx] = item
                report.updated += 1
            } else {
                items.append(item)
                report.added += 1
            }
            if shortcut != nil, !registerItem(item) {
                report.conflicts.append("\(name)：\(shortcut!.display) 已被系统或其他应用占用")
                if let idx = items.firstIndex(where: { $0.path == item.path }) { items[idx].shortcut = "" }
            }
        }
        save()
        return report
    }

    func export(to url: URL) throws {
        var out = items
        for i in out.indices {
            out[i].appIconData = LauncherManager.iconPNGBase64(forAppAt: out[i].path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(out).write(to: url, options: .atomic)
    }

    // MARK: - 触发

    /// 目标应用已在前台则隐藏它，否则启动 / 切换到它。
    func trigger(_ item: LauncherItem) {
        guard let url = item.url else { return }
        if !item.appBundleIdentifier.isEmpty,
           let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier == item.appBundleIdentifier {
            front.hide()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error = error { NSLog("启动 %@ 失败: %@", item.appDisplayName, error.localizedDescription) }
        }
    }

    // MARK: - 内部

    @discardableResult
    private func registerItem(_ item: LauncherItem) -> Bool {
        unregisterItem(item)
        guard let shortcut = item.shortcutValue else { return true }
        let path = item.path
        guard let id = hotKeys.register(shortcut, action: { [weak self] in
            guard let self = self, let current = self.items.first(where: { $0.path == path }) else { return }
            self.trigger(current)
        }) else { return false }
        registrations[path] = id
        return true
    }

    private func unregisterItem(_ item: LauncherItem) {
        if let id = registrations.removeValue(forKey: item.path) { hotKeys.unregister(id) }
    }

    @discardableResult
    private func registerPanel() -> Bool {
        if let id = panelRegistration { hotKeys.unregister(id); panelRegistration = nil }
        guard let id = hotKeys.register(panelShortcut, action: { [weak self] in self?.onPanelHotKey?() }) else { return false }
        panelRegistration = id
        return true
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LauncherItem].self, from: data) else { return }
        items = decoded.map { var i = $0; i.appIconData = nil; return i }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .launchersDidChange, object: self)
    }

    /// 导出时附带 72×72 的 PNG 图标，和 Thor 一致
    private static func iconPNGBase64(forAppAt path: String) -> String? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let side = 72
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])?.base64EncodedString()
    }
}
