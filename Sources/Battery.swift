import AppKit
import IOKit.ps

// MARK: - 读数

/// 电池的当前读数。
///
/// 全部来自 IOKit 的电源信息——**不需要任何系统权限**，也不会弹授权框。
/// 这一点是刻意的：Limen 的权限清单只有「自动化」和「登录项」两项，
/// 为了一条电量光条去多要一项权限，不划算。
struct BatteryStatus: Equatable {

    /// 电量分档。阈值：40 及以上绿、20–40 偏黄绿、10–20 黄、10 及以下红。
    enum Band {
        case green
        case yellowGreen
        case yellow
        case red
    }

    /// 0–1。按整百分比量化，避免 0.4% 的抖动反复改光条宽度。
    var level: Double
    /// 正在充电（接了电源，且确实在往里充）
    var isCharging: Bool
    /// 接了电源（无论是否在充）
    var isOnAC: Bool
    /// 已经充满
    var isCharged: Bool

    var percent: Int { Int((level * 100).rounded()) }

    var band: Band {
        if percent >= 40 { return .green }
        if percent >= 20 { return .yellowGreen }
        if percent > 10 { return .yellow }
        return .red
    }

    /// 接了电源但不再往里充：满电，或到了「充电上限 / 电池健康管理」的停充点。
    /// 这两种情况视觉一致——白条，不脉冲。
    var isSettled: Bool { isOnAC && (!isCharging || isCharged) }

    /// 只有「正在往里充」才有脉冲。
    var isPulsing: Bool { isOnAC && isCharging && !isCharged }

    /// 光条上的颜色。接电源一律转白——白条本身就是「在充电」的第一层信息，
    /// 颜色（绿/黄/红）只在用电池时才需要被读出来。
    var isWhite: Bool { isOnAC }

    static func demo(percent: Int, charging: Bool = false, settled: Bool = false) -> BatteryStatus {
        BatteryStatus(
            level: Double(percent) / 100,
            isCharging: charging,
            isOnAC: charging || settled,
            isCharged: settled
        )
    }
}

/// 读电池 + 盯变化。
///
/// 两条来源：插拔电源由 IOKit 的通知源**立即**回调（用户要有即时反馈）；
/// 电量本身变化很慢，20 秒轮询一次就够，不必为此跑高频定时器。
final class BatteryMonitor {

    var onChange: ((BatteryStatus?) -> Void)?

    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var last: BatteryStatus?

    func start() {
        refresh()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { monitor.refresh() }
        }
        if let s = IOPSNotificationCreateRunLoopSource(callback, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
            source = s
        }

        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let s = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode)
            source = nil
        }
    }

    /// 读一次，**只有真的变了**才回调——否则每次轮询都会重设一遍动画。
    func refresh() {
        let now = Self.read()
        guard now != last else { return }
        last = now
        onChange?(now)
    }

    /// 返回 nil = 这台机器没有内置电池（台式机），界面上就什么都不画。
    static func read() -> BatteryStatus? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard desc[kIOPSIsPresentKey] as? Bool ?? true else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            guard maximum > 0 else { continue }

            let level = min(1, max(0, Double(current) / Double(maximum)))
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            // 有些机型/系统不报 Is Charged，按电量兜底
            let charged = desc[kIOPSIsChargedKey] as? Bool ?? (level >= 0.995)

            return BatteryStatus(level: level, isCharging: charging,
                                 isOnAC: onAC, isCharged: charged)
        }
        return nil
    }
}

// MARK: - 全屏检测

/// 判断某块屏现在是否被全屏应用占着。
///
/// 为什么不问 `NSApp.presentationOptions`：那只反映**自己**的状态，
/// 而这里要问的是别人开没开全屏。
///
/// 公开信息里最可靠的一条几何特征：**全屏窗口会顶到屏幕最上沿，把菜单栏一起盖掉**；
/// 普通的最大化窗口是从菜单栏下沿开始（这台机器上就是 y=33 那一档）。
/// 于是扫一遍窗口列表就够了——不需要辅助功能、不需要屏幕录制，
/// 而且读不到别的 App 的窗口标题也无所谓，只用到 bounds 和层级。
///
/// 另外两条约束：
/// - 层级必须是 0（普通窗口）。菜单栏、Dock、通知中心这些都在别的层级上，
///   它们不构成「全屏」。
/// - 必须排除自己。Limen 自己的窗口是无边框透明窗，几何上很接近全屏。
enum FullscreenProbe {

    static func isFullscreen(on screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        // CGWindowList 的坐标原点在**全局左上**，而 NSScreen.frame 是左下原点。
        // 用主屏高度把这块屏的顶边换算过去。
        guard let primary = NSScreen.screens.first else { return false }
        let topY = primary.frame.maxY - screen.frame.maxY
        let f = screen.frame

        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)

        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int, pid != ownPID else { continue }
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                           width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            // 顶到屏幕最上沿 + 覆盖整块屏 = 全屏
            if r.minY <= topY + 1,
               r.minX <= f.minX + 1,
               r.width >= f.width - 1,
               r.height >= f.height - 1 {
                return true
            }
        }
        return false
    }
}

// MARK: - 刘海边缘的电量光条

/// 贴着刘海轮廓的一条极细电量光条。
///
/// 三条设计约束，都是用户明确要的：
///
/// 1. **无感**。线宽只有彩虹光晕的七分之一、倒计时路径的一半：柔光 4.6pt、
///    核心 1.7pt，而这条轨迹的中心线压在刘海边缘上——一半埋进物理挖空，
///    露在外面的核心不到 1pt。它应该像玻璃边缘的一道反光，
///    不是一根进度条。
/// 2. **左上角是 0，右上角是 100**。轨迹 0 = 左上角、1 = 右上角，
///    光条画成 `[0, level]`：从左上角起笔，铺到哪个位置就是多少电；
///    100% 时刚好绕满一圈闭合。
/// 3. **优先级最低**。投送彩虹和倒计时都在这同一条轮廓上画光，
///    叠在一起只会互相糊掉，所以它们在时这条整体淡出（见 Controller）。
final class BatteryLayer: CALayer {

    // 苹果系统色系，压掉一点饱和度——细线上纯色会显刺眼。
    private static let green = CGColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    private static let yellowGreen = CGColor(srgbRed: 0.58, green: 0.81, blue: 0.24, alpha: 1)
    private static let yellow = CGColor(srgbRed: 1.00, green: 0.82, blue: 0.10, alpha: 1)
    private static let red = CGColor(srgbRed: 0.98, green: 0.33, blue: 0.29, alpha: 1)
    /// 充电白略带一点暖，纯白在浅色菜单栏上会显得生硬
    private static let white = CGColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1)
    private static let shade = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    static func color(for band: BatteryStatus.Band) -> CGColor {
        switch band {
        case .green: return green
        case .yellowGreen: return yellowGreen
        case .yellow: return yellow
        case .red: return red
        }
    }

    /// 整条光条装在一个组里，显隐只改这一层的 opacity——
    /// 三条子层各自还有自己的动画（填充、颜色、脉冲），
    /// 分开控制才不会互相打断。
    private let group = CALayer()
    private let barSoft = CAShapeLayer()
    private let barCore = CAShapeLayer()
    private let pulseSoft = CAShapeLayer()
    private let pulseCore = CAShapeLayer()

    private var configured = false
    /// 当前已填充到的弧长位置（0 = 左上角，1 = 右上角）
    private var fillEnd: CGFloat = 0
    private var groupTarget: Float = 0
    private var pulsing = false
    private var pulseHi: CGFloat = 0
    /// 脉冲动画的起跑时刻，用来在长度变化时把相位接上
    private var pulseStartedAt: CFTimeInterval = 0
    private var traceTimer: Timer?
    /// 一次完整行程的时长。生长占 0.18、行进 0.64、收尾 0.18，
    /// 所以行进速度约等于「整条走完 1.9 秒」，和早先 2.4 秒一段的手感接近。
    ///
    /// `LIMEN_PULSE_SLOW=10` 可把行程拉长 10 倍，用来逐帧看生长与收尾的形状——
    /// `screencapture` 单帧要 130ms，正常速度下这两段只有 0.5 秒，抓不到。
    private static let pulseDuration: CFTimeInterval = {        let scale = ProcessInfo.processInfo.environment["LIMEN_PULSE_SLOW"]
            .flatMap(Double.init) ?? 1
        return 3.0 * max(0.1, scale)
    }()
    private var current: BatteryStatus?
    /// 呼吸：底噪亮度与周期。一条完全不动的细线会被读成渲染残留，
    /// 轻轻起伏才像「还在工作」。
    private var breathCoreBase: Float = 0
    private var breathSoftBase: Float = 0
    private var breathCoreLow: Float = 0.70
    private var breathing = false

    override init() {
        super.init()
        zPosition = 50          // 低于倒计时(60)，更低于是拖拽彩虹(100)
        masksToBounds = false
        build()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        traceTimer?.invalidate()
    }

    private func build() {
        group.frame = bounds
        group.opacity = 0
        group.masksToBounds = false
        addSublayer(group)

        for layer in [barSoft, barCore, pulseSoft, pulseCore] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.strokeStart = 0
            layer.strokeEnd = 0
            layer.shadowOffset = .zero
            layer.opacity = 0
            group.addSublayer(layer)
        }

        barSoft.lineWidth = 4.6
        barCore.lineWidth = 1.7

        // 脉冲比本体略宽一点点，靠亮度和影子读出「在流动」，
        // 而不是靠变粗——变粗就抢视野了。
        pulseSoft.lineWidth = 6.0
        pulseCore.lineWidth = 2.4
        pulseSoft.strokeColor = Self.white
        pulseCore.strokeColor = Self.white
        pulseSoft.shadowColor = Self.white
        pulseSoft.shadowRadius = 4
        pulseSoft.shadowOpacity = 0.5
        pulseCore.shadowColor = Self.white
        pulseCore.shadowRadius = 4
        pulseCore.shadowOpacity = 0.75
    }

    // MARK: 配置

    func configure(metrics: NotchMetrics, size: CGSize) {
        frame = CGRect(origin: .zero, size: size)
        guard metrics.mode == .notch, size.width > 10, size.height > 10 else {
            configured = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            group.opacity = 0
            CATransaction.commit()
            groupTarget = 0
            return
        }

        let path = NotchGlowLayer.makeRingPath(size: size, metrics: metrics)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        group.frame = CGRect(origin: .zero, size: size)
        for layer in [barSoft, barCore, pulseSoft, pulseCore] {
            layer.path = path
            layer.removeAllAnimations()
            layer.strokeStart = 0
            layer.strokeEnd = 0
            layer.opacity = 0
        }
        group.opacity = 0
        CATransaction.commit()

        configured = true
        groupTarget = 0
        pulsing = false
        fillEnd = 0
        // 换屏/重建后由 Controller 立刻补一次 apply()，这里不自己猜状态
    }

    // MARK: 应用状态

    /// - Parameters:
    ///   - status: nil（没有电池 / 没读到）就整条淡出
    ///   - visible: 优先级判定结果，由 Controller 算
    func apply(_ status: BatteryStatus?, visible: Bool, animated: Bool) {
        guard configured else { return }
        guard visible, let st = status else {
            stopPulse(animated: animated)
            stopBreath()
            fade(to: 0, animated: animated)
            return
        }

        current = st

        let isWhite = st.isWhite
        let color = isWhite ? Self.white : Self.color(for: st.band)
        // 白条在浅色菜单栏上本来就不显，靠一圈很淡的暗影把轮廓交代出来；
        // 充电中把本体压暗、把脉冲提亮，脉冲才读得出来
        let coreAlpha: Float = isWhite ? (st.isPulsing ? 0.42 : 0.46) : 0.60
        let softAlpha: Float = isWhite ? 0.12 : 0.15
        // 白色底子亮，呼吸要收着；彩色细线可以动得明显一点
        let breathLow: Float = isWhite ? 0.72 : 0.62

        setFill(st.level)
        setColor(color, white: isWhite, animated: animated)
        setAlpha(core: coreAlpha, soft: softAlpha, lowFactor: breathLow, animated: animated)

        if st.isPulsing {
            startPulse(level: CGFloat(min(max(st.level, 0), 1)), animated: animated)
        } else {
            stopPulse(animated: animated)
        }

        fade(to: 1, animated: animated)
    }

    private func setFill(_ level: Double) {
        let l = CGFloat(min(max(level, 0), 1))
        guard abs(l - fillEnd) > 0.0005 else { return }
        fillEnd = l
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [barSoft, barCore] {
            // 刻度就是轨迹本身的走向：0 = 左上角，1 = 右上角。
            // 所以「画到哪」直接等于「有多少电」——100% 时刚好绕满一圈闭合，
            // 掉电时右端往左上退。
            layer.strokeStart = 0
            layer.strokeEnd = l
        }
        CATransaction.commit()
    }

    private func setColor(_ color: CGColor, white: Bool, animated: Bool) {
        let shadow = white ? Self.shade : color
        // 白条在浅色菜单栏上几乎看不见——那圈很淡的暗影就是把轮廓交代出来的东西。
        // 深色桌面上它埋在刘海里，等于不存在，所以不会显得脏。
        let shadowOpacity: Float = white ? 0.50 : 0.30

        func commit() {
            barSoft.strokeColor = color
            barSoft.shadowColor = shadow
            barSoft.shadowRadius = white ? 4.5 : 5
            barSoft.shadowOpacity = white ? 0.20 : 0.28
            barCore.strokeColor = color
            barCore.shadowColor = shadow
            barCore.shadowRadius = white ? 1.8 : 3
            barCore.shadowOpacity = shadowOpacity
        }

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            commit()
            CATransaction.commit()
            return
        }

        // 跨过阈值时颜色渐过去，不「啪」地换——这条光条的气质就是安静
        let dur: CFTimeInterval = 0.55
        func shift(_ layer: CAShapeLayer, _ keyPath: String,
                   from: CGColor?, to: CGColor) {
            let a = CABasicAnimation(keyPath: keyPath)
            a.fromValue = from ?? to
            a.toValue = to
            a.duration = dur
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: keyPath)
        }
        shift(barSoft, "strokeColor", from: barSoft.presentation()?.strokeColor, to: color)
        shift(barCore, "strokeColor", from: barCore.presentation()?.strokeColor, to: color)
        shift(barSoft, "shadowColor", from: barSoft.presentation()?.shadowColor, to: shadow)
        shift(barCore, "shadowColor", from: barCore.presentation()?.shadowColor, to: shadow)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        commit()
        CATransaction.commit()
    }

    /// 设定亮度，并让它**一直轻轻呼吸**。
    ///
    /// 呼吸不是为了好看，是为了「它没坏」：一条完全静止的细线贴在刘海边缘，
    /// 第一眼会被读成渲染残留或者屏幕出了问题。亮度以 4 秒一个来回起伏
    /// ±25%，幅度小到不抢视野，但足以让人看出这是活的。
    private func setAlpha(core: Float, soft: Float, lowFactor: Float, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barCore.opacity = core
        barSoft.opacity = soft
        CATransaction.commit()

        // 亮度变化本身也做一次 0.4s 过渡（换档、插拔电源时用得上）
        if animated {
            for layer in [barCore, barSoft] {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = layer.presentation()?.opacity ?? layer.opacity
                a.toValue = layer.opacity
                a.duration = 0.4
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(a, forKey: "alpha")
            }
        }

        // 呼吸排在亮度过渡之后起拍，两个动画不抢同一个属性
        startBreath(core: core, soft: soft, lowFactor: lowFactor,
                    after: animated ? 0.45 : 0)
    }

    private func startBreath(core: Float, soft: Float, lowFactor: Float, after delay: CFTimeInterval) {
        // 亮度真变了才重起：每次都重设会打断相位，看起来像卡顿
        if breathing,
           abs(breathCoreBase - core) < 0.001,
           abs(breathSoftBase - soft) < 0.001,
           abs(breathCoreLow - lowFactor) < 0.001 {
            return
        }
        breathCoreBase = core
        breathSoftBase = soft
        breathCoreLow = lowFactor
        breathing = true

        let begin = CACurrentMediaTime() + delay
        // 核心起伏比柔光多一点：核心是"亮的那条"，它动了才看得出呼吸
        for (layer, base, low) in [(barCore, core, lowFactor),
                                   (barSoft, soft, min(0.92, lowFactor + 0.14))] {
            layer.removeAnimation(forKey: "breath")
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = base
            a.toValue = base * low
            a.duration = 2.0                       // autoreverse → 4s 一个来回
            a.autoreverses = true
            a.repeatCount = .infinity
            a.beginTime = begin
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: "breath")
        }
    }

    private func stopBreath() {
        guard breathing else { return }
        breathing = false
        barCore.removeAnimation(forKey: "breath")
        barSoft.removeAnimation(forKey: "breath")
    }

    private func fade(to target: Float, animated: Bool) {
        guard groupTarget != target else { return }
        groupTarget = target
        let from = group.presentation()?.opacity ?? group.opacity
        group.removeAnimation(forKey: "fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        group.opacity = target
        CATransaction.commit()
        guard animated else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = target
        a.duration = target > 0 ? 0.45 : 0.30
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.add(a, forKey: "fade")
    }

    // MARK: 充电脉冲

    /// 一段白光沿光条**从左往右**走。**只在已填充的那一段里走**——
    /// 跑到没电量的空段上，就等于在骗人。
    ///
    /// 起点固定在左上角（0），终点是当前电量。于是电量越多，光跑的路越长，
    /// 方向和「充电在补进去」这件事一致。
    ///
    /// 一次行程分三步，而不是一段固定长的光硬生生平移过去：
    ///
    /// ```
    /// 0 ──0.18── 由点长成一段（左端不动，右端伸展）
    ///    ──0.82── 定长匀速行进（两端同速，长度不变）
    ///    ──1.00── 收进右端（右端不动，左端追上来）
    /// ```
    ///
    /// 头尾都从「零长度」出发，所以它在左端是**长出来**的、在右端是**收进去**的，
    /// 不会出现「整段突然出现 / 到点瞬间消失」那种一闪。
    /// 亮度同步做一次 0 → 满 → 0 的包络，两头再柔一点。
    private func startPulse(level: CGFloat, animated: Bool) {
        let lo: CGFloat = 0
        let hi = min(max(level, 0), 1)
        let span = hi - lo
        // 太短的一段跑起来只会原地闪，索性不跑
        guard span > 0.05 else {
            stopPulse(animated: animated)
            return
        }
        // 电量没变就别重启：重启会让脉冲在途中跳一下
        if pulsing, abs(pulseHi - hi) < 0.004 { return }

        // 脉冲最长占整段的四成：段短时自动收窄，免得「生长」和「收尾」
        // 把中间那段匀速行程挤没。
        // `LIMEN_PULSE_SEG` 只是调试用（放大光段才看得清生长/收尾的形状）。
        let maxSeg = ProcessInfo.processInfo.environment["LIMEN_PULSE_SEG"]
            .flatMap(Double.init).map { CGFloat($0) } ?? 0.10
        let seg = min(maxSeg, span * 0.42)
        let grow: CGFloat = 0.18          // 长到这么长，开始匀速走
        let shrink: CGFloat = 0.82        // 到这里开始收进右端

        // 电量涨了要按新长度重排动画，但相位得接上——
        // 每涨 1% 就让光跳回左端重来，比原来那点割裂还难受
        let wasPulsing = pulsing
        let now = CACurrentMediaTime()
        let phase: CFTimeInterval
        if wasPulsing {
            phase = (now - pulseStartedAt)
                .truncatingRemainder(dividingBy: Self.pulseDuration)
        } else {
            phase = 0
            pulseStartedAt = now
        }
        pulseHi = hi
        pulsing = true

        let times: [NSNumber] = [0, NSNumber(value: Double(grow)),
                                 NSNumber(value: Double(shrink)), 1]
        let startValues: [CGFloat] = [lo, lo, hi - seg, hi]
        let endValues: [CGFloat] = [lo, lo + seg, hi, hi]
        let fadeTimes: [NSNumber] = [
            0,
            NSNumber(value: Double(grow) * 0.9),
            NSNumber(value: Double(shrink) + (1 - Double(shrink)) * 0.45),
            1,
        ]

        for (layer, alpha) in [(pulseSoft, Float(0.15)), (pulseCore, Float(0.80))] {
            layer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.strokeStart = lo
            layer.strokeEnd = lo
            layer.opacity = 0
            CATransaction.commit()

            let s = CAKeyframeAnimation(keyPath: "strokeStart")
            s.values = startValues
            s.keyTimes = times
            s.timingFunctions = [
                CAMediaTimingFunction(name: .linear),        // 左端钉住不动
                CAMediaTimingFunction(name: .linear),        // 匀速行进
                CAMediaTimingFunction(name: .easeInEaseOut), // 追上去，收进右端
            ]

            let e = CAKeyframeAnimation(keyPath: "strokeEnd")
            e.values = endValues
            e.keyTimes = times
            e.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut), // 由点慢慢长成一段
                CAMediaTimingFunction(name: .linear),        // 与 s 同速，长度不变
                CAMediaTimingFunction(name: .linear),        // 右端钉住不动
            ]

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, alpha, alpha, 0]
            fade.keyTimes = fadeTimes
            fade.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]

            for a in [s, e, fade] as [CAAnimation] {
                a.duration = Self.pulseDuration
                a.repeatCount = .infinity
                a.beginTime = now - phase
                a.isRemovedOnCompletion = false
            }
            layer.add(s, forKey: "pulseStart")
            layer.add(e, forKey: "pulseEnd")
            layer.add(fade, forKey: "pulseFade")
        }

        if ProcessInfo.processInfo.environment["LIMEN_PULSE_TRACE"] == "1" {
            startTrace()
        }
    }

    /// 调试：把脉冲此刻的 presentation 值打出来。
    ///
    /// 壁纸是亮的、刘海边缘又压在屏幕顶边，截图里那条白线几乎无法用像素判定形状
    /// （呼吸、背景、圆角热斑全都混在一起）。要看「它到底是不是从零长起来的」，
    /// 直接读动画的当前值比读像素可靠得多。
    private func startTrace() {
        traceTimer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.pulseCore.presentation() else { return }
            NSLog("[PULSE] start=%.3f end=%.3f w=%.3f op=%.2f",
                  p.strokeStart, p.strokeEnd, p.strokeEnd - p.strokeStart, p.opacity)
        }
        RunLoop.main.add(t, forMode: .common)
        traceTimer = t
    }

    private func stopPulse(animated: Bool) {
        guard pulsing else { return }
        pulsing = false
        for layer in [pulseSoft, pulseCore] {
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.strokeStart = 0
            layer.strokeEnd = 0
            layer.opacity = 0
            CATransaction.commit()
            guard animated else { continue }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from
            a.toValue = 0
            a.duration = 0.25
            layer.add(a, forKey: "pulseOut")
        }
    }
}
