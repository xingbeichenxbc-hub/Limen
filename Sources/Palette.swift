import AppKit
import SwiftUI

/// 从专辑封面提取出来的一套颜色。
///
/// 设计原则：不管封面是什么颜色（包括纯白、纯黑、灰度），
/// 最终卡片底色都必须足够深，这样白字才永远读得清。
/// 所以这里不直接拿"平均色"当底色——平均色往往发灰发脏，
/// 而是提取**主色相**，再按固定规则派生出深色底和亮色强调色。
struct AlbumPalette: Equatable {
    /// 主色的色相（0..1）
    var hue: Double
    /// 主色的饱和度（0..1）
    var saturation: Double
    /// 强调色：用于进度线、激活图标。偏亮、偏艳
    var accent: Color
    /// 卡片底色（上）：深色、同色相
    var baseTop: Color
    /// 卡片底色（下）：更深一点，做出层次
    var baseBottom: Color
    /// 封面本身是否偏亮。用于微调高光强度
    var isLightSource: Bool

    /// 给 SwiftUI 用的主色，按亮度排序后最鲜艳的那个
    static func extract(from image: NSImage) -> AlbumPalette? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let size = 32
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(
            data: &buf,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        // 36 个色相桶
        let binCount = 36
        var weight = [Double](repeating: 0, count: binCount)
        var sumR = [Double](repeating: 0, count: binCount)
        var sumG = [Double](repeating: 0, count: binCount)
        var sumB = [Double](repeating: 0, count: binCount)

        var totalLum = 0.0
        var count = 0.0
        var totalWeight = 0.0

        for i in stride(from: 0, to: buf.count, by: 4) {
            let a = Double(buf[i + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(buf[i]) / 255
            let g = Double(buf[i + 1]) / 255
            let b = Double(buf[i + 2]) / 255

            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            totalLum += lum
            count += 1

            let (h, s, v) = Self.hsv(r: r, g: g, b: b)

            // 只丢掉近黑和近灰的像素。
            // 注意：**不能**用"亮度不能太高"来排除白色——纯白饱和度本来就是 0，
            // 已经被 s 卡掉了；再加亮度上限会把亮黄、亮橙这类鲜艳主色一起误杀。
            guard v > 0.10, s > 0.16 else { continue }

            // 偏好中等亮度的颜色，但不过分惩罚明亮色：
            // 权重下限给到 0.35，保证黄色(v≈1.0)这类依然能胜出。
            let vibrancy = s * (0.35 + 0.65 * (1.0 - min(1.0, abs(v - 0.65) / 0.65)))
            guard vibrancy > 0.03 else { continue }

            let idx = min(binCount - 1, max(0, Int(h * Double(binCount))))
            weight[idx] += vibrancy
            sumR[idx] += r * vibrancy
            sumG[idx] += g * vibrancy
            sumB[idx] += b * vibrancy
            totalWeight += vibrancy
        }

        // 色相桶平滑：渐变封面（如粉→橙）的颜色会分散到相邻桶里，
        // 不平滑的话容易被一小块纯色反超。环形卷积一次即可。
        let raw = weight
        for i in 0..<binCount {
            let prev = raw[(i - 1 + binCount) % binCount]
            let next = raw[(i + 1) % binCount]
            weight[i] = raw[i] + 0.45 * (prev + next)
        }

        let avgLum = count > 0 ? totalLum / count : 0.5

        // 找不到足够鲜艳的像素（黑白封面、灰度照）：
        // 退化为"低饱和中性色"，避免硬造一个假颜色。
        guard totalWeight > 3.0,
              let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > 0 else {
            return Self.neutral(light: avgLum > 0.6)
        }

        let w = weight[best]
        let pr = sumR[best] / w
        let pg = sumG[best] / w
        let pb = sumB[best] / w
        let (h, s, _) = Self.hsv(r: pr, g: pg, b: pb)

        return Self.make(hue: h, saturation: s, lightSource: avgLum > 0.62)
    }

    /// 由色相/饱和度派生整套颜色。
    /// 关键是把底色亮度钉死在暗区间，白字对比度才稳定。
    static func make(hue h: Double, saturation s: Double, lightSource: Bool) -> AlbumPalette {
        // 强调色：亮、艳，用来点睛
        let accentSat = min(0.85, max(0.30, s * 1.12))
        let accent = Color(hue: h, saturation: accentSat, brightness: 0.88)

        // 底色：低亮度 + 略降饱和，避免太"荧光"
        let baseSat = min(0.72, max(0.16, s * 0.82))
        let top = Color(hue: h, saturation: baseSat, brightness: 0.30)
        let bottom = Color(hue: h, saturation: min(0.80, baseSat * 1.08), brightness: 0.20)

        return AlbumPalette(
            hue: h,
            saturation: s,
            accent: accent,
            baseTop: top,
            baseBottom: bottom,
            isLightSource: lightSource
        )
    }

    /// 灰度/黑白封面的退化方案：低饱和的冷灰，仍然暗，保证白字可读
    static func neutral(light: Bool) -> AlbumPalette {
        make(hue: 0.60, saturation: 0.10, lightSource: light)
    }

    static func hsv(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let mx = max(r, max(g, b))
        let mn = min(r, min(g, b))
        let d = mx - mn
        var h = 0.0
        if d > 0.0001 {
            if mx == r {
                h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
            } else if mx == g {
                h = (b - r) / d + 2
            } else {
                h = (r - g) / d + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = mx <= 0.0001 ? 0 : d / mx
        return (h, s, mx)
    }
}
