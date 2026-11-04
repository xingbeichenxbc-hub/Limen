import Foundation
import Combine

enum CardMode {
    case main
    case settings
}

/// 功能开关的持久化键。
/// 前缀跟着 bundle id 走，换名字之后不会和旧版本互相覆盖。
enum PrefKey {
    static let music = "limen.enabled.music"
    static let airdrop = "limen.enabled.airdrop"
    static let style = "limen.glassStyle"
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
    @Published var cardMode: CardMode = .main

    /// 展开前把页面复位。
    ///
    /// 设置页是「进来改个东西」的临时去处，不该被记住：在设置页里移开鼠标，
    /// 面板收起，再移回来——那一刻用户要的是曲目，不是上次留下的那一页。
    ///
    /// 复位只挂在展开这一侧（而不是收起），因为收起可能被「刚移出去又马上
    /// 移回来」取消；展开才是每次必经的那一步。
    func prepareForExpand(forceSettings: Bool = false) {
        cardMode = forceSettings ? .settings : .main
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
    var onSetLaunchAtLogin: ((Bool) -> Void)?
    /// 权限被拒时，点提示行直接跳到「隐私与安全性 › 自动化」
    var onOpenAutomationSettings: (() -> Void)?

    init() {
        let d = UserDefaults.standard
        musicEnabled = d.object(forKey: PrefKey.music) as? Bool ?? true
        airDropEnabled = d.object(forKey: PrefKey.airdrop) as? Bool ?? true
        if let raw = d.string(forKey: PrefKey.style), let s = GlassStyle(rawValue: raw) {
            style = s
        } else {
            style = .liquidClear
        }
        launchAtLogin = LaunchAtLogin.isEnabled
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
