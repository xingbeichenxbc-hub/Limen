import AppKit

// MARK: - 时间格式

enum CountdownFormat {
    /// 秒 → "mm:ss"（不足 1 小时）或 "h:mm:ss"
    static func clock(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 路径等距采样

/// 沿刘海 U 形轮廓做等距采样，让光团能按「走过的路程」取位置，
/// 而不是按参数 t——t 均分出来的点在转角处会忽快忽慢。
struct PathSampler {
    private var points: [CGPoint] = []
    private var lengths: [CGFloat] = []
    private(set) var total: CGFloat = 0

    init(path: CGPath, samplesPerSegment: Int = 24) {
        var pts: [CGPoint] = []
        path.applyWithBlock { elementPtr in
            let el = elementPtr.pointee
            switch el.type {
            case .moveToPoint:
                pts = [el.points[0]]
            case .addLineToPoint:
                let a = pts.last ?? el.points[0]
                let b = el.points[0]
                for i in 1...samplesPerSegment {
                    let t = CGFloat(i) / CGFloat(samplesPerSegment)
                    pts.append(CGPoint(x: a.x + (b.x - a.x) * t,
                                       y: a.y + (b.y - a.y) * t))
                }
            case .addQuadCurveToPoint:
                let a = pts.last ?? el.points[0]
                let c = el.points[0]
                let b = el.points[1]
                for i in 1...samplesPerSegment {
                    let t = CGFloat(i) / CGFloat(samplesPerSegment)
                    let mt = 1 - t
                    pts.append(CGPoint(
                        x: mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x,
                        y: mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y
                    ))
                }
            default:
                break
            }
        }
        points = pts
        var acc: CGFloat = 0
        lengths = [0]
        if pts.count > 1 {
            for i in 1..<pts.count {
                acc += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
                lengths.append(acc)
            }
        }
        total = acc
    }

    /// fraction 0 = 刘海左上角，1 = 右上角，中途按弧长均匀
    func point(at fraction: CGFloat) -> CGPoint {
        guard total > 0, !points.isEmpty else { return .zero }
        let f = min(max(fraction, 0), 1)
        let target = f * total
        var lo = 0
        var hi = lengths.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lengths[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        guard lo < points.count - 1 else { return points.last ?? .zero }
        let seg = lengths[lo + 1] - lengths[lo]
        let local = seg > 0 ? (target - lengths[lo]) / seg : 0
        let a = points[lo]
        let b = points[lo + 1]
        return CGPoint(x: a.x + (b.x - a.x) * local,
                       y: a.y + (b.y - a.y) * local)
    }
}

// MARK: - 倒计时发光层

/// 倒计时的刘海边缘进度：一个会呼吸的小光团从刘海左上角出发，
/// 沿轮廓走到右上角，走过的路留下一条窄窄的发光路径；
/// 走完后整条路径「吸气扩大」，并保持发光跃动，直到弹窗里点了关闭。
///
/// 为什么用 Core Animation 而不是 SwiftUI：它住在光晕窗口里，
/// 和彩虹光晕同一套理由——CA 动画由渲染服务推进，进度由 0.1s 定时器
/// 按墙钟时间直接写值，任何界面卡顿都不会让进度停摆。
final class CountdownLayer: CALayer {

    /// 琥珀光。明、暗菜单栏下都可辨，也跟彩虹光晕的色调拉开距离。
    private static let coreColor = CGColor(srgbRed: 1.00, green: 0.66, blue: 0.24, alpha: 1)
    private static let softColor = CGColor(srgbRed: 1.00, green: 0.52, blue: 0.16, alpha: 1)
    private static let haloColor = CGColor(srgbRed: 1.00, green: 0.75, blue: 0.33, alpha: 1)
    private static let hotColor  = CGColor(srgbRed: 1.00, green: 0.98, blue: 0.90, alpha: 1)

    /// 结束态的虹彩光谱（柔光层与外圈用）：从进行态同色的琥珀橙出发，
    /// 经珊瑚/玫瑰/紫罗兰/蓝紫/天蓝/青/薄荷/金，回到琥珀橙，无限循环。
    /// 相邻色相很近，RGB 插值不会穿过灰区——整环永远保持"发光"的质感，
    /// 这是「光环」而不是「色带」的关键。亮度全部压在高位，
    /// 是宝石边缘那种薄薄的虹彩，不是霓虹灯。
    private static let spectral: [CGColor] = [
        softColor,                                                  // 琥珀橙（与进行态同色，交接无跳变）
        CGColor(srgbRed: 1.00, green: 0.55, blue: 0.46, alpha: 1),  // 珊瑚
        CGColor(srgbRed: 1.00, green: 0.50, blue: 0.64, alpha: 1),  // 玫瑰
        CGColor(srgbRed: 0.88, green: 0.52, blue: 0.98, alpha: 1),  // 紫罗兰
        CGColor(srgbRed: 0.62, green: 0.58, blue: 1.00, alpha: 1),  // 蓝紫
        CGColor(srgbRed: 0.48, green: 0.74, blue: 1.00, alpha: 1),  // 天蓝
        CGColor(srgbRed: 0.42, green: 0.88, blue: 0.90, alpha: 1),  // 青
        CGColor(srgbRed: 0.54, green: 0.92, blue: 0.68, alpha: 1),  // 薄荷
        CGColor(srgbRed: 0.98, green: 0.78, blue: 0.40, alpha: 1),  // 金（与琥珀橙同族，闭环）
    ]

    /// 白热核心用的同序列虹彩：从进行态同色的核心琥珀出发，
    /// 每一档都混入更多白——核心始终像"被光照亮"，只是微微带色。
    private static let spectralCore: [CGColor] = {
        var out: [CGColor] = [coreColor]
        for c in spectral.dropFirst() {
            let cc = c.components ?? [0, 0, 0, 1]
            out.append(CGColor(srgbRed: cc[0] * 0.45 + 0.55,
                               green: cc[1] * 0.45 + 0.55,
                               blue: cc[2] * 0.45 + 0.55,
                               alpha: 1))
        }
        return out
    }()

    /// 进行中的发光路径：宽柔光垫底 + 窄亮核心，两层的 strokeEnd 一起推进。
    private let trailSoft = CAShapeLayer()
    private let trailCore = CAShapeLayer()
    /// 结束态的虹彩光环：外圈大柔光 + 宽柔光 + 亮核心。
    /// 与进行中的路径是**两套独立的结构**——结束时路径安静淡出，
    /// 光环以最终形态直接淡入（Siri 式柔光登场），不做线宽生长动画，
    /// 从机制上就没有"闪"和"跳"。
    private let haloAura = CAShapeLayer()
    private let haloSoft = CAShapeLayer()
    private let haloCore = CAShapeLayer()
    /// 光团：外圈光晕 + 白热核心，容器层负责移动
    private let orb = CALayer()
    private let orbHalo = CAShapeLayer()
    private let orbCore = CAShapeLayer()

    private var sampler: PathSampler?
    private var configured = false
    private var runningVisuals = false
    private var finishedState = false

    override init() {
        super.init()
        zPosition = 60        // 低于拖拽彩虹(100)：同时出现时彩虹在上
        masksToBounds = false
        buildLayers()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayers() {
        // 光环三层（结束态专用，平时全透明）。放在路径下面，
        // 交叉溶解时进行中的细线始终浮在光环之上，边缘保持清晰。
        haloAura.fillColor = nil
        haloAura.strokeColor = Self.softColor
        haloAura.lineWidth = 20
        haloAura.lineCap = .round
        haloAura.lineJoin = .round
        haloAura.opacity = 0
        haloAura.strokeStart = 0
        haloAura.strokeEnd = 0
        haloAura.shadowColor = Self.softColor
        haloAura.shadowRadius = 18
        haloAura.shadowOpacity = 0.8
        haloAura.shadowOffset = .zero

        haloSoft.fillColor = nil
        haloSoft.strokeColor = Self.softColor
        haloSoft.lineWidth = 16
        haloSoft.lineCap = .round
        haloSoft.lineJoin = .round
        haloSoft.opacity = 0
        haloSoft.strokeStart = 0
        haloSoft.strokeEnd = 0
        haloSoft.shadowColor = Self.softColor
        haloSoft.shadowRadius = 16
        haloSoft.shadowOpacity = 0.7
        haloSoft.shadowOffset = .zero

        haloCore.fillColor = nil
        haloCore.strokeColor = Self.coreColor
        haloCore.lineWidth = 4.2
        haloCore.lineCap = .round
        haloCore.lineJoin = .round
        haloCore.opacity = 0
        haloCore.strokeStart = 0
        haloCore.strokeEnd = 0
        haloCore.shadowColor = Self.coreColor
        haloCore.shadowRadius = 9
        haloCore.shadowOpacity = 0.85
        haloCore.shadowOffset = .zero

        trailSoft.fillColor = nil
        trailSoft.strokeColor = Self.softColor
        trailSoft.lineWidth = 7
        trailSoft.lineCap = .round
        trailSoft.lineJoin = .round
        trailSoft.opacity = 0
        trailSoft.strokeStart = 0
        trailSoft.strokeEnd = 0
        trailSoft.shadowColor = Self.softColor
        trailSoft.shadowRadius = 7
        trailSoft.shadowOpacity = 0.7
        trailSoft.shadowOffset = .zero

        trailCore.fillColor = nil
        trailCore.strokeColor = Self.coreColor
        trailCore.lineWidth = 2.2
        trailCore.lineCap = .round
        trailCore.lineJoin = .round
        trailCore.opacity = 0
        trailCore.strokeStart = 0
        trailCore.strokeEnd = 0
        trailCore.shadowColor = Self.coreColor
        trailCore.shadowRadius = 4
        trailCore.shadowOpacity = 0.85
        trailCore.shadowOffset = .zero

        addSublayer(haloAura)
        addSublayer(haloSoft)
        addSublayer(haloCore)
        addSublayer(trailSoft)
        addSublayer(trailCore)

        orbHalo.fillColor = Self.haloColor.copy(alpha: 0.45)
        orbHalo.strokeColor = nil
        orbHalo.shadowColor = Self.haloColor
        orbHalo.shadowRadius = 5
        orbHalo.shadowOpacity = 0.9
        orbHalo.shadowOffset = .zero

        orbCore.fillColor = Self.hotColor
        orbCore.strokeColor = nil
        orbCore.shadowColor = NSColor.white.cgColor
        orbCore.shadowRadius = 3
        orbCore.shadowOpacity = 1
        orbCore.shadowOffset = .zero

        orb.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        orb.opacity = 0
        orb.addSublayer(orbHalo)
        orb.addSublayer(orbCore)
        addSublayer(orb)
    }

    // MARK: 配置

    func configure(metrics: NotchMetrics, size: CGSize) {
        frame = CGRect(origin: .zero, size: size)
        guard metrics.mode == .notch, size.width > 10, size.height > 10 else {
            configured = false
            sampler = nil
            resetVisuals()
            return
        }
        let path = NotchGlowLayer.makeRingPath(size: size, metrics: metrics)
        sampler = PathSampler(path: path)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        haloAura.path = path
        haloSoft.path = path
        haloCore.path = path
        trailSoft.path = path
        trailCore.path = path
        let haloR: CGFloat = 6.5
        let coreR: CGFloat = 2.6
        orbHalo.path = CGPath(ellipseIn: CGRect(x: 12 - haloR, y: 12 - haloR,
                                                width: haloR * 2, height: haloR * 2),
                              transform: nil)
        orbCore.path = CGPath(ellipseIn: CGRect(x: 12 - coreR, y: 12 - coreR,
                                                width: coreR * 2, height: coreR * 2),
                              transform: nil)
        CATransaction.commit()
        configured = true
        resetVisuals()
    }

    private func resetVisuals() {
        haloAura.removeAllAnimations()
        haloSoft.removeAllAnimations()
        haloCore.removeAllAnimations()
        trailSoft.removeAllAnimations()
        trailCore.removeAllAnimations()
        orb.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        haloAura.opacity = 0
        haloAura.strokeEnd = 0
        haloSoft.opacity = 0
        haloSoft.strokeEnd = 0
        haloCore.opacity = 0
        haloCore.strokeEnd = 0
        trailSoft.opacity = 0
        trailSoft.strokeEnd = 0
        trailSoft.lineWidth = 7
        trailSoft.shadowRadius = 7
        trailCore.opacity = 0
        trailCore.strokeEnd = 0
        trailCore.lineWidth = 2.2
        trailCore.shadowRadius = 4
        // 颜色复位到琥珀：虹彩循环结束后模型色可能停在任意一档，
        // 下次开始计时必须是琥珀（进行态的颜色）。
        haloAura.strokeColor = Self.softColor
        haloAura.shadowColor = Self.softColor
        haloSoft.strokeColor = Self.softColor
        haloSoft.shadowColor = Self.softColor
        haloCore.strokeColor = Self.coreColor
        haloCore.shadowColor = Self.coreColor
        trailSoft.strokeColor = Self.softColor
        trailSoft.shadowColor = Self.softColor
        trailCore.strokeColor = Self.coreColor
        trailCore.shadowColor = Self.coreColor
        orb.opacity = 0
        if let p = sampler?.point(at: 0) { orb.position = p }
        CATransaction.commit()
        runningVisuals = false
        finishedState = false
    }

    // MARK: 时序

    /// 从头开始一次计时
    func startRunning() {
        guard configured else { return }
        beginRunningVisuals()
        showProgress(0)
    }

    private func beginRunningVisuals() {
        guard configured, !finishedState else { return }
        resetVisuals()
        runningVisuals = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailSoft.opacity = 0.30
        trailCore.opacity = 0.95
        orb.opacity = 1
        if let p = sampler?.point(at: 0) { orb.position = p }
        CATransaction.commit()
        startBreath()
    }

    /// 推进到 fraction（0–1）。由控制器每 0.1s 调一次，按墙钟时间换算，
    /// 直接写值不走动画——这样机器睡眠、界面卡顿都不会让进度失真。
    func showProgress(_ fraction: Double) {
        guard configured, !finishedState else { return }
        if !runningVisuals { beginRunningVisuals() }
        let f = CGFloat(min(max(fraction, 0), 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailSoft.strokeEnd = f
        trailCore.strokeEnd = f
        if let p = sampler?.point(at: f) { orb.position = p }
        CATransaction.commit()
    }

    /// 光团的呼吸：每 2 秒一个完整周期（1s 涨、1s 落）。
    /// 只动 scale 和 opacity，不碰 position，所以和进度推进互不干扰。
    private func startBreath() {
        orb.removeAnimation(forKey: "breath")
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.22
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0.72
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.0
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        orb.add(group, forKey: "breath")
    }

    /// 走完：光团融进路径，进行中的细线安静淡出，虹彩光环以**最终形态**
    /// 直接淡入（Siri 式柔光登场），随后开始呼吸与虹彩漂移。
    /// 全程只有交叉溶解，没有任何线宽生长或亮度爬坡——机制上就没有"闪"。
    func finish() {
        guard configured, !finishedState else { return }
        if !runningVisuals { beginRunningVisuals() }
        finishedState = true

        // 光团融进路径：放慢一点，让"完成"有一个安顿的瞬间
        orb.removeAnimation(forKey: "breath")
        let orbOut = CABasicAnimation(keyPath: "opacity")
        orbOut.fromValue = orb.presentation()?.opacity ?? orb.opacity
        orbOut.toValue = 0
        orbOut.duration = 0.6
        orbOut.timingFunction = CAMediaTimingFunction(name: .easeOut)
        orbOut.fillMode = .forwards
        orbOut.isRemovedOnCompletion = false
        orb.opacity = 0
        orb.add(orbOut, forKey: "orbOut")

        // 路径与光环都先完整包住刘海
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailSoft.strokeEnd = 1
        trailCore.strokeEnd = 1
        haloAura.strokeEnd = 1
        haloSoft.strokeEnd = 1
        haloCore.strokeEnd = 1
        CATransaction.commit()

        // 进行中的细线安静淡出
        func fadeOut(_ layer: CAShapeLayer, key: String, dur: CFTimeInterval) {
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.removeAllAnimations()
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from
            a.toValue = 0
            a.duration = dur
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.opacity = 0
            layer.add(a, forKey: key)
        }
        fadeOut(trailSoft, key: "trailOutS", dur: 0.7)
        fadeOut(trailCore, key: "trailOutC", dur: 0.7)

        // 光环以最终形态淡入：先停一拍（0.15s），再用 1.6s 的 easeInOut
        // 缓缓亮起——起步缓、中段稳、收尾柔，像 Siri 的柔光浮现，
        // 而不是"啪"地一下亮。模型值保持 0，靠 fillMode 撑住淡入的终值，
        // 之后的呼吸动画从相同的终值接上，全程连续。
        let fadeInStart = CACurrentMediaTime() + 0.15
        func fadeInLayer(_ layer: CAShapeLayer, to: Float, key: String) {
            layer.opacity = 0
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = to
            a.duration = 1.6
            a.beginTime = fadeInStart
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: key)
        }
        fadeInLayer(haloAura, to: 0.30, key: "haloInA")
        fadeInLayer(haloSoft, to: 0.70, key: "haloInS")
        fadeInLayer(haloCore, to: 1.0, key: "haloInC")

        // 呼吸与虹彩在淡入完成（0.15 + 1.6 = 1.75s）后接上
        let when = CACurrentMediaTime() + 1.75
        let breathCore = CABasicAnimation(keyPath: "opacity")
        breathCore.fromValue = 1.0
        breathCore.toValue = 0.66
        breathCore.duration = 1.0
        breathCore.autoreverses = true
        breathCore.repeatCount = .infinity
        breathCore.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathCore.beginTime = when
        haloCore.add(breathCore, forKey: "finishBreathCore")

        let breathSoft = CABasicAnimation(keyPath: "opacity")
        breathSoft.fromValue = 0.70
        breathSoft.toValue = 0.42
        breathSoft.duration = 1.0
        breathSoft.autoreverses = true
        breathSoft.repeatCount = .infinity
        breathSoft.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathSoft.beginTime = when
        haloSoft.add(breathSoft, forKey: "finishBreathSoft")

        let breathSoftW = CABasicAnimation(keyPath: "lineWidth")
        breathSoftW.fromValue = 16
        breathSoftW.toValue = 18
        breathSoftW.duration = 1.0
        breathSoftW.autoreverses = true
        breathSoftW.repeatCount = .infinity
        breathSoftW.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathSoftW.beginTime = when
        haloSoft.add(breathSoftW, forKey: "finishBreathSoftW")

        let breathAura = CABasicAnimation(keyPath: "opacity")
        breathAura.fromValue = 0.30
        breathAura.toValue = 0.17
        breathAura.duration = 1.0
        breathAura.autoreverses = true
        breathAura.repeatCount = .infinity
        breathAura.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathAura.beginTime = when
        haloAura.add(breathAura, forKey: "finishBreathAura")

        // 虹彩：呼吸开始后，整环的颜色沿光谱缓缓漂移（20s 一圈）。
        // 起点是琥珀——与进行态同色，交接没有任何跳变；随后经珊瑚、玫瑰、
        // 紫罗兰、天蓝、青、薄荷、金回到琥珀，无限循环。
        // 三层同步换色（核心用混白版本，始终像"被光照亮"），
        // 每一段之间用 easeInEaseOut 衔接：颜色是"流动"的，
        // 整环在同一时刻只有一种色调——光环，而不是霓虹色带。
        let cycle: CFTimeInterval = 20
        func spectralAnim(_ keyPath: String, colors: [CGColor]) -> CAKeyframeAnimation {
            var vals = colors
            vals.append(colors[0])
            let a = CAKeyframeAnimation(keyPath: keyPath)
            a.values = vals
            var times: [NSNumber] = []
            for i in 0..<vals.count {
                times.append(NSNumber(value: Double(i) / Double(vals.count - 1)))
            }
            a.keyTimes = times
            a.duration = cycle
            a.repeatCount = .infinity
            a.beginTime = when
            a.timingFunctions = Array(
                repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                count: vals.count - 1
            )
            return a
        }
        for layer in [haloAura, haloSoft] {
            layer.add(spectralAnim("strokeColor", colors: Self.spectral),
                      forKey: "spectralStroke")
            layer.add(spectralAnim("shadowColor", colors: Self.spectral),
                      forKey: "spectralShadow")
        }
        haloCore.add(spectralAnim("strokeColor", colors: Self.spectralCore),
                     forKey: "spectralStroke")
        haloCore.add(spectralAnim("shadowColor", colors: Self.spectralCore),
                     forKey: "spectralShadow")
    }

    /// 关闭（取消或结束后点「关闭计时」）：安静淡出，不留残留
    func dismiss() {
        guard configured else { return }
        guard runningVisuals || finishedState else { return }
        let dur: CFTimeInterval = 0.3

        for (layer, key) in [(haloAura, "outA"), (haloSoft, "outS"),
                             (haloCore, "outC"), (trailSoft, "outT"),
                             (trailCore, "outK")] {
            let from = layer.presentation()?.opacity ?? layer.opacity
            // 定格此刻的虹彩色再撤动画：淡出期间颜色不跳回琥珀
            if let c = layer.presentation()?.strokeColor { layer.strokeColor = c }
            if let s = layer.presentation()?.shadowColor { layer.shadowColor = s }
            layer.removeAllAnimations()
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from
            a.toValue = 0
            a.duration = dur
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.opacity = 0
            layer.add(a, forKey: key)
        }
        orb.removeAllAnimations()
        let orbFrom = orb.presentation()?.opacity ?? orb.opacity
        let oa = CABasicAnimation(keyPath: "opacity")
        oa.fromValue = orbFrom
        oa.toValue = 0
        oa.duration = dur
        oa.fillMode = .forwards
        oa.isRemovedOnCompletion = false
        orb.opacity = 0
        orb.add(oa, forKey: "outO")

        runningVisuals = false
        finishedState = false
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.05) { [weak self] in
            self?.resetVisuals()
        }
    }
}
