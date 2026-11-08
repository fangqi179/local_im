// 绘制 LanChat 应用图标，输出 iconset 目录供 iconutil 打包。
// 用法：swift scripts/make-icon.swift <输出目录.iconset> [预览.png]
//
// 设计：青蓝渐变的圆角方形底；白色对话气泡，气泡里三个相连的节点
// （既像"正在输入"的三个点，也是局域网里互相连接的设备）；
// 右上角两道弧线表示 Bonjour 广播发现。小尺寸下省略弧线。
import AppKit

// 以 1024 为设计画布，坐标原点在左上角
func drawIcon(in ctx: CGContext, px: Int) {
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    let small = px <= 64
    let cs = CGColorSpaceCreateDeviceRGB()
    func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    // 1. 底板：macOS 图标网格 824×824，连续圆角
    let base = CGRect(x: 100, y: 100, width: 824, height: 824)
    let basePath = NSBezierPath(roundedRect: base, xRadius: 185, yRadius: 185).cgPathCompat
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.30))
    ctx.addPath(basePath); ctx.setFillColor(rgb(0x1E7BE6)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(basePath); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2FD8C4), rgb(0x1E8CEB), rgb(0x2B4FD8)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 180, y: 100), end: CGPoint(x: 844, y: 924), options: [])
    // 顶部柔光
    let gloss = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 520), options: [])
    ctx.restoreGState()

    // 2. 广播弧线（右上角）
    if !small {
        let center = CGPoint(x: 700, y: 330)
        ctx.saveGState()
        ctx.addPath(basePath); ctx.clip()
        ctx.setLineCap(.round)
        for (r, a) in [(115.0, 0.9), (195.0, 0.55)] {
            ctx.setStrokeColor(rgb(0xFFFFFF, a))
            ctx.setLineWidth(36)
            ctx.addArc(center: center, radius: r, startAngle: -.pi * 0.44, endAngle: -.pi * 0.06, clockwise: false)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // 3. 对话气泡
    let body = small ? CGRect(x: 190, y: 290, width: 644, height: 420)
                     : CGRect(x: 190, y: 360, width: 600, height: 390)
    // 左下角的小尾巴，与气泡主体取并集
    let tail = CGMutablePath()
    let tx = body.minX + body.height * 0.32, ty = body.maxY - 60
    tail.move(to: CGPoint(x: tx - 30, y: ty))
    tail.addQuadCurve(to: CGPoint(x: tx - 80, y: body.maxY + 100), control: CGPoint(x: tx - 20, y: body.maxY + 60))
    tail.addQuadCurve(to: CGPoint(x: tx + 140, y: ty), control: CGPoint(x: tx + 50, y: body.maxY + 70))
    tail.closeSubpath()
    let bubble = NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2).cgPathCompat
        .union(tail)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: rgb(0x0B2E7A, 0.35))
    ctx.addPath(bubble); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bubble); ctx.clip()
    let paper = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xE3F0FF)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY + 110), options: [])
    ctx.restoreGState()

    // 4. 气泡内三个相连的节点
    let cy = body.midY
    let gap = body.width * 0.24
    let nodes = [-1.0, 0, 1].map { CGPoint(x: body.midX + gap * $0, y: cy) }
    let r: CGFloat = small ? 62 : 50
    let ink = CGGradient(colorsSpace: cs, colors: [rgb(0x22C3C0), rgb(0x2B5EDB)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    let links = CGMutablePath()
    links.move(to: nodes[0]); links.addLine(to: nodes[2])
    var mark: CGPath = links.copy(strokingWithWidth: small ? 30 : 24, lineCap: .round, lineJoin: .round, miterLimit: 1)
    for n in nodes { mark = mark.union(CGPath(ellipseIn: CGRect(x: n.x - r, y: n.y - r, width: r * 2, height: r * 2), transform: nil)) }
    ctx.addPath(mark); ctx.clip()
    ctx.drawLinearGradient(ink, start: CGPoint(x: nodes[0].x - r, y: cy), end: CGPoint(x: nodes[2].x + r, y: cy), options: [])
    ctx.restoreGState()
}

extension NSBezierPath {
    var cgPathCompat: CGPath {
        let path = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo: path.move(to: pts[0])
            case .lineTo: path.addLine(to: pts[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo: path.addQuadCurve(to: pts[1], control: pts[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, px: px)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
