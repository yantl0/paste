// 生成应用图标：swift scripts/make_icon.swift <输出目录>
// 输出 icon_1024.png 与 AppIcon.icns
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let S: CGFloat = 1024
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// 翻转坐标系，改成左上角为原点，便于按设计稿坐标画
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// 1. macOS 风格圆角方形底板（含边距）
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = roundedPath(plate, 186)

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
// 主渐变：靛蓝 → 深紫，左上亮右下暗
let grad = CGGradient(colorsSpace: cs,
                      colors: [rgb(0x6E7BFF), rgb(0x4B4BE0), rgb(0x2E2A9E)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
// 左上角柔光
let glow = CGGradient(colorsSpace: cs,
                      colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 260), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 260), endRadius: 520, options: [])
ctx.restoreGState()

// 底板内侧 1px 高光描边，增加质感
ctx.saveGState()
ctx.addPath(roundedPath(plate.insetBy(dx: 2, dy: 2), 184))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// 2. 剪贴板主体（白色卡片，带投影）
let board = CGRect(x: 302, y: 268, width: 420, height: 520)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: rgb(0x14124A, 0.42))
ctx.addPath(roundedPath(board, 60))
ctx.setFillColor(rgb(0xF8F8FC))
ctx.fillPath()
ctx.restoreGState()

// 卡片顶部微弱渐变，避免死白
ctx.saveGState()
ctx.addPath(roundedPath(board, 60))
ctx.clip()
let cardGrad = CGGradient(colorsSpace: cs,
                          colors: [rgb(0xFFFFFF), rgb(0xEEEFF7)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(cardGrad, start: CGPoint(x: 0, y: board.minY), end: CGPoint(x: 0, y: board.maxY), options: [])
ctx.restoreGState()

// 3. 顶部夹子（深色，压在卡片上沿）
let clip = CGRect(x: 412, y: 226, width: 200, height: 96)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x14124A, 0.35))
ctx.addPath(roundedPath(clip, 34))
ctx.setFillColor(rgb(0x1E1B5C))
ctx.fillPath()
ctx.restoreGState()
// 夹子上的小开口
ctx.addPath(roundedPath(CGRect(x: 476, y: 250, width: 72, height: 22), 11))
ctx.setFillColor(rgb(0x6E7BFF, 0.9))
ctx.fillPath()

// 4. 三条记录线：第一条为高亮的「当前选中」记录
let lineX: CGFloat = board.minX + 66
let lineH: CGFloat = 40
let lines: [(y: CGFloat, w: CGFloat, color: CGColor)] = [
    (y: 402, w: 288, color: rgb(0x5B67F2)),
    (y: 490, w: 214, color: rgb(0xCBCDE0)),
    (y: 578, w: 254, color: rgb(0xCBCDE0)),
    (y: 666, w: 160, color: rgb(0xCBCDE0)),
]
for (i, l) in lines.enumerated() {
    if i == 0 {
        // 选中态：淡色底 + 实色线
        ctx.addPath(roundedPath(CGRect(x: board.minX + 40, y: l.y - 24, width: board.width - 80, height: lineH + 48), 26))
        ctx.setFillColor(rgb(0x5B67F2, 0.12))
        ctx.fillPath()
    }
    ctx.addPath(roundedPath(CGRect(x: lineX, y: l.y, width: l.w, height: lineH), lineH / 2))
    ctx.setFillColor(l.color)
    ctx.fillPath()
}

// 输出 1024 PNG
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
let pngPath = "\(outDir)/icon_1024.png"
try! png.write(to: URL(fileURLWithPath: pngPath))
print("wrote \(pngPath)")
