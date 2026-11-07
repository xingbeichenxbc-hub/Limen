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

/// 调试用：`LIMEN_APPEARANCE=dark|light` 强制外观。
///
/// 深色边缘这类问题只能在对应外观下判断，但改系统设置去验证是很讨厌的事
/// （会打断用户手上的一切）。这个开关只影响 Limen 自己的视图树。
enum AppearanceOverride {
    static var forced: ColorScheme? {
        switch ProcessInfo.processInfo.environment["LIMEN_APPEARANCE"] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}

/// 玻璃的几何调参点。放在非泛型类型里，才能从 `CardSurface` 外面引用。
enum GlassTuning {

    /// 内容相对窗口边界的内缩量，用来消掉卡片边缘那条黑缝。
    ///
    /// 卡片形状的裁剪边如果正好压在窗口边界上，窗口服务会在那一列物理像素上
    /// 把内容与窗口外的透明合成一次，结果是近黑的缝——白底实测 lum 0.12
    /// （卡片 0.78、背景 0.87），深底 0.02。让裁剪发生在窗口内部，缝就没了。
    static var seamInset: CGFloat {
        ProcessInfo.processInfo.environment["LIMEN_SEAM_INSET"]
            .flatMap(Double.init) ?? 1.0
    }

    /// 玻璃比卡片大出多少，多出来的部分由外层裁剪掉。
    /// 让 `glassEffect` 自带的材质边落在裁剪线之外。
    static var bleed: CGFloat {
        ProcessInfo.processInfo.environment["LIMEN_GLASS_BLEED"]
            .flatMap(Double.init) ?? 2.0
    }
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
    /// 卡片实际处于深色外观吗。深色下边缘要更淡（见 `thickness`），
    /// 不能沿用浅色那套数值——同一圈黑色内阴影，浅色底上是"厚度"，
    /// 深色底上就是一条脏黑边。
    var dark: Bool = false
    /// 卡片当前高度。只在"卡片被压扁"时用来淡出白色描边，
    /// 见 `whiteDetail`。默认给个大值，等于不启用。
    var cardHeight: CGFloat = 9999

    private var tinted: Bool { palette != nil }

    /// 卡片被压扁的程度：0 = 正常高度，1 = 已经压成一条线。
    ///
    /// **它是"收起时白边闪现"的解。** `NotchFade` 的渐变尾端是透明的，
    /// 卡片缩到十几 pt 时，那一小段透明露出的不是玻璃，而是下方的
    /// `thickness` 白描边——1.8pt 的白描边在 2pt 高的形状上被压成**一条横线**。
    /// 深色底实测 y=66 亮度 0.488，而背景只有 0.161，非常刺眼。
    ///
    /// 一个 6pt 高、正在消失的卡片本来就不该有"边缘高光"。所以让这些
    /// 白色细节随压扁程度淡出，留下玻璃本身——它与背景几乎同色，不会抢眼。
    private var squash: Double {
        let h = cardHeight
        if h >= 26 { return 0 }
        if h <= 10 { return 1 }
        return Double((26 - h) / 16)
    }

    /// 白色细节层（描边、镜面反射）的不透明度倍数
    private var whiteDetail: Double { 1 - squash }

    var body: some View {
        ZStack {
            shadow

            baseLayer

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
            }

            // 注意：这里**不再铺白膜**。
            // 之前那层 `white 0.20` 是"假通透"的根源——它把玻璃采样到的
            // 颜色和模糊一起抹平成灰白，看起来就是一块半透明白板。
            // 可读性改由「文字按背景明暗取色」+「下方厚薄边」来保证，
            // 不再靠给整块玻璃蒙一层白。

            thickness
            specular
            hairline
        }
        // 卡片被压扁时整体淡出。spring 的尾巴很长，高度收尾时白描边
        // 只淡了一半仍然会留一条亮线（真速实测 y=32pt 处 0.26 对背景 0.14）。
        // 卡片正在消失时就该整体退场，而不是留一层"半透明的自己"。
        .opacity(1 - squash * 0.92)
    }


    // MARK: - 玻璃的三层质感

    /// 深色外观（含专辑档，它的底色本来就钉在暗区间）。
    /// 这时候"边缘"不能靠压黑来做——见 `thickness`。
    private var onDark: Bool { dark || tinted }

    /// 卡片自己的投影。
    ///
    /// 为什么不用系统窗口投影：它在紧贴内容边缘的那一圈是近乎纯黑的核心暗环
    /// （白底 lum 0.12、深底 0.02），而周围是 0.78 / 0.16——就是那条"细细的黑边"。
    /// 它属于窗口服务，SwiftUI 层盖不掉，只能整体关掉再自己画。
    ///
    /// 关键差别：**只向下、且从一开始就是柔的**。
    /// 系统投影之所以形成黑边，是因为它在 0 偏移处密度最高、然后向外衰减；
    /// 这里把偏移设成正值、把颜色起点压到很低，卡片四周就不会出现暗环。
    ///
    /// 画在卡片内部（被 `clipShape` 裁掉外面那半），所以不需要窗口外扩，
    /// 也不影响命中区。
    private var shadow: some View {
        // 只沿**下缘**画一道柔暗，不用 fill+blur——
        // 那会把整块卡片一起压暗（实测从 0.78 掉到 0.66），像蒙了层灰。
        // 描边 + 向下偏移 + 大模糊，再裁回形状内部，就只剩贴边的一圈暗部。
        shape
            .stroke(Color.black.opacity((onDark ? 0.34 : 0.24) * whiteDetail), lineWidth: 4)
            .blur(radius: 5)
            .offset(y: 3)
            .clipShape(shape)
            .allowsHitTesting(false)
    }

    /// 内缘的"厚度"：上亮下暗。
    ///
    /// 真玻璃的边缘会把光吸进去再吐出来，表现为内侧一圈柔和的亮边，
    /// 底部因为背后没有光而略暗。这两笔是这个卡片"像玻璃"而不是
    /// "像一块半透明色块"的关键。
    ///
    /// **深色底上不能再压黑。** 浅色玻璃压一点黑是"厚度"，深色玻璃本来就暗，
    /// 再叠一圈黑描边就是一条可辨的脏黑线——2.6pt 的描边配 2.6pt 模糊，
    /// 影响范围接近 10pt，在深色背景上非常显眼。深色下改成：
    /// 暗边几乎取消，只留一丝；亮度全靠上缘高光来交代。
    /// 这也是 macOS 26/27 玻璃的做法——深色下边缘是"亮起来"，不是"黑下去"。
    private var thickness: some View {
        ZStack {
            // 内侧柔光
            shape
                .stroke(
                    Color.white.opacity((onDark ? 0.22 : 0.55) * whiteDetail),
                    lineWidth: onDark ? 1.6 : 2.4
                )
                .blur(radius: onDark ? 1.8 : 2.0)
                .clipShape(shape)
                .mask(
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white.opacity(onDark ? 0.45 : 0.55), location: 0.30),
                                .init(color: .clear, location: onDark ? 0.58 : 0.68)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                )
                .allowsHitTesting(false)

            // 底部内阴影：暗示玻璃有厚度，也让卡片下缘从背景里"站"起来。
            // 深色底上刻意压到极淡（0.07）：它只用来把下缘从深色壁纸里
            // 分出一点点层次，不该被看见。
            shape
                .stroke(
                    Color.black.opacity((onDark ? 0.07 : 0.22) * whiteDetail),
                    lineWidth: onDark ? 2.0 : 2.6
                )
                .blur(radius: onDark ? 2.2 : 2.6)
                .clipShape(shape)
                .mask(
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.42),
                                .init(color: .white.opacity(0.5), location: 0.80),
                                .init(color: .white, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                )
                .allowsHitTesting(false)
        }
    }

    /// 斜向反光：玻璃被单一光源照到的那道宽而淡的亮带。
    /// 只在左上角出现，越往下越淡，不要做成一条硬边。
    private var specular: some View {
        shape
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity((onDark ? 0.12 : 0.20) * whiteDetail), location: 0.0),
                        .init(color: .white.opacity((onDark ? 0.04 : 0.06) * whiteDetail), location: 0.18),
                        .init(color: .clear, location: 0.52)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    /// 1pt 描边：玻璃的轮廓线。
    ///
    /// 深色下这条线是**白**的（`Color.primary` 在深色里就是白色），
    /// 所以它不是黑边的来源；但 0.34 的白在深色玻璃上会跳成一道明显的
    /// 细白线，和刚去掉的黑边一样扎眼。深色下一律压到很淡：
    /// 它只需要"勾一下轮廓"，不需要被看见。
    private var hairline: some View {
        shape.stroke(
            LinearGradient(
                stops: onDark
                    ? [
                        .init(color: Color.white.opacity(0.16), location: 0.0),
                        .init(color: Color.white.opacity(0.05), location: 0.20),
                        .init(color: Color.white.opacity(0.04), location: 0.72),
                        .init(color: Color.white.opacity(0.06), location: 1.0)
                      ]
                    : [
                        .init(color: Color.white.opacity(0.62), location: 0.0),
                        .init(color: Color.white.opacity(0.20), location: 0.18),
                        .init(color: Color.primary.opacity(0.10), location: 0.70),
                        .init(color: Color.primary.opacity(0.26), location: 1.0)
                      ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 1.0
        )
        .opacity(whiteDetail)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var baseLayer: some View {
        if CardSurface.probe {
            shape.fill(Color(red: 1.0, green: 0.0, blue: 1.0))
        } else if #available(macOS 26.0, *) {
            switch style {
            case .liquidClear, .album:
                // 专辑档在没有封面时（palette 为 nil）就等同于通透玻璃，
                // 自然回退，不需要额外分支。
                ZStack {
                    GlassFill(.clear, bleed: GlassTuning.bleed)
                    contrastTint
                }
            case .liquidRegular:
                ZStack {
                    GlassFill(.regular, bleed: GlassTuning.bleed)
                    contrastTint
                }
            case .visual:
                ZStack {
                    VisualEffect(material: .popover, blending: .behindWindow)
                        .clipShape(shape)
                    contrastTint
                }
            }
        } else {
            VisualEffect(material: .popover, blending: .behindWindow)
                .clipShape(shape)
        }
    }

    /// 玻璃的对比度下限（真正的根因修复）。
    ///
    /// 所有采样背景的材质（玻璃、毛玻璃）在明亮背景上都会显得过于通透：
    /// 白色窗口在刘海下方时，卡片亮到 180+，白字白卡不可读（原始 0.9.0
    /// 实测 211）。这一层色调**作用在透进来的背景上**——深色桌面时
    /// 暗+暗≈不可见，玻璃观感不变；明亮背景时把卡片压暗，文字立刻分得开。
    /// 这就是「不采样背景的自适应」。
    ///
    /// 三档强度递进，保证相对关系与档名一致：通透最透、底衬最轻；
    /// 标准更实；磨砂最实、底衬最重。深色外观用黑色调保护白字，
    /// 浅色外观用白色调保护深字。
    private var contrastTint: some View {
        shape
            .fill(
                LinearGradient(
                    stops: onDark
                        ? [
                            .init(color: .black.opacity(tintStrength.top), location: 0.0),
                            .init(color: .black.opacity(tintStrength.bottom), location: 1.0)
                          ]
                        : [
                            .init(color: .white.opacity(tintStrength.top), location: 0.0),
                            .init(color: .white.opacity(tintStrength.bottom), location: 1.0)
                          ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
    }

    /// 各档玻璃的对比度下限强度（上、下两端的透明度）。
    private var tintStrength: (top: Double, bottom: Double) {
        switch style {
        case .liquidClear, .album:
            return onDark ? (0.55, 0.72) : (0.16, 0.30)
        case .liquidRegular:
            return onDark ? (0.66, 0.80) : (0.20, 0.34)
        case .visual:
            return onDark ? (0.74, 0.86) : (0.24, 0.38)
        }
    }

    /// 玻璃要比卡片大出这么多，多出来的部分会被外层 `clipShape(shape)` 裁掉。
    ///
    /// **这是"细黑边"的解法。** `glassEffect` 在材质边缘会画一圈自己的
    /// 内描边，实测在白色背景上是 lum 0.13（内部 0.78、背景 0.87），
    /// 深色背景上是 0.02——正好 1pt 宽，任何覆盖层都盖不掉，因为它属于
    /// 材质本身。把玻璃放大再裁掉，那圈边就落在裁剪线外面了。
    ///
    /// 2pt 足够：描边 + 抗锯齿的实际影响范围约 1.5pt。
}

/// 一块"比容器大一圈"的玻璃。
///
/// 用 `Rectangle` 而不是卡片形状：形状由外层 `clipShape` 负责，
/// 这里只需要一块足够大的材质，让它的边缘落在裁剪线之外。
private struct GlassFill: View {
    let kind: GlassKind
    let bleed: CGFloat

    enum GlassKind {
        case clear
        case regular
    }

    init(_ kind: GlassKind, bleed: CGFloat) {
        self.kind = kind
        self.bleed = bleed
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(kind == .clear ? .clear : .regular, in: Rectangle())
                .padding(-bleed)
                .allowsHitTesting(false)
        } else {
            Color.clear
        }
    }
}
