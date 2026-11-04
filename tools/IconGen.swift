import AppKit
import CoreGraphics

// MARK: - 从原图测出的几何（单位：原图像素）
//
// 两个图标是同一套母题：一个横向胶囊 + 下方一个下垂箭头。
// 左侧（菜单栏）与右侧（app）是两份独立绘制，比例并不相同，分别保留。

struct GlyphSpec {
    var capsuleW: CGFloat
    var capsuleH: CGFloat
    var gap: CGFloat
    var chevW: CGFloat
    var chevH: CGFloat
    /// 箭头中心相对胶囊中心的水平偏移（原图实测；非 0 表示原设计本身就不对称）
    var chevDx: CGFloat
    /// 箭头区域在原图中的纵向起点（用于描摹）
    var chevSrcY0: Int

    var totalH: CGFloat { capsuleH + gap + chevH }

    /// 以胶囊宽度为基准的整体缩放
    var outerW: CGFloat { max(capsuleW, chevW) }
}

let menuSpec = GlyphSpec(
    capsuleW: 565, capsuleH: 165, gap: 38, chevW: 152, chevH: 85, chevDx: 1.5, chevSrcY0: 547
)
// app 图标：原图里箭头中心比胶囊中心偏右约 16.5px，这里如实保留
let appSpec = GlyphSpec(
    capsuleW: 455, capsuleH: 160, gap: 32, chevW: 157, chevH: 89, chevDx: 16.5, chevSrcY0: 536
)

// 原图中各元素的绝对位置
struct SourceFrame {
    var x0: Int, x1: Int
    var capsuleY0: Int, capsuleY1: Int
    var chevY0: Int, chevY1: Int
}
let menuFrame = SourceFrame(x0: 216, x1: 780, capsuleY0: 344, capsuleY1: 508, chevY0: 547, chevY1: 631)
let appFrame = SourceFrame(x0: 1131, x1: 1585, capsuleY0: 344, capsuleY1: 503, chevY0: 536, chevY1: 624)

// app 图标底板：按边框中心实测（原图里这圈约 1px 的深色描边就是图标边界）
// 注意原图中它是 647.5 宽 × 626 高，并非正方形；
// 系统 app 图标必须是正方形，所以按宽度定标、纵向按比例放，不做非等比拉伸。
let tileSrcX0: CGFloat = 1034.5, tileSrcX1: CGFloat = 1682.0
let tileSrcY0: CGFloat = 145.0, tileSrcY1: CGFloat = 771.0
let tileSrcW: CGFloat = tileSrcX1 - tileSrcX0     // 647.5
let tileSrcH: CGFloat = tileSrcY1 - tileSrcY0     // 626
let tileCornerRatio: CGFloat = 161.0 / 647.5      // 由角部轮廓拟合

// 颜色（实测）
let glyphColor = NSColor(srgbRed: 20/255.0, green: 20/255.0, blue: 20/255.0, alpha: 1)
let tileTop = NSColor(srgbRed: 250/255.0, green: 250/255.0, blue: 250/255.0, alpha: 1)
let tileBottom = NSColor(srgbRed: 228/255.0, green: 227/255.0, blue: 231/255.0, alpha: 1)

// MARK: - 载入原图

let srcPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/Users/xingbeichen/.workbuddy/clipboard-images/clipboard-2026-11-03T12-47-11-617Z-a2459339.jpg"

guard let srcImage = NSImage(contentsOfFile: srcPath),
      let srcRep = NSBitmapImageRep(data: srcImage.tiffRepresentation!) else {
    print("无法读取源图"); exit(1)
}
let SW = srcRep.pixelsWide, SH = srcRep.pixelsHigh

/// 取亮度（0=黑, 1=白）
func lum(_ x: Int, _ y: Int) -> Double {
    guard let c = srcRep.colorAt(x: min(max(x, 0), SW - 1), y: min(max(y, 0), SH - 1)) else { return 1 }
    return (c.redComponent + c.greenComponent + c.blueComponent) / 3
}

// MARK: - 箭头描摹

/// 逐行求左右边缘（0.5 阈值 + 线性亚像素插值），返回相对 (x0,y0) 的坐标
func traceRows(x0: Int, x1: Int, y0: Int, y1: Int) -> ([(CGFloat, CGFloat)], [(CGFloat, CGFloat)]) {
    var lefts: [(CGFloat, CGFloat)] = []
    var rights: [(CGFloat, CGFloat)] = []

    for y in y0...y1 {
        // 从左往右找第一个"暗"的亚像素位置
        var l: CGFloat? = nil
        var r: CGFloat? = nil
        var prev = lum(x0 - 2, y)
        for x in x0...x1 {
            let cur = lum(x, y)
            if l == nil, prev >= 0.5, cur < 0.5 {
                let t = (prev - 0.5) / max(prev - cur, 0.0001)
                l = CGFloat(x - 1) + CGFloat(t)
            }
            if l != nil, prev < 0.5, cur >= 0.5 {
                let t = (0.5 - prev) / max(cur - prev, 0.0001)
                r = CGFloat(x - 1) + CGFloat(t)
                break
            }
            prev = cur
        }
        guard let ll = l, let rr = r, rr > ll else { continue }
        lefts.append((ll - CGFloat(x0), CGFloat(y - y0)))
        rights.append((rr - CGFloat(x0), CGFloat(y - y0)))
    }
    return (lefts, rights)
}

/// 轻微平滑，去掉 JPEG 噪点；端点保持不动以免破坏平顶
func smooth(_ pts: [(CGFloat, CGFloat)], kernel: Int = 3) -> [(CGFloat, CGFloat)] {
    guard pts.count > kernel * 2 else { return pts }
    var out = pts
    for i in kernel..<(pts.count - kernel) {
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        var wsum: CGFloat = 0
        for k in -kernel...kernel {
            let w = CGFloat(kernel + 1 - abs(k))
            sx += pts[i + k].0 * w
            sy += pts[i + k].1 * w
            wsum += w
        }
        out[i] = (sx / wsum, sy / wsum)
    }
    return out
}

/// 把描摹结果变成闭合路径（右侧下行 + 左侧上行），并缩放到目标尺寸
func chevronPath(frame: SourceFrame, targetW: CGFloat, targetH: CGFloat) -> CGPath {
    let (lp, rp) = traceRows(x0: frame.x0, x1: frame.x1, y0: frame.chevY0, y1: frame.chevY1)
    let L = smooth(lp), R = smooth(rp)
    guard L.count > 2, R.count == L.count else { return CGMutablePath() }

    // 以描摹结果的真实包围盒做归一化，保证缩放后恰好填满目标区域
    let minX = min(L.map { $0.0 }.min()!, R.map { $0.0 }.min()!)
    let maxX = max(L.map { $0.0 }.max()!, R.map { $0.0 }.max()!)
    let minY = min(L.map { $0.1 }.min()!, R.map { $0.1 }.min()!)
    let maxY = max(L.map { $0.1 }.max()!, R.map { $0.1 }.max()!)
    let srcW = max(maxX - minX, 0.001)
    let srcH = max(maxY - minY, 0.001)

    func tx(_ p: (CGFloat, CGFloat)) -> CGPoint {
        CGPoint(x: (p.0 - minX) / srcW * targetW,
                y: (p.1 - minY) / srcH * targetH)
    }

    let path = CGMutablePath()
    // 右侧自上而下
    path.move(to: tx(R[0]))
    for p in R.dropFirst() { path.addLine(to: tx(p)) }
    // 左侧自下而上
    for p in L.reversed() { path.addLine(to: tx(p)) }
    path.closeSubpath()
    return path
}

// MARK: - 胶囊与底板（参数化，边缘绝对锐利）

func capsulePath(w: CGFloat, h: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
           cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
}

func tilePath(w: CGFloat, h: CGFloat) -> CGPath {
    let r = w * tileCornerRatio
    return CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                  cornerWidth: r, cornerHeight: r, transform: nil)
}

// MARK: - 组合绘制
//
// 统一约定：所有这些函数都在「左上原点、y 向下」的坐标系里工作。
// 调用方负责在最外层翻转一次 CTM（见 beginTopLeft），内部不再翻转，
// 否则两层翻转会互相抵消，图形会上下颠倒。

/// 把 CGContext 翻到左上原点（调用一次，覆盖整张图）
func beginTopLeft(_ ctx: CGContext, height: CGFloat) {
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)
}

/// 在给定矩形里画"胶囊 + 箭头"（左上原点坐标）
func drawGlyph(in ctx: CGContext, rect: CGRect, spec: GlyphSpec, frame: SourceFrame, color: NSColor) {
    ctx.saveGState()
    ctx.setFillColor(color.cgColor)
    ctx.addPath(glyphPath(rect: rect, spec: spec, frame: frame))
    ctx.fillPath()
    ctx.restoreGState()
}

/// 字形轮廓（胶囊 + 箭头，两个子路径）。填色与描边光环都用它。
func glyphPath(rect: CGRect, spec: GlyphSpec, frame: SourceFrame) -> CGPath {
    let scale = min(rect.width / spec.outerW, rect.height / spec.totalH)
    let usedW = spec.outerW * scale
    let ox = rect.minX + (rect.width - usedW) / 2
    let oy = rect.minY

    let capW = spec.capsuleW * scale
    let capH = spec.capsuleH * scale
    let capX = ox + (usedW - capW) / 2

    let chevW = spec.chevW * scale
    let chevH = spec.chevH * scale
    let chevX = ox + (usedW - chevW) / 2 + spec.chevDx * scale
    let chevY = oy + capH + spec.gap * scale

    let p = CGMutablePath()
    p.addPath(capsulePath(w: capW, h: capH),
              transform: CGAffineTransform(translationX: capX, y: oy))
    p.addPath(chevronPath(frame: frame, targetW: chevW, targetH: chevH),
              transform: CGAffineTransform(translationX: chevX, y: chevY))
    return p
}

// MARK: - 彩虹光圈
//
// 与刘海上的拖入脉冲同源：沿字形轮廓描一圈彩虹。
// 描边以轮廓为中心线，靠外的半边露出来、靠里的半边被字形盖住，
// 所以黑色主体仍然锐利，光圈只从外面"渗"出来。

let rainbowRing: [CGColor] = [
    CGColor(srgbRed: 1.00, green: 0.37, blue: 0.56, alpha: 1),   // 玫红
    CGColor(srgbRed: 1.00, green: 0.69, blue: 0.24, alpha: 1),   // 琥珀
    CGColor(srgbRed: 0.48, green: 0.88, blue: 0.54, alpha: 1),   // 青柠
    CGColor(srgbRed: 0.25, green: 0.82, blue: 0.79, alpha: 1),   // 湖青
    CGColor(srgbRed: 0.36, green: 0.55, blue: 0.94, alpha: 1),   // 蓝
    CGColor(srgbRed: 0.65, green: 0.55, blue: 0.98, alpha: 1)    // 紫
]

/// 沿 path 描一圈彩虹。coreWidth 是"灯管"本体宽度，外两层按倍数放大、降低透明度当弥散。
func drawRainbowRing(in ctx: CGContext, path: CGPath, coreWidth: CGFloat, box: CGRect) {
    guard let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: rainbowRing as CFArray,
        locations: [0, 0.2, 0.4, 0.6, 0.8, 1]
    ) else { return }

    // 从外到内三层：这比真做高斯模糊更稳，也不会在不同尺寸下糊成一片
    let layers: [(CGFloat, CGFloat)] = [
        (coreWidth * 3.2, 0.16),
        (coreWidth * 1.9, 0.34),
        (coreWidth, 1.00)
    ]

    for (w, alpha) in layers {
        ctx.saveGState()
        ctx.addPath(path.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10))
        ctx.clip()
        ctx.setAlpha(alpha)
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: box.minX, y: box.midY),
            end: CGPoint(x: box.maxX, y: box.midY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }
}

/// 渲染 app 图标（方形画布，底板 + glyph）
func renderAppIcon(size: CGFloat) -> CGImage? {
    let px = Int(size)
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.saveGState()
    beginTopLeft(ctx, height: size)

    // macOS 标准：画布 1024 时圆角方块为 824，四周各留 100
    let tileSide = size * 824.0 / 1024.0
    let tileRect = CGRect(x: (size - tileSide) / 2, y: (size - tileSide) / 2,
                          width: tileSide, height: tileSide)

    // 底板 + 竖向渐变
    ctx.saveGState()
    ctx.translateBy(x: tileRect.minX, y: tileRect.minY)
    ctx.addPath(tilePath(w: tileSide, h: tileSide))
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [tileTop.cgColor, tileBottom.cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 0, y: tileSide),
                           options: [])
    // 原图底板边缘有一圈很淡的深色描边，保留它，图标才有轮廓感
    ctx.setStrokeColor(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.13).cgColor)
    ctx.setLineWidth(max(1, tileSide / 647.5 * 1.2))
    ctx.addPath(tilePath(w: tileSide, h: tileSide).copy(strokingWithWidth: max(1, tileSide / 647.5 * 1.2),
                                                        lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.fillPath()
    ctx.restoreGState()

    // glyph：按原图中的相对比例放进方块
    // 水平、纵向分别用各自方向的相对比例，这样源图那点非等比也不会被放大成变形；
    // glyph 自身用统一缩放，绝不拉伸。
    let sx = tileSide / tileSrcW
    let sy = tileSide / tileSrcH

    let glyphLeft = (CGFloat(appFrame.x0) - tileSrcX0) * sx + tileRect.minX
    let glyphTop = (CGFloat(appFrame.capsuleY0) - tileSrcY0) * sy + tileRect.minY
    let glyphW = CGFloat(appSpec.capsuleW) * sx
    let glyphH = appSpec.totalH * sx
    let glyphRect = CGRect(x: glyphLeft, y: glyphTop, width: glyphW, height: glyphH)

    let path = glyphPath(rect: glyphRect, spec: appSpec, frame: appFrame)

    // 先把彩虹光圈铺在下面，再把黑色字形压在上面。
    // 描边以轮廓为中心线，压在上面的字形会盖掉靠内的半边，
    // 于是光圈只从外缘渗出来——和刘海上的拖入脉冲同一个道理。
    ctx.saveGState()
    // 先在局部坐标里建立裁剪，再翻回原坐标画光圈
    ctx.translateBy(x: tileRect.minX, y: tileRect.minY)
    ctx.addPath(tilePath(w: tileSide, h: tileSide))
    ctx.clip()
    ctx.translateBy(x: -tileRect.minX, y: -tileRect.minY)
    drawRainbowRing(in: ctx, path: path, coreWidth: tileSide * 0.011, box: glyphRect)
    ctx.restoreGState()

    drawGlyph(in: ctx, rect: glyphRect, spec: appSpec, frame: appFrame, color: glyphColor)

    ctx.restoreGState()
    return ctx.makeImage()
}

/// 渲染菜单栏图标（模板图：纯黑 + alpha，系统按明暗自动着色）
/// 传逻辑宽度与倍率，保证 1x/2x/3x 严格成倍数，NSImage 的各 rep 才能对齐。
func renderMenuBarIcon(logicalW: CGFloat, logicalH: CGFloat, scale: Int) -> CGImage? {
    let h = Int((logicalH * CGFloat(scale)).rounded())
    let w = Int((logicalW * CGFloat(scale)).rounded())
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high

    ctx.saveGState()
    beginTopLeft(ctx, height: CGFloat(h))
    drawGlyph(in: ctx,
              rect: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
              spec: menuSpec, frame: menuFrame,
              color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.restoreGState()
    return ctx.makeImage()
}

func writePNG(_ img: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: img.width, height: img.height)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

// MARK: - 主流程

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 2
                 ? CommandLine.arguments[2] : "/tmp/iconout")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// 1) app 图标各尺寸
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (size, name) in variants {
    if let img = renderAppIcon(size: CGFloat(size)) {
        writePNG(img, to: iconset.appendingPathComponent(name))
    }
}
print("已生成 iconset：\(iconset.path)")

// 2) 菜单栏模板图（1x / 2x / 3x，基准高 14pt）
//    不再用 18pt：35×18 比一般状态栏图标宽出一截，和旁边那些不成比例。
//    14 × 1.962 ≈ 27.5 → 28×14，和 18pt 一档的高宽比一致，只是整体小一号。
let mb = outDir.appendingPathComponent("menubar")
try? FileManager.default.createDirectory(at: mb, withIntermediateDirectories: true)
let mbH: CGFloat = 14
let mbW: CGFloat = (mbH * menuSpec.outerW / menuSpec.totalH).rounded()
for (mult, name) in [(1, "MenuBarIcon.png"), (2, "MenuBarIcon@2x.png"), (3, "MenuBarIcon@3x.png")] {
    if let img = renderMenuBarIcon(logicalW: mbW, logicalH: mbH, scale: mult) {
        writePNG(img, to: mb.appendingPathComponent(name))
        print("菜单栏图标 \(name): \(img.width)x\(img.height) px  = \(mbW)x\(mbH) pt")
    }
}

// 3) 预览大图（便于检查）
if let big = renderAppIcon(size: 512) {
    writePNG(big, to: outDir.appendingPathComponent("preview_app_512.png"))
}
if let mbBig = renderMenuBarIcon(logicalW: (160 * menuSpec.outerW / menuSpec.totalH).rounded(), logicalH: 160, scale: 1) {
    writePNG(mbBig, to: outDir.appendingPathComponent("preview_menubar.png"))
}

// 4) 打包成 icns。
//    这一步必须放在生成 iconset 之后——之前漏了它，
//    结果 .icns 一直是旧的，换了图案也看不出来。
let icns = outDir.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
do {
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus == 0 {
        let size = ((try? FileManager.default.attributesOfItem(atPath: icns.path))?[.size] as? Int) ?? 0
        print("AppIcon.icns: \(size) 字节")
    } else {
        print("⚠️ iconutil 失败，退出码 \(p.terminationStatus)")
    }
} catch {
    print("⚠️ 无法执行 iconutil: \(error)")
}

print("预览图已生成")
