import SwiftUI
import AppKit

/// 从刘海向下长出的卡片形状：顶部直角（与刘海贴合），底部圆角（可动画）。
struct NotchCardShape: Shape {
    var height: CGFloat
    var radius: CGFloat = 21

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let h = min(max(height, 0), rect.height)
        let r = min(radius, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - r * 0.78, y: rect.minY + h),
            control: CGPoint(x: rect.maxX - r * 0.06, y: rect.minY + h - r * 0.06)
        )
        p.addLine(to: CGPoint(x: rect.minX + r * 0.78, y: rect.minY + h))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + h - r),
            control: CGPoint(x: rect.minX + r * 0.06, y: rect.minY + h - r * 0.06)
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// 系统级毛玻璃（真正的背景采样，不是画出来的模糊）
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = .active
    }
}

enum GlassStyle: String, CaseIterable {
    case liquidClear = "liquid-clear"        // 液态玻璃 · 通透（默认，透色最强）
    case liquidRegular = "liquid-regular"    // 液态玻璃 · 标准（更实，字更清楚）
    case visual = "visual"                   // 传统毛玻璃
    case album = "album"                     // 专辑：底色由当前封面取色

    var shortTitle: String {
        switch self {
        case .liquidClear: return "通透"
        case .liquidRegular: return "标准"
        case .visual: return "磨砂"
        case .album: return "专辑"
        }
    }

    /// 这一档是否需要用专辑封面的配色
    var usesAlbumPalette: Bool { self == .album }
}

/// 卡片底：玻璃 + 极细高光描边
struct CardSurface<S: Shape>: View {
    /// 调试用：不透明纯色，便于逐帧测量形状动画（正常运行时不会走到这里）
    static var probe: Bool {
        ProcessInfo.processInfo.environment["LIMEN_PROBE"] == "1"
    }

    let shape: S
    var style: GlassStyle = .liquidClear
    /// 有值时用专辑封面的配色给卡片上色
    var palette: AlbumPalette? = nil

    @Environment(\.colorScheme) private var scheme

    private var tinted: Bool { palette != nil }

    var body: some View {
        ZStack {
            base

            if let p = palette {
                // 专辑色层：同色相的深色渐变。
                // 亮度被 Palette 钉在暗区间，所以白字对比度是稳定的，
                // 不受壁纸明暗影响——这是这个功能能安全上色的前提。
                shape
                    .fill(
                        LinearGradient(
                            colors: [p.baseTop, p.baseBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.92)
                    .allowsHitTesting(false)

                // 一点点强调色的晕染，让"专辑的色"更可辨，但不至于变成色块
                shape
                    .fill(
                        RadialGradient(
                            colors: [p.accent.opacity(0.22), p.accent.opacity(0.0)],
                            center: .topTrailing,
                            startRadius: 0,
                            endRadius: 150
                        )
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            } else {
                // 极淡的补偿层：保证文字在任何壁纸上都读得清，同时不压掉通透感
                shape
                    .fill(scheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.20))
                    .allowsHitTesting(false)
            }

            // 上缘高光：玻璃被光照到的那一道，克制一点，只占顶部三成
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(tinted ? 0.10 : 0.13), location: 0.0),
                            .init(color: Color.white.opacity(tinted ? 0.02 : 0.03), location: 0.16),
                            .init(color: Color.clear, location: 0.34)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            shape
                .stroke(
                    LinearGradient(
                        stops: tinted
                            ? [
                                .init(color: Color.white.opacity(0.16), location: 0.0),
                                .init(color: Color.white.opacity(0.05), location: 0.16),
                                .init(color: Color.white.opacity(0.08), location: 0.72),
                                .init(color: Color.white.opacity(0.16), location: 1.0)
                              ]
                            : [
                                .init(color: Color.white.opacity(0.18), location: 0.0),
                                .init(color: Color.white.opacity(0.06), location: 0.16),
                                .init(color: Color.primary.opacity(0.09), location: 0.72),
                                .init(color: Color.primary.opacity(0.20), location: 1.0)
                              ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.0
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var base: some View {
        if CardSurface.probe {
            shape.fill(Color(red: 1.0, green: 0.0, blue: 1.0))
        } else if #available(macOS 26.0, *) {
            switch style {
            case .liquidClear, .album:
                // 专辑档在没有封面时（palette 为 nil）就等同于通透玻璃，
                // 自然回退，不需要额外分支。
                Color.clear.glassEffect(.clear, in: shape)
            case .liquidRegular:
                Color.clear.glassEffect(.regular, in: shape)
            case .visual:
                VisualEffect(material: .popover, blending: .behindWindow)
                    .clipShape(shape)
            }
        } else {
            VisualEffect(material: .popover, blending: .behindWindow)
                .clipShape(shape)
        }
    }
}
