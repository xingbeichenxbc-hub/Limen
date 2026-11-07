import Foundation
import Combine

enum CardMode {
    case main
    case settings
    case countdown
}

/// 倒计时的三个状态。
enum CountdownPhase {
    case idle      // 没有计时
    case running   // 光团正沿刘海前进
    case finished  // 时间到：发光路径吸气扩大、持续跃动，等弹窗来关
}

/// 功能开关的持久化键。
/// 前缀跟着 bundle id 走，换名字之后不会和旧版本互相覆盖。
enum PrefKey {
    static let music = "limen.enabled.music"
    static let airdrop = "limen.enabled.airdrop"
    static let battery = "limen.enabled.battery"
    static let style = "limen.glassStyle"
    static let countdownHistory = "limen.countdown.history"
}

final class NotchModel: ObservableObject {
    /// 带调试参数运行时不要写偏好。
    /// `--music-off`、`--settings` 这类只该影响这一次，
    /// 不然演示一次就把用户真正的开关改掉了。
    private static let persistsPreferences = !CommandLine.arguments.contains { $0.hasPrefix("--") }

    @Published var expanded = false
    @Published var dropping = false
    @Published var snapshot: NowPlayingSnapshot?
    @Published var permissionHint = false
    @Published var cardMode: CardMode = .main {
        didSet {
            // 离开倒计时页 = 打字会话结束：立刻交还键盘、面板不再做 key window。
            //
            // 不这样做的后果是透明 bug 的最后一个出口：输入框持焦时点 ♪/⏱/⚙
            // 切去别的页面，面板仍是 key window，而其他页面用的是玻璃底——
            // 玻璃材质在 key 窗口下会变得过于通透，整块卡片白字不可读。
            // 焦点必须在切页的那一刻清掉，而不是等面板收起。
            if cardMode != .countdown, countdownFieldFocused {
                countdownFieldFocused = false
                onCountdownFocusChange?(false)
            }
        }
    }

    /// 展开前把页面复位。
    ///
    /// 设置页是「进来改个东西」的临时去处，不该被记住：在设置页里移开鼠标，
    /// 面板收起，再移回来——那一刻用户要的是曲目，不是上次留下的那一页。
    ///
    /// 复位只挂在展开这一侧（而不是收起），因为收起可能被「刚移出去又马上
    /// 移回来」取消；展开才是每次必经的那一步。
    ///
    /// 唯一的例外是倒计时：计时进行中或已结束等待关闭时，展开要直接停在
    /// 倒计时页——弹窗里得能看到剩余的具体数字，这也是「完成后只能靠
    /// 呼出弹窗关闭」的入口。
    func prepareForExpand(forceSettings: Bool = false) {
        if forceSettings {
            cardMode = .settings
        } else {
            cardMode = countdownPhase == .idle ? .main : .countdown
        }
    }

    @Published var style: GlassStyle {
        didSet { Self.persist(style.rawValue, forKey: PrefKey.style) }
    }
    @Published var musicEnabled: Bool {
        didSet { Self.persist(musicEnabled, forKey: PrefKey.music) }
    }
    @Published var airDropEnabled: Bool {
        didSet { Self.persist(airDropEnabled, forKey: PrefKey.airdrop) }
    }

    /// 刘海边缘的电量光条。默认**关**：它是一条常驻的光，
    /// 默认打开就是在替用户做决定。想看的人自己去设置里开。
    @Published var batteryEnabled: Bool {
        didSet {
            Self.persist(batteryEnabled, forKey: PrefKey.battery)
            onBatteryToggled?(batteryEnabled)
        }
    }

    /// 开机自启的状态**不在** UserDefaults 里——唯一可信的来源是系统登录项。
    /// 每次展开面板时由 Controller 重新读一次，用户去系统设置里改过也能跟上。
    @Published var launchAtLogin = false

    /// 由 Controller 注入
    var onTogglePlay: (() -> Void)?
    var onOpenSource: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onQuit: (() -> Void)?
    var onMusicToggled: ((Bool) -> Void)?
    var onBatteryToggled: ((Bool) -> Void)?
    var onSetLaunchAtLogin: ((Bool) -> Void)?
    /// 权限被拒时，点提示行直接跳到「隐私与安全性 › 自动化」
    var onOpenAutomationSettings: (() -> Void)?

    // MARK: - 倒计时

    /// 输入上限（分钟）。超出即钳制到该值并让输入框闪红。
    static let maxCountdownMinutes = 1200

    @Published var countdownPhase: CountdownPhase = .idle
    /// 输入框的原文（只保留数字，最多 4 位）
    @Published var countdownInputText: String = ""
    /// 输入超出上限后被钳制，输入框短暂变红提示
    @Published var countdownClampFlash = false
    /// 剩余秒数（向上取整），弹窗显示用
    @Published var countdownRemaining: Int = 0
    /// 0–1，光团与发光路径的进度
    @Published var countdownProgress: Double = 0
    /// 最近用过的分钟数，最多记 6 个（持久化，输入页以胶囊形式回填）
    @Published var countdownHistory: [Int] = []
    /// 输入框当前是否持焦。收起面板时要主动清掉，否则键盘会被留住。
    @Published var countdownFieldFocused = false

    /// 本次计时的总时长（秒）与起点。起点用墙钟时间记，
    /// 机器睡眠一段时间也不会让倒计时停摆。
    var countdownTotal: TimeInterval = 0
    var countdownStart = Date.distantPast

    /// 由 Controller 注入：开始/停止计时后的动作（启动定时器、驱动光晕层）
    var onCountdownStarted: (() -> Void)?
    var onCountdownStopped: (() -> Void)?
    /// 输入框焦点变化 → Controller 决定面板能不能成为 key window
    var onCountdownFocusChange: ((Bool) -> Void)?

    enum CountdownInputResult {
        case empty
        case invalid
        case clamped(Int)
        case valid(Int)
    }

    static func evaluateCountdownInput(_ raw: String) -> CountdownInputResult {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        guard let v = Int(t) else { return .invalid }
        if v > maxCountdownMinutes { return .clamped(maxCountdownMinutes) }
        if v < 1 { return .invalid }
        return .valid(v)
    }

    var countdownCanStart: Bool {
        if case .valid = Self.evaluateCountdownInput(countdownInputText) { return true }
        return false
    }

    /// 输入框要不要标红：超出上限被钳制（短暂闪红），或当前内容不可用
    var countdownInputBad: Bool {
        if countdownClampFlash { return true }
        if case .invalid = Self.evaluateCountdownInput(countdownInputText) { return true }
        return false
    }

    /// 输入框的写入端：只留数字（≤4 位）。超出 1200 时直接给出最大值并闪红。
    func setCountdownInput(_ raw: String) {
        let digits = String(raw.filter { $0.isNumber }.prefix(4))
        if case .clamped(let m) = Self.evaluateCountdownInput(digits) {
            countdownInputText = String(m)
            countdownClampFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.countdownClampFlash = false
            }
        } else {
            countdownInputText = digits
            countdownClampFlash = false
        }
    }

    /// 点「开始」：进入计时，并把这次分钟数记进历史（去重、最近在前、最多 6 个）
    func startCountdown() {
        guard case .valid(let m) = Self.evaluateCountdownInput(countdownInputText) else { return }
        countdownTotal = TimeInterval(m * 60)
        countdownStart = Date()
        countdownRemaining = m * 60
        countdownProgress = 0
        countdownPhase = .running
        countdownFieldFocused = false
        rememberCountdown(m)
        onCountdownFocusChange?(false)
        onCountdownStarted?()
    }

    /// 结束计时（取消 / 关闭结束态）。回到空闲后，收起再展开就是主页面。
    func stopCountdown() {
        countdownPhase = .idle
        countdownProgress = 0
        countdownRemaining = 0
        countdownFieldFocused = false
        onCountdownFocusChange?(false)
        onCountdownStopped?()
        cardMode = .main
    }

    /// 由 Controller 的定时器驱动（0.1s 一拍，进度才顺滑）。
    /// 返回 true 表示这一拍恰好走完，发光路径该进「吸气扩大」了。
    func tickCountdown(now: Date = Date()) -> Bool {
        guard countdownPhase == .running else { return false }
        let elapsed = now.timeIntervalSince(countdownStart)
        let remaining = max(0, countdownTotal - elapsed)
        countdownProgress = countdownTotal > 0 ? min(1, elapsed / countdownTotal) : 1
        let secs = Int(ceil(remaining))
        if secs != countdownRemaining { countdownRemaining = secs }
        if remaining <= 0 {
            countdownPhase = .finished
            return true
        }
        return false
    }

    /// 记一次用过的分钟数：去重、最近在前、最多 6 个
    private func rememberCountdown(_ minutes: Int) {
        var h = countdownHistory.filter { $0 != minutes }
        h.insert(minutes, at: 0)
        if h.count > 6 { h = Array(h.prefix(6)) }
        countdownHistory = h
        Self.persist(h, forKey: PrefKey.countdownHistory)
    }

    init() {
        let d = UserDefaults.standard
        musicEnabled = d.object(forKey: PrefKey.music) as? Bool ?? true
        airDropEnabled = d.object(forKey: PrefKey.airdrop) as? Bool ?? true
        batteryEnabled = d.object(forKey: PrefKey.battery) as? Bool ?? false
        if let raw = d.string(forKey: PrefKey.style), let s = GlassStyle(rawValue: raw) {
            style = s
        } else {
            style = .liquidClear
        }
        launchAtLogin = LaunchAtLogin.isEnabled
        // 注意：plist 数组读回来的元素类型不固定——App 自己写入的是 NSNumber，
        // 外部工具（如 `defaults write`）可能写成字符串。两者都要能读，
        // 否则历史在重启后凭空消失（`as? [Int]` 桥接对两者都返回 nil）。
        let raw = d.array(forKey: PrefKey.countdownHistory) ?? []
        countdownHistory = raw.compactMap { elem -> Int? in
            if let n = elem as? NSNumber { return n.intValue }
            if let s = elem as? String, let v = Int(s) { return v }
            return nil
        }
        countdownHistory = Array(countdownHistory.prefix(6))
        if ProcessInfo.processInfo.environment["LIMEN_LOG"] == "1" {
            NSLog("[MODEL] history loaded: %@", countdownHistory.map(String.init).joined(separator: ","))
        }
    }

    /// 开关是「请求」，不是直接改值：真正能不能开要由系统说了算，
    /// 失败时 Controller 会把它改回真实状态并解释原因。
    func requestLaunchAtLogin(_ on: Bool) {
        onSetLaunchAtLogin?(on)
    }

    private static func persist(_ value: Any, forKey key: String) {
        guard persistsPreferences else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}
