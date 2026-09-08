import AppKit

/// 轮询 NSPasteboard.changeCount，发现新内容后回调。macOS 没有剪贴板变更通知，轮询是标准做法。
final class ClipboardMonitor {
    var onText: ((String) -> Void)?
    /// png 数据、缩略图 png、像素宽、像素高
    var onImage: ((Data, Data?, Int, Int) -> Void)?

    /// 单张图片原始数据上限，超过则不记录，避免内存暴涨。
    var maxImageBytes = 30 * 1024 * 1024
    /// 单条文本上限（UTF-8 字节），超过则不记录，避免超大文本拖慢搜索。
    var maxTextBytes = 1 * 1024 * 1024
    var thumbMaxPixels = 96

    private var timer: Timer?
    private var lastChangeCount: Int
    private let pasteboard = NSPasteboard.general
    private let workQueue = DispatchQueue(label: "paste.image", qos: .utility)

    private static let ignoredTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),   // 密码管理器
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword"),
    ]

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 自己写入剪贴板后调用，避免把刚粘贴的内容再处理一遍。
    func ignoreCurrentChange() {
        lastChangeCount = pasteboard.changeCount
    }

    private func check() {
        let change = pasteboard.changeCount
        guard change != lastChangeCount else { return }
        lastChangeCount = change

        guard let types = pasteboard.types, !types.isEmpty else { return }
        if types.contains(where: { ClipboardMonitor.ignoredTypes.contains($0) }) { return }
        // 在 Finder 里复制文件时剪贴板会附带文件名文本，这类内容不记录
        if types.contains(.fileURL) { return }

        if types.contains(.string), let s = pasteboard.string(forType: .string) {
            guard s.utf8.count <= maxTextBytes else { return }
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onText?(s)
            }
            return
        }

        if types.contains(.png) || types.contains(.tiff) {
            let isPNG = types.contains(.png)
            guard let raw = pasteboard.data(forType: isPNG ? .png : .tiff) else { return }
            guard raw.count <= maxImageBytes else { return }
            let thumbMax = thumbMaxPixels
            workQueue.async { [weak self] in
                guard let rep = NSBitmapImageRep(data: raw), let cg = rep.cgImage else { return }
                let w = cg.width, h = cg.height
                guard w > 0, h > 0 else { return }
                let png: Data?
                if isPNG {
                    png = raw
                } else {
                    png = rep.representation(using: .png, properties: [:])
                }
                guard let pngData = png else { return }
                let thumb = ClipboardMonitor.thumbnail(from: cg, maxPixels: thumbMax)
                DispatchQueue.main.async {
                    self?.onImage?(pngData, thumb, w, h)
                }
            }
        }
    }

    static func thumbnail(from cg: CGImage, maxPixels: Int) -> Data? {
        let w = cg.width, h = cg.height
        let scale = min(1.0, Double(maxPixels) / Double(max(w, h)))
        let tw = max(1, Int(Double(w) * scale))
        let th = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}
