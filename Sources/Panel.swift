import AppKit
import SwiftUI

/// 永不抢焦点的浮动面板。
final class NotchPanel: NSPanel {
    /// 平时绝不能成为 key window（否则它会把键盘从别的 App 那里抢走）。
    /// 唯一的例外是倒计时输入框持焦时：只有 key window 能收到键盘输入。
    /// 焦点一离开立刻改回 false。
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

/// 拖放接收器。
///
/// 这里**不做命中测试**。早前用 `hitTest` 返回 nil 把窗口里不需要的部分
/// 让给下层，但那不成立：窗口 server 是按窗口投递事件的，视图层拒绝
/// 只是把事件丢掉，下层 App 收不到。真正的做法是让窗口在收起时
/// 只有刘海那么大——见 `NotchMetrics.windowFrame(expanded:)`。
/// 窗口边界就是热区边界，这块代码因此可以整段消失。
final class GateView: NSView {

    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    /// 承载 SwiftUI 内容的视图。
    ///
    /// 它按 `designSize`（展开态）排版，并由 `layout()` 顶边对齐地放进来。
    /// 窗口收起时会比内容矮，超出的部分留在窗口外被裁掉——
    /// 于是收起动画能完整播完，而屏幕上方那点窗口高度仍然只有刘海那么高。
    private weak var contentHost: NSView?
    var designSize: CGSize = .zero

    /// 刘海高度（窗口顶部这一段）。0 表示这块屏没有刘海。
    ///
    /// 有刘海时，投放必须落在刘海里面：光晕只在刘海边缘亮，若允许投到
    /// 下方卡片区，就成了「光说可以、其实已经出了目标」的错位反馈。
    var notchHeight: CGFloat = 0

    /// 是否只接受「拖进刘海」的投放
    var notchOnlyDrag = false

    /// 光晕当前是否亮着。拖进/拖出刘海要跟着亮/灭，
    /// 而不是等整个窗口的 entered/exited——窗口比刘海大。
    private var lit = false
    /// 本次拖拽是否已经成功投放（投放后不要再把光晕 fade 掉）
    private var dropped = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContent(_ view: NSView, designSize: CGSize) {
        contentHost = view
        self.designSize = designSize
        addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let host = contentHost else { return }
        let w = designSize.width > 0 ? designSize.width : bounds.width
        let h = designSize.height > 0 ? designSize.height : bounds.height
        // AppKit 原点在左下：让内容的**顶边**贴住窗口顶边。
        //
        // 左右和底边各留 `seamInset` 的透明余量。**这不是排版微调，是修一条黑边。**
        // 卡片形状的裁剪边如果正好压在窗口边界上，窗口服务在那一列物理像素上
        // 会把内容与窗口外的透明做一次合成，结果是一条近黑的缝——
        // 白底实测 lum 0.12（卡片 0.78、背景 0.87），深底 0.02。
        // 让裁剪发生在窗口**内部**，缝就没了；代价只是卡片窄 2pt（肉眼不可见）。
        let seam = GlassTuning.seamInset
        host.frame = CGRect(
            x: (bounds.width - w) / 2 + seam,
            y: bounds.height - h + seam,
            width: max(0, w - seam * 2),
            height: max(0, h - seam * 2)
        )
    }

    // MARK: - 拖放

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let pb = info.draggingPasteboard
        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pb.readObjects(forClasses: classes, options: options) as? [URL]) ?? []
    }

    /// 投放点是否在刘海里面。
    ///
    /// 窗口收起时整块就是刘海，任何点都算；展开时刘海只占顶上那一段，
    /// 下面的卡片区不算——那里已经出了光晕画的圈。
    ///
    /// 用 `containsInclusive` 而不是 `contains`：鼠标贴着屏幕顶边时
    /// y 恰好等于窗口顶边，`contains` 会判成 false，光晕当场灭掉。
    /// 手一甩到最上面就空操作，正是这个原因。
    static func pointInNotch(
        _ p: CGPoint, bounds: CGRect, notchHeight: CGFloat, notchOnly: Bool
    ) -> Bool {
        guard notchOnly, notchHeight > 0 else { return bounds.containsInclusive(p) }
        guard bounds.containsInclusive(p) else { return false }
        // 收起态窗口高度就等于刘海高度，此时整块都算
        if bounds.height <= notchHeight + 0.5 { return true }
        // 展开态：只有顶上那一段（刘海）算，卡片区返回 false
        return p.y >= bounds.height - notchHeight - 0.5
    }

    private func isInNotch(_ p: NSPoint) -> Bool {
        Self.pointInNotch(p, bounds: bounds, notchHeight: notchHeight, notchOnly: notchOnlyDrag)
    }

    private func point(_ info: NSDraggingInfo) -> NSPoint {
        convert(info.draggingLocation, from: nil)
    }

    private func accepts(_ info: NSDraggingInfo) -> Bool {
        guard !fileURLs(info).isEmpty else { return false }
        return isInNotch(point(info))
    }

    private func setLit(_ on: Bool) {
        guard lit != on else { return }
        lit = on
        if on { onDragEnter?() } else { onDragExit?() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = point(sender)
        let ok = accepts(sender)
        DragLog.write("entered ok=\(ok) files=\(fileURLs(sender).count) p=\(NSStringFromPoint(p)) bounds=\(NSStringFromRect(bounds)) notchH=\(notchHeight)")
        guard ok else { return [] }
        setLit(true)
        // 只要文件进了这个窗口就表示可以放；返回 [] 会让光标显示"禁止"符号
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = accepts(sender)
        // 诊断：只记贴近窗口顶边的几个点。
        // 「手甩到屏幕最上面光晕就没了」这类问题只能靠这条日志定位——
        // 看看到底是没收到事件（窗口外），还是收到了被判成不可投放。
        let p = point(sender)
        if p.y > bounds.height - 3 {
            DragLog.write("updated nearTop p=\(NSStringFromPoint(p)) h=\(bounds.height) ok=\(ok)")
        }
        // 拖出刘海（但仍在这个窗口里）时立刻收光，别让光晕替用户撒谎
        setLit(ok)
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DragLog.write("exited")
        setLit(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        DragLog.write("ended dropped=\(dropped)")
        // 投放成功时不要灭灯：那一下爆闪是收尾反馈，交给控制器放完
        if !dropped { setLit(false) }
        dropped = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        accepts(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        DragLog.write("drop files=\(urls.count) inNotch=\(isInNotch(point(sender)))")
        guard !urls.isEmpty, isInNotch(point(sender)) else { return false }
        dropped = true
        lit = false
        onDrop?(urls)
        return true
    }
}

/// 彩虹光晕的宿主视图。
///
/// 光晕比刘海宽出一圈，需要一块比面板更大的画布；但面板窗口一旦放大，
/// 收起时就会在刘海下方压出一条点不动的死区。
/// 所以光晕单独住一个 `ignoresMouseEvents = true` 的窗口：
/// 想画多大画多大，永远不参与事件路由。
final class GlowView: NSView {

    let glow = NotchGlowLayer()
    /// 倒计时的光团与发光路径。和彩虹光晕住在同一个不吃事件的窗口里，
    /// 层级比面板高，所以面板弹出也不会遮住它。
    let countdown = CountdownLayer()
    /// 电量光条。优先级排在最后：投送彩虹与倒计时出现时它整体淡出。
    let battery = BatteryLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(glow)
        layer?.addSublayer(battery)
        layer?.addSublayer(countdown)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        glow.frame = bounds
        battery.frame = bounds
        countdown.frame = bounds
    }
}

/// 拖放事件的落盘日志。
///
/// 拖拽路径没法用脚本模拟，只能真机拖一次、再回来看痕迹。
/// 闸门（收到了什么）和控制器（决定做什么）都往同一个文件写，
/// 出问题时能一眼看出卡在哪一层。
///
/// 一直开着：每次拖放只写一行，成本可以忽略，而"用户说没反应"时
/// 这份日志是唯一能复现现场的线索。
enum DragLog {
    private static let path = "/tmp/limen-drag.log"

    static func write(_ message: String) {
        NSLog("[drag] %@", message)
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, message)
        let url = URL(fileURLWithPath: path)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 拖入光晕

/// 贴着刘海左、下、右三条外边的一圈彩虹，用 Core Animation 直接绘制。
///
/// 为什么不用 SwiftUI：拖动会话期间系统在跑拖放循环，
/// SwiftUI 的显示刷新会被推迟——状态值改了但画面不跟着更新，
/// 表现出来就是「动画完全不生效」（用脚本触发时却正常）。
/// CA 动画提交后由渲染服务推进，与 app 主循环无关，
/// 这是唯一能保证拖拽过程中真的动起来的做法。
///
/// 一套效果适配两种节奏：
/// ```
/// 扫开(0.18s) → 呼吸+流光(按住多久就多久) → 释放脉冲(0.26s)
/// ```
/// 快速松手时中间那段被直接跳过。
final class NotchGlowLayer: CALayer {

    private struct Band {
        let gradient: CAGradientLayer
        let mask: CAShapeLayer
        let baseAlpha: Float
    }

    /// 六档横向渐变：两侧各是一个色区，底边是完整的彩虹带
    private static let rainbow: [CGColor] = [
        CGColor(srgbRed: 1.00, green: 0.37, blue: 0.56, alpha: 1),
        CGColor(srgbRed: 1.00, green: 0.69, blue: 0.24, alpha: 1),
        CGColor(srgbRed: 0.48, green: 0.88, blue: 0.54, alpha: 1),
        CGColor(srgbRed: 0.25, green: 0.82, blue: 0.79, alpha: 1),
        CGColor(srgbRed: 0.36, green: 0.55, blue: 0.94, alpha: 1),
        CGColor(srgbRed: 0.65, green: 0.55, blue: 0.98, alpha: 1)
    ]

    private var bands: [Band] = []
    private let streak = CAShapeLayer()
    private var ringPath: CGPath?
    private var breathing = false

    override init() {
        super.init()
        isHidden = true
        zPosition = 100          // 压在 SwiftUI 内容之上
        masksToBounds = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 构建

    func configure(metrics: NotchMetrics, size: CGSize) {
        frame = CGRect(origin: .zero, size: size)
        guard metrics.mode == .notch, size.width > 10, size.height > 10 else {
            isHidden = true
            ringPath = nil
            return
        }

        let path = Self.makeRingPath(size: size, metrics: metrics)
        ringPath = path

        // 三条带子：外弥散 / 过渡 / 本体
        // 线宽是按"压在边缘上"给的——一半埋进刘海，露在外面的是宽度的一半。
        // 所以数值比看起来要大：14/7/3 实际露出约 7 / 3.5 / 1.5。
        let spec: [(CGFloat, Float)] = [(14, 0.10), (7, 0.34), (3, 0.96)]
        if bands.count != spec.count {
            bands.forEach { $0.gradient.removeFromSuperlayer() }
            bands = spec.map { makeBand(width: $0.0, alpha: $0.1, path: path) }
        } else {
            for (i, b) in bands.enumerated() {
                b.gradient.frame = bounds
                b.mask.path = path
                b.mask.lineWidth = spec[i].0
            }
        }

        streak.path = path
        if streak.superlayer == nil {
            streak.fillColor = nil
            streak.strokeColor = NSColor.white.cgColor
            streak.lineWidth = 3.0
            streak.lineCap = .round
            streak.opacity = 0
            streak.shadowColor = NSColor.white.cgColor
            streak.shadowRadius = 3
            streak.shadowOpacity = 0.55
            streak.shadowOffset = .zero
            addSublayer(streak)
        }
    }

    private func makeBand(width: CGFloat, alpha: Float, path: CGPath) -> Band {
        let g = CAGradientLayer()
        g.frame = bounds
        g.colors = Self.rainbow
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.opacity = 0

        let m = CAShapeLayer()
        m.path = path
        m.fillColor = nil
        m.strokeColor = NSColor.black.cgColor   // mask 只看 alpha
        m.lineWidth = width
        m.lineCap = .round
        m.strokeStart = 0.5
        m.strokeEnd = 0.5
        g.mask = m

        addSublayer(g)
        return Band(gradient: g, mask: m, baseAlpha: alpha)
    }

    /// 贴着刘海三条外边的 U 形轨迹。
    /// 坐标原点在**左下**（CALayer 默认），起点左上 → 左下 → 底边 → 右下 → 右上，
    /// 所以 trim 的 0.5 正好落在底边中点。
    ///
    /// 轨迹中心线**压在刘海边缘上**，不向外偏移。
    /// 早前向外偏 1.5pt，但线只有 2pt 宽，内缘就停在边缘外 0.5pt 处，
    /// 于是一道比头发还细的背景从缝里漏出来；加上刘海左右边缘的计算值与
    /// 物理边缘还可能有 ±1pt 误差，左侧就明显偏了。
    /// 现在把线的一半埋进刘海（那里是物理挖空，画了也看不见），
    /// 内缘必然越界，任何方向 ±1pt 的误差都不会留缝。
    ///
    /// 倒计时的光团走的也是这条轮廓（左上角 → 右 → 上 → 右上角），共用。
    static func makeRingPath(size: CGSize, metrics: NotchMetrics) -> CGPath {
        let pad = metrics.glowPad
        let r = metrics.notchCornerRadius

        let left = pad
        let right = pad + metrics.notchWidth
        let top = size.height
        let bottom = top - metrics.notchHeight

        let p = CGMutablePath()
        p.move(to: CGPoint(x: left, y: top))
        p.addLine(to: CGPoint(x: left, y: bottom + r))
        p.addQuadCurve(
            to: CGPoint(x: left + r * 0.78, y: bottom),
            control: CGPoint(x: left + r * 0.06, y: bottom + r * 0.06)
        )
        p.addLine(to: CGPoint(x: right - r * 0.78, y: bottom))
        p.addQuadCurve(
            to: CGPoint(x: right, y: bottom + r),
            control: CGPoint(x: right - r * 0.06, y: bottom + r * 0.06)
        )
        p.addLine(to: CGPoint(x: right, y: top))
        return p
    }

    // MARK: 时序

    /// 拖入：扫开 → 呼吸 + 流光
    func appear() {
        guard ringPath != nil else { return }
        let dur: CFTimeInterval = 0.18
        isHidden = false
        breathing = false

        for b in bands {
            b.gradient.removeAllAnimations()
            b.mask.removeAllAnimations()
            b.mask.strokeStart = 0
            b.mask.strokeEnd = 1
            b.gradient.opacity = b.baseAlpha

            let s1 = CABasicAnimation(keyPath: "strokeStart")
            s1.fromValue = 0.5; s1.toValue = 0.0
            s1.duration = dur
            s1.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            b.mask.add(s1, forKey: "sweepStart")

            let s2 = CABasicAnimation(keyPath: "strokeEnd")
            s2.fromValue = 0.5; s2.toValue = 1.0
            s2.duration = dur
            s2.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            b.mask.add(s2, forKey: "sweepEnd")

            // 扫开时亮度从 0.45 线性升到 1，与持续段严格接上
            let rise = CABasicAnimation(keyPath: "opacity")
            rise.fromValue = b.baseAlpha * 0.45
            rise.toValue = b.baseAlpha
            rise.duration = dur
            b.gradient.add(rise, forKey: "rise")
        }

        // 扫开结束后开始呼吸，避免两段同时改 opacity 打架
        let when = CACurrentMediaTime() + dur
        for b in bands {
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = b.baseAlpha
            breath.toValue = b.baseAlpha * 0.62
            breath.duration = 0.75                    // autoreverse → 1.5s 周期
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breath.beginTime = when
            b.gradient.add(breath, forKey: "breath")
        }
        breathing = true

        startStreak()
    }

    /// 流光：一小段白光沿轨迹往返。
    /// 用往返而非绕圈，绕一圈会在轨迹顶端（屏幕边缘）留下一个跳变。
    private func startStreak() {
        guard ringPath != nil else { return }
        let seg: CGFloat = 0.17
        streak.removeAllAnimations()
        streak.strokeStart = 0
        streak.strokeEnd = seg

        let a1 = CABasicAnimation(keyPath: "strokeStart")
        a1.fromValue = 0.0; a1.toValue = 1.0 - seg
        let a2 = CABasicAnimation(keyPath: "strokeEnd")
        a2.fromValue = seg; a2.toValue = 1.0
        for a in [a1, a2] {
            a.duration = 2.6
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        streak.add(a1, forKey: "flowStart")
        streak.add(a2, forKey: "flowEnd")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 0.55
        fade.duration = 0.3
        streak.opacity = 0.55
        streak.add(fade, forKey: "streakIn")
    }

    /// 松手：冲到最亮再熄灭。
    /// 前 20% 保持峰值，之后线性衰减——比立刻衰减更有"打出来"的力度。
    func burst() {
        guard ringPath != nil, !isHidden else { return }
        breathing = false
        for b in bands {
            b.gradient.removeAnimation(forKey: "breath")
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [b.baseAlpha, b.baseAlpha * 1.0, 0]
            a.keyTimes = [0, 0.2, 1]
            a.duration = 0.26
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            b.gradient.opacity = 0
            b.gradient.add(a, forKey: "burst")
            b.mask.strokeStart = 0
            b.mask.strokeEnd = 1
        }
        let s = CASpringAnimation(keyPath: "opacity")
        s.fromValue = 0.55
        s.toValue = 0
        s.duration = 0.2
        s.fillMode = .forwards
        s.isRemovedOnCompletion = false
        streak.opacity = 0
        streak.add(s, forKey: "streakOut")
        scheduleHide(after: 0.28)
    }

    /// 拖出取消：安静淡出
    func fade() {
        guard ringPath != nil, !isHidden else { return }
        breathing = false
        let dur: CFTimeInterval = 0.16
        for b in bands {
            let from = (b.gradient.presentation()?.opacity ?? b.gradient.opacity)
            b.gradient.removeAllAnimations()
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from
            a.toValue = 0
            a.duration = dur
            b.gradient.opacity = 0
            b.gradient.add(a, forKey: "fade")
        }
        let sFrom = streak.presentation()?.opacity ?? streak.opacity
        streak.removeAllAnimations()
        let s = CABasicAnimation(keyPath: "opacity")
        s.fromValue = sFrom
        s.toValue = 0
        s.duration = dur
        streak.opacity = 0
        streak.add(s, forKey: "streakOut")
        scheduleHide(after: dur)
    }

    private func scheduleHide(after delay: TimeInterval) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideNow), object: nil)
        perform(#selector(hideNow), with: nil, afterDelay: delay)
    }

    @objc private func hideNow() {
        guard !breathing else { return }
        isHidden = true
        for b in bands {
            b.gradient.removeAllAnimations()
            b.mask.removeAllAnimations()
            b.gradient.opacity = 0
            b.mask.strokeStart = 0.5
            b.mask.strokeEnd = 0.5
        }
        streak.removeAllAnimations()
        streak.opacity = 0
    }
}
