import AppKit
import SwiftUI

final class NotchController: NSObject, NSSharingServiceDelegate {

    private let model = NotchModel()
    private let media = NowPlayingService()

    private var panel: NotchPanel?
    private var gate: GateView?
    /// 光晕单独一个不吃事件的窗口（只在刘海形态存在）
    private var glowWindow: NSWindow?
    private var glowView: GlowView?
    private var metrics: NotchMetrics
    private var pollTimer: Timer?
    private var expandJob: DispatchWorkItem?
    private var collapseJob: DispatchWorkItem?
    private var shrinkJob: DispatchWorkItem?

    /// 菜单栏形态下由 AppDelegate 注入。刘海形态下为 nil。
    private weak var menuBar: MenuBarController?

    /// 状态栏项的真实位置。它可能出现在**任意一块屏**上——
    /// 系统只把第三方状态栏项画在“当前活动显示器”的菜单栏里，
    /// 焦点换屏时图标会跟着搬家。
    private var rawIconRect: CGRect?
    private var iconScreen: NSScreen?
    /// 强制走菜单栏形态（用于在有刘海的机器上验证）
    private let forceMenuBar: Bool

    /// 演示用：`--settings` 让每次展开都停在设置页。
    /// 正常运行时这个值是 false，于是每次展开都从主页面开始。
    private let forceSettingsPage: Bool

    /// 展开前的等待时长。
    /// 菜单栏形态给 220ms：菜单栏是用户高频横穿的区域，鼠标从屏幕左上角
    /// 去关窗口一定会经过它。只是路过就不该弹面板。
    private var expandDelay: TimeInterval {
        metrics.mode == .menuBar ? 0.22 : 0.10
    }

    /// 本次展开的时刻，用来保证最短显示时长
    private var expandTime = Date.distantPast
    /// 最短显示时长：鼠标快速划过刘海时不要闪一下
    private let minVisibleDuration: TimeInterval = 0.30

    private let logEnabled = ProcessInfo.processInfo.environment["LIMEN_LOG"] == "1"

    /// 测试钩子：从文件读取"鼠标位置"（距屏幕顶部 pt）驱动状态机。
    /// 合成鼠标位置在部分环境下会被系统撤销，无法可靠模拟悬停。
    private let mouseFile: String?

    private func mousePoint() -> NSPoint {
        if let f = mouseFile,
           let text = try? String(contentsOfFile: f, encoding: .utf8) {
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
            if parts.count == 2, let x = Double(parts[0]), let yTop = Double(parts[1]),
               let screen = NSScreen.main {
                return NSPoint(x: x, y: screen.frame.maxY - yTop)
            }
        }
        return NSEvent.mouseLocation
    }

    private var airdropService: NSSharingService?

    private let demo: Bool
    private let dropDemo: Bool
    private let fake: Bool
    private let glassDemo: Bool
    private let lightDemo: Bool
    private var backdropWindow: NSWindow?

    override init() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // --force-menubar 用于在带刘海的机器上验证无刘海形态
        let forced = CommandLine.arguments.contains("--force-menubar")
        forceMenuBar = forced
        metrics = NotchMetrics.compute(for: screen, forceMenuBar: forced)
        demo = CommandLine.arguments.contains("--demo")
        dropDemo = CommandLine.arguments.contains("--drop-demo")
        fake = CommandLine.arguments.contains("--fake")
        glassDemo = CommandLine.arguments.contains("--glass-demo")
        lightDemo = CommandLine.arguments.contains("--light-demo")
        forceSettingsPage = CommandLine.arguments.contains("--settings")

        mouseFile = ProcessInfo.processInfo.environment["LIMEN_MOUSE_FILE"]
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--style=") }) {
            let raw = String(arg.dropFirst("--style=".count))
            if let s = GlassStyle(rawValue: raw) { model.style = s }
        }
        super.init()
    }

    // MARK: - 生命周期

    /// 几何自检：不开界面、不依赖拖拽，直接验证边界判定。
    ///
    /// 拖放路径没法用脚本模拟出真实的 dragging 会话，但「某个点收不收」
    /// 是纯函数，可以单独验。这里断言的都是曾经真出过问题的地方，
    /// 尤其是「鼠标贴着屏幕顶边」那一条。
    static func runSelfTest() -> Int {
        var failures = 0
        func check(_ name: String, _ got: Bool, _ want: Bool) {
            let ok = got == want
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(name)  got=\(got) want=\(want)")
        }

        // 收起态：窗口就是刘海 185×32
        let collapsed = CGRect(x: 0, y: 0, width: 185, height: 32)
        let c = { (x: CGFloat, y: CGFloat) in
            GateView.pointInNotch(CGPoint(x: x, y: y), bounds: collapsed,
                                  notchHeight: 32, notchOnly: true)
        }
        check("收起态·正中", c(92, 16), true)
        check("收起态·贴顶边 (y=32)", c(92, 32), true)
        check("收起态·贴底边 (y=0)", c(92, 0), true)
        check("收起态·贴左边 (x=0)", c(0, 16), true)
        check("收起态·贴右边 (x=185)", c(185, 16), true)
        check("收起态·左上角", c(0, 32), true)
        check("收起态·窗口下方 3pt（不该收）", c(92, -3), false)
        check("收起态·窗口左外 3pt（不该收）", c(-3, 16), false)

        // 展开态：窗口 165×129，只有顶上 32pt 是刘海
        let expanded = CGRect(x: 0, y: 0, width: 165, height: 129)
        let e = { (x: CGFloat, y: CGFloat) in
            GateView.pointInNotch(CGPoint(x: x, y: y), bounds: expanded,
                                  notchHeight: 32, notchOnly: true)
        }
        check("展开态·刘海顶边", e(82, 129), true)
        check("展开态·刘海中部", e(82, 113), true)
        check("展开态·刘海下沿 (y=97)", e(82, 97), true)
        check("展开态·卡片区（不该收）", e(82, 60), false)

        // 悬停热区：必须与窗口同一边界，且顶边可命中
        let hot = collapsed
        check("热区·贴顶边", hot.containsInclusive(CGPoint(x: 92, y: 32)), true)
        check("热区·窗口下方 4pt", hot.containsInclusive(CGPoint(x: 92, y: -4)), false)
        check("CGRect.contains 的顶边陷阱（应仍为 false）",
              collapsed.contains(CGPoint(x: 92, y: 32)), false)

        // 展开时页面复位：设置页是临时的，收起后再展开必须回到主页面。
        // 这条挡住的是「在设置页里移开鼠标、再移回来还停在设置页」。
        let m = NotchModel()
        m.cardMode = .settings
        m.prepareForExpand()
        check("展开前复位：设置页 → 主页面", m.cardMode == .main, true)
        m.cardMode = .settings
        m.prepareForExpand(forceSettings: true)
        check("演示开关仍可强制停在设置页", m.cardMode == .settings, true)

        print(failures == 0 ? "\n几何自检全部通过" : "\n几何自检 \(failures) 项失败")
        return failures
    }

    func start() {
        buildPanel()
        wire()
        if fake {
            // 演示曲目只在「音乐」开着时才显示；没显式关掉就当作开着，
            // 免得上一次 --music-off 留下的状态让截图变成一条提示。
            if !CommandLine.arguments.contains("--music-off") {
                model.musicEnabled = true
            }
            model.snapshot = NowPlayingSnapshot(
                title: "Clair de Lune",
                artist: "Claude Debussy",
                album: "Suite bergamasque",
                position: 92,
                duration: 302,
                isPlaying: true,
                artwork: nil
            )
        } else if model.musicEnabled {
            media.start()
        }
        startPolling()
        observeScreens()

        if demo || dropDemo || glassDemo || lightDemo
            || CommandLine.arguments.contains("--glow-demo")
            || CommandLine.arguments.contains("--glow-burst-demo") {
            if glassDemo { showGlassBackdrop(colorful: true) }
            if lightDemo { showGlassBackdrop(colorful: false) }
            if CommandLine.arguments.contains("--music-off") { model.musicEnabled = false }
            if CommandLine.arguments.contains("--airdrop-off") { model.airDropEnabled = false }
            let glowOnly = dropDemo
                || CommandLine.arguments.contains("--glow-demo")
                || CommandLine.arguments.contains("--glow-burst-demo")
            if glowOnly {
                // 只验证光晕，保持面板收起，光晕才看得清。
                // --drop-demo 也走这条：真实拖拽同样不展开面板。
            } else if metrics.mode == .menuBar {
                // 菜单栏形态要等状态栏窗口建立后才知道图标位置，
                // 太早展开会用到 fallback 坐标
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.expandNow()
                }
            } else {
                expandNow()
            }
            if dropDemo {
                model.dropping = true
                // 演示态：直接点亮光晕，便于截图与手感确认
                startGlow()
            }
            // 只点亮光晕、不展开面板，用于按时间点抓帧验证
            if CommandLine.arguments.contains("--glow-demo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.startGlow()
                }
            }
            // 走一遍「按住 → 松手」的完整时序（跳过真正的分享面板）
            if CommandLine.arguments.contains("--glow-burst-demo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.startGlow()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.burstGlow()
                }
            }
        }

        // 诊断钩子：假装正在拖文件，用来验证「拖拽期间绝不展开面板」。
        // 和 --drop-demo 的区别是**保留鼠标轮询**——那才是真实拖拽的处境：
        // 鼠标停在刘海热区里，轮询每 40ms 都在请求展开。
        if CommandLine.arguments.contains("--drag-hold") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.model.dropping = true
                self.startGlow()
                NSLog("[NB] drag-hold 开始（模拟拖拽中）")
            }
        }

        // 诊断钩子：不开界面也能验证登录项能不能登记。
        // `--login-item=on|off|status`，结果打印到 stdout。
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--login-item=") }) {
            let value = String(arg.dropFirst("--login-item=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let result: String?
                if value == "on" || value == "off" {
                    result = LaunchAtLogin.set(value == "on")
                } else {
                    result = nil
                }
                print("LOGIN_ITEM request=\(value) status=\(LaunchAtLogin.statusDescription) result=\(result ?? "ok")")
                fflush(stdout)
            }
        }
    }

    /// 演示用：在刘海下方放一块彩色背景，让玻璃的折射真的看得见
    private func showGlassBackdrop(colorful: Bool) {
        let w = metrics.notchWidth + 220
        let h: CGFloat = 230
        let frame = CGRect(
            x: metrics.notchRect.midX - w / 2,
            y: metrics.screen.frame.maxY - metrics.notchHeight - h,
            width: w,
            height: h
        )
        let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = true
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        win.contentView = GlassBackdropView(frame: NSRect(origin: .zero, size: frame.size), colorful: colorful)
        win.orderFrontRegardless()
        backdropWindow = win
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        expandJob?.cancel()
        collapseJob?.cancel()
        shrinkJob?.cancel()
        media.stop()
        panel?.orderOut(nil)
        glowWindow?.orderOut(nil)
    }

    // MARK: - 面板

    private func buildPanel() {
        let frame = metrics.windowFrame(expanded: model.expanded)

        let p = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = false

        let gate = GateView(frame: CGRect(origin: .zero, size: frame.size))
        gate.autoresizingMask = [.width, .height]
        gate.notchHeight = metrics.notchHeight
        gate.notchOnlyDrag = metrics.mode == .notch
        gate.onDragEnter = { [weak self] in
            guard let self else { return }
            DragLog.write("[ctl] enter mode=\(metrics.mode.rawValue) airDrop=\(model.airDropEnabled) screen=\(metrics.screen.localizedName)")
            guard self.model.airDropEnabled else { return }
            self.model.dropping = true
            // 拖入只点亮光晕，不展开面板。
            // 光晕本身就是"已瞄准、可以松手"的反馈，比弹一张卡片更省也更准。
            self.cancelExpand()
            self.cancelCollapse()
            // 万一面板已经开着（鼠标先悬停再开始拖），立刻收起：
            // 卡片顶部那层黑色渐隐正好压在光晕下沿外侧，会让光晕被啃掉一段。
            if self.model.expanded { self.collapse() }
            self.startGlow()
        }
        gate.onDragExit = { [weak self] in
            guard let self else { return }
            DragLog.write("[ctl] exit")
            self.model.dropping = false
            self.fadeOutGlow()
            if self.model.expanded { self.scheduleCollapse(after: 0.4) }
        }
        gate.onDrop = { [weak self] urls in
            guard let self else { return }
            DragLog.write("[ctl] drop files=\(urls.count) airDrop=\(model.airDropEnabled)")
            guard self.model.airDropEnabled else { return }
            self.sendAirDrop(urls)
        }

        let hosting = NSHostingView(rootView: RootView(model: model, metrics: metrics))
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true
        gate.setContent(hosting, designSize: metrics.designSize)

        p.contentView = gate
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()

        panel = p
        self.gate = gate

        buildGlowWindow()
    }

    /// 光晕独占一个不吃事件的窗口，这样它能画到刘海外面，
    /// 又不会在面板收起时压住下方的任何东西。
    private func buildGlowWindow() {
        guard metrics.mode == .notch else { return }
        let f = metrics.glowFrame

        let w = NSWindow(contentRect: f, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true      // 只负责画，不参与任何事件
        // 比面板**高一级**：光晕的下半边落在刘海外面，面板窗口一旦在那里，
        // 就会把它盖掉。这个窗口不吃事件，压在上面是安全的。
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none

        let v = GlowView(frame: CGRect(origin: .zero, size: f.size))
        v.autoresizingMask = [.width, .height]
        v.glow.configure(metrics: metrics, size: f.size)
        w.contentView = v
        w.orderFrontRegardless()

        glowWindow = w
        glowView = v
        if logEnabled {
            NSLog("[NB] glow window frame=%@ ignoresMouse=%@",
                  NSStringFromRect(f), String(w.ignoresMouseEvents))
        }
    }

    private func rebuild() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        gate = nil
        glowWindow?.orderOut(nil)
        glowWindow?.contentView = nil
        glowWindow = nil
        glowView = nil
        buildPanel()
    }

    // MARK: - 连接

    private func wire() {
        model.onTogglePlay = { [weak self] in self?.media.togglePlayPause() }
        model.onOpenSource = { [weak self] in self?.media.openSourceApp() }
        model.onNext = { [weak self] in self?.media.nextTrack() }
        model.onPrevious = { [weak self] in self?.media.previousTrack() }
        model.onQuit = { NSApp.terminate(nil) }

        model.onMusicToggled = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.media.start()
            } else {
                self.media.stop()
                self.model.snapshot = nil
                self.model.permissionHint = false
            }
        }

        media.onUpdate = { [weak self] snap in
            self?.model.snapshot = snap
        }
        media.onPermissionIssue = { [weak self] denied in self?.model.permissionHint = denied }

        model.onSetLaunchAtLogin = { [weak self] on in self?.applyLaunchAtLogin(on) }
        model.onOpenAutomationSettings = {
            // Ventura 之后一直是这个锚点；打不开也不会影响别的功能
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 悬停

    private func startPolling() {
        guard !demo && !dropDemo && !glassDemo && !lightDemo else { return }
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.pollMouse()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// 菜单栏形态：取图标真实位置。持续轮询，不能只读一次。
    ///
    /// 三个原因：
    /// 1. 状态栏窗口建立得比启动晚，`attach` 那次读到的必然是 nil；
    /// 2. 刚建立的一瞬间 frame 还可能是 `(0, -33)` 这种未定位的坏值；
    /// 3. 图标会随状态栏项增减、分辨率变化、**焦点换屏**而移动。
    private func syncMenuBarAnchor() {
        guard let f = menuBar?.iconRect, isPlausibleIconRect(f) else { return }
        let scr = screen(containing: f)

        if rawIconRect != f || iconScreen !== scr {
            rawIconRect = f
            iconScreen = scr
            if logEnabled {
                NSLog("[NB] icon=%@ screen=%@", NSStringFromRect(f), scr?.localizedName ?? "nil")
            }
        }

        // 只有当面板本身就在这块屏、且是菜单栏形态时，才把它当作锚点
        if metrics.mode == .menuBar, let scr, metrics.screen === scr,
           metrics.iconAnchor != f {
            metrics.iconAnchor = f
            applyWindowFrame()
        }
    }

    /// 图标应当位于某块屏幕的上半部、且尺寸合理。
    /// 未定位的窗口会返回 `(0, -33)` 这类值，位置在任何屏幕之外。
    private func isPlausibleIconRect(_ r: CGRect) -> Bool {
        guard r.width > 10, r.height > 10 else { return false }
        guard let s = screen(containing: r) else { return false }
        return r.minY > s.frame.midY && r.maxY <= s.frame.maxY + 4
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    private func screenUnderMouse() -> NSScreen? {
        let p = mousePoint()
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }

    /// 跟随鼠标切换面板所在屏与形态。
    ///
    /// 规则很简单：**面板跟着鼠标走**。
    /// - 鼠标在带刘海的屏 → 刘海形态，悬停刘海展开
    /// - 鼠标在无刘海的屏 → 菜单栏形态，悬停菜单栏图标展开
    ///
    /// 两者互不干扰：在有刘海的机器上，鼠标在刘海屏时图标不响应悬停
    ///（因为形态是 .notch，热区在刘海而不是图标），
    /// 这正是「有刘海时不弹菜单栏面板」的实现方式。
    private func refreshContext() {
        guard let ms = screenUnderMouse() else { return }
        let targetMode: BarMode = (ms.hasNotch && !forceMenuBar) ? .notch : .menuBar

        // 只有图标真的落在这块屏上，才拿它做锚点
        let anchor: CGRect? = (targetMode == .menuBar && iconScreen === ms) ? rawIconRect : nil

        let sameScreen = metrics.screen === ms
        let sameMode = metrics.mode == targetMode

        if sameScreen && sameMode {
            if metrics.iconAnchor != anchor {
                metrics.iconAnchor = anchor
                applyWindowFrame()
            }
            return
        }

        // 拖拽过程中不重建窗口，否则会中断拖放会话
        guard !model.dropping else { return }

        if sameMode {
            // 同一形态、换了一块屏：只移动窗口，不重建。
            // 重建会先 orderOut 再建新窗口，拖拽目标在那几毫秒里是消失的，
            // 光标正好在上面就会丢会话。移动窗口没有这个问题。
            metrics = NotchMetrics.compute(for: ms, forceMenuBar: forceMenuBar, iconAnchor: anchor)
            applyWindowFrame()
            applyGlowFrame()
            if logEnabled {
                NSLog("[NB] move mode=%@ screen=%@ panel=%@",
                      targetMode.rawValue, ms.localizedName,
                      NSStringFromRect(metrics.windowFrame(expanded: model.expanded)))
            }
            return
        }

        if model.expanded { collapse() }
        metrics = NotchMetrics.compute(for: ms, forceMenuBar: forceMenuBar, iconAnchor: anchor)
        rebuild()
        if logEnabled {
            NSLog("[NB] context mode=%@ screen=%@ anchor=%@ panel=%@",
                  targetMode.rawValue, ms.localizedName,
                  anchor.map { NSStringFromRect($0) } ?? "nil",
                  NSStringFromRect(metrics.panelFrame))
        }
    }

    private func pollMouse() {
        syncMenuBarAnchor()
        refreshContext()

        let p = mousePoint()

        // 拖着文件的时候绝不开面板。
        // 拖拽时鼠标必然停在刘海热区里，若照常展开，卡片顶部那层黑色渐隐
        // 正好压在光晕下沿外侧，彩虹的下边缘就被啃掉了。
        // 拖拽期间的唯一反馈是光晕本身。
        if model.dropping {
            cancelExpand()
            if model.expanded { collapse() }
            return
        }

        if model.expanded {
            if isInsideExpandedZone(p) {
                cancelCollapse()
                return
            }

            // 鼠标已经离开 —— 立刻收回。
            // 只留 0.08s 的判定余量（防边界抖动），
            // 再加一个最短显示时长，避免鼠标快速划过时闪一下。
            guard collapseJob == nil else { return }
            let shown = Date().timeIntervalSince(expandTime)
            let wait = max(0.08, minVisibleDuration - shown)
            if logEnabled {
                let f = metrics.panelFrame
                NSLog("[NB] leave mode=%@ mouse=(%.0f,%.0f) panel y=%.0f..%.0f wait=%.2f",
                      metrics.mode.rawValue, p.x, p.y, f.minY, f.maxY, wait)
            }
            scheduleCollapse(after: wait)
        } else {
            // containsInclusive：鼠标贴着屏幕顶边时也算在刘海内。
            // 用 contains 会在顶边这 1 个物理像素上判成"不在"，表现为
            // 手快速移到最上方时面板不弹、光晕熄灭。
            if hotZone().containsInclusive(p) {
                scheduleExpand()
            } else {
                cancelExpand()
            }
        }
    }

    /// 展开后「仍算在面板上」的判定区。
    ///
    /// 菜单栏形态必须额外把**图标本身**算进来：鼠标是从图标移进面板的，
    /// 若只认面板，鼠标刚离开图标、还没进入面板的那一瞬就会被判成「离开」，
    /// 面板立即收回、又被悬停重新展开 —— 来回闪。
    /// 面板顶边与菜单栏下沿重合，所以两者在 y 方向连续，合并后没有缝。
    private func isInsideExpandedZone(_ p: NSPoint) -> Bool {
        // hitFrame 就是展开后的窗口本身，和可见卡片一致。
        if metrics.hitFrame.insetBy(dx: -2, dy: -3).containsInclusive(p) { return true }
        // 刘海本身也算「还在上面」。
        //
        // 卡片只有 165 宽，刘海有 185 —— 左右各 10pt。鼠标停在刘海边缘时，
        // 展开的卡片根本没盖住它，于是「刚展开就判定离开」，闪一下才收回。
        // 在刘海区域里就保持展开，鼠标往下移进卡片是连续的，不会卡住。
        if metrics.mode == .notch, metrics.notchRect.containsInclusive(p) { return true }
        if metrics.mode == .menuBar, let icon = metrics.iconAnchor {
            return icon.insetBy(dx: -2, dy: -1).contains(p)
        }
        return false
    }

    /// 收起态接受悬停的区域。
    ///
    /// **必须完全落在窗口里面**：热区比窗口大出哪怕 1pt，那一圈就是
    /// 「拖拽已经离开窗口（dropping 被清掉）但鼠标还在热区」的缝，
    /// 面板会在拖文件时从缝里弹出来，正好盖住光晕下沿。
    ///
    /// 刘海是物理挖空、32pt 高，本身就是个够大的靶子，不需要额外放宽。
    private func hotZone() -> CGRect {
        if metrics.mode == .menuBar {
            guard let icon = metrics.iconAnchor else { return .null }
            return icon.insetBy(dx: -2, dy: -2)
        }
        return metrics.notchRect
    }

    private func scheduleExpand() {
        guard expandJob == nil, !model.expanded, !model.dropping else { return }
        let job = DispatchWorkItem { [weak self] in
            self?.expandJob = nil
            self?.expandNow()
        }
        expandJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay, execute: job)
    }

    private func cancelExpand() {
        expandJob?.cancel()
        expandJob = nil
    }

    private func expandNow() {
        cancelExpand()
        cancelCollapse()
        cancelShrink()
        guard !model.expanded, !model.dropping else { return }
        refreshMenuBarAnchor()
        expandTime = Date()

        // 每次展开都从主页面开始。
        //
        // 设置页是「进来改个东西」的临时去处，不该被记住：在设置页里移开鼠标，
        // 面板收起，再移回来——那一刻用户要的是曲目，不是上次那一页。
        //
        // 复位放在这里而不是 collapse() 里：collapse 可能被「移出去又马上移回来」
        // 取消，只有展开这一侧才是必经之路。而且此刻卡片高度还是 0，
        // 换页发生在看不见的时候，不会有内容突变的闪动。
        model.prepareForExpand(forceSettings: forceSettingsPage)

        // 先把窗口长到完整尺寸，再让内容开始动画。
        // 此刻卡片高度还是 0，所以"窗口变大"这一步看不见；
        // 反过来先动画后长窗口，卡片就会被窗口边缘裁掉。
        applyWindowFrame(expanded: true)
        model.expanded = true
        // 用户可能在「系统设置 › 登录项」里改过，展开时顺手对一次
        model.launchAtLogin = LaunchAtLogin.isEnabled
        if logEnabled { NSLog("[NB] EXPAND mode=%@", metrics.mode.rawValue) }
    }

    /// 菜单栏形态：每次展开前重读图标位置并挪动窗口。
    ///
    /// 不能在启动时算一次就固定 —— 菜单栏图标会因为状态栏项增减、
    /// 切换分辨率、插拔显示器而横向移动。位置错了会出现
    /// 「面板从半空中垂下来」的效果。
    private func refreshMenuBarAnchor() {
        guard metrics.mode == .menuBar else { return }
        if let f = menuBar?.iconRect, isPlausibleIconRect(f) {
            metrics.iconAnchor = f
        }
        applyWindowFrame()
    }

    /// 注入菜单栏控制器（无刘海设备上才需要）
    func attach(menuBar: MenuBarController) {
        self.menuBar = menuBar
        metrics.iconAnchor = menuBar.iconRect
        if logEnabled {
            NSLog("[NB] attach mode=%@ iconRect=%@ panel=%@",
                  metrics.mode.rawValue,
                  NSStringFromRect(menuBar.iconRect ?? .null),
                  NSStringFromRect(metrics.windowFrame(expanded: model.expanded)))
        }
        applyWindowFrame()
    }

    /// 菜单栏形态的右键菜单。
    /// 所有「低频功能」都集中在这里，单行条面板才能只剩一行。
    func makeMenuBarMenu() -> NSMenu {
        MenuBarController.makeMenu(
            style: model.style,
            onStyle: { [weak self] s in self?.model.style = s },
            launchAtLogin: model.launchAtLogin,
            onToggleLaunchAtLogin: { [weak self] in
                guard let self else { return }
                self.applyLaunchAtLogin(!self.model.launchAtLogin)
            },
            musicEnabled: model.musicEnabled,
            onToggleMusic: { [weak self] in
                guard let self else { return }
                self.model.musicEnabled.toggle()
                // didSet 只做持久化，真正的启停要显式通知
                self.model.onMusicToggled?(self.model.musicEnabled)
            },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    /// 左侧点击菜单栏图标。
    ///
    /// 返回 true 表示「已处理，不要再弹菜单」。
    /// - 刘海形态：图标不负责弹面板（刘海自己会弹），所以交给菜单
    /// - 菜单栏形态：图标就是入口，点一下切换面板
    func handleIconClick() -> Bool {
        guard metrics.mode == .menuBar, metrics.iconAnchor != nil else { return false }
        if model.expanded {
            cancelCollapse()
            collapse()
        } else {
            expandNow()
        }
        return true
    }

    // MARK: - 开机自启

    /// 真正动系统登录项的地方。开关不直接绑 `@Published`：
    /// 系统可能拒绝、也可能要求用户去设置里再确认，所以以执行后的
    /// 真实状态为准，把界面改回去。
    private func applyLaunchAtLogin(_ on: Bool) {
        let problem = LaunchAtLogin.set(on)
        model.launchAtLogin = LaunchAtLogin.isEnabled
        guard let problem else { return }
        presentLaunchAtLoginProblem(problem, offerSettings: LaunchAtLogin.needsApproval)
    }

    private func presentLaunchAtLoginProblem(_ text: String, offerSettings: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "开机启动没有开启"
        alert.informativeText = text
        alert.alertStyle = .informational
        if offerSettings {
            alert.addButton(withTitle: "打开登录项设置")
        }
        alert.addButton(withTitle: "好")

        let response = alert.runModal()
        if offerSettings, response == .alertFirstButtonReturn {
            LaunchAtLogin.openSettings()
        }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        guard collapseJob == nil, model.expanded else { return }
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseJob = nil
            if self.model.dropping { return }
            self.collapse()
        }
        collapseJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }

    private func cancelCollapse() {
        collapseJob?.cancel()
        collapseJob = nil
    }

    private func collapse() {
        guard model.expanded else { return }
        model.expanded = false
        // 窗口要等收起动画放完再缩。立刻缩会把还在动的卡片一刀切掉。
        scheduleShrink()
        if logEnabled { NSLog("[NB] COLLAPSE") }
    }

    // MARK: - 窗口尺寸

    /// 把窗口挪/缩到当前状态该有的大小。
    ///
    /// 收起时窗口只覆盖刘海（菜单栏形态退化成一条线），
    /// 这是「面板收起后不挡屏幕内容」的唯一可靠做法——
    /// 视图的 hitTest 拒绝只会把事件丢掉，不会转给下层。
    private func applyWindowFrame(expanded: Bool? = nil) {
        guard let panel else { return }
        // 窗口尺寸变了，刘海在窗口里的位置也变了，拖放目标区要跟着更新
        gate?.notchHeight = metrics.notchHeight
        gate?.notchOnlyDrag = metrics.mode == .notch
        let e = expanded ?? model.expanded
        let f = metrics.windowFrame(expanded: e)
        guard panel.frame != f else { return }
        panel.setFrame(f, display: false)
    }

    private func applyGlowFrame() {
        guard let glowWindow, let glowView else { return }
        let f = metrics.glowFrame
        glowWindow.setFrame(f, display: false)
        glowView.glow.configure(metrics: metrics, size: f.size)
    }

    private func scheduleShrink() {
        shrinkJob?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.shrinkJob = nil
            self.applyWindowFrame(expanded: false)
        }
        shrinkJob = job
        // 收起弹簧约 0.24s 响应、阻尼 0.95，0.45s 时已经彻底停住
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: job)
    }

    private func cancelShrink() {
        shrinkJob?.cancel()
        shrinkJob = nil
    }

    // MARK: - 拖入光晕
    //
    // 一套效果，两种节奏：
    //   扫开 → 呼吸+流光（按住多久就多久）→ 释放脉冲
    // 快速松手时"持续"被压成 0，整体就是一个短脉冲。
    //
    // 全部交给 Core Animation（见 NotchGlowLayer）。
    // 刻意不用 SwiftUI、也不自己跑 60fps 定时器：拖动会话期间系统在跑
    // 拖放循环，SwiftUI 的显示刷新会被推迟——状态值改了但画面不跟，
    // 表现出来就是「动画完全不生效」（用脚本触发时却正常）。
    // CA 动画提交后由渲染服务推进，与 app 主循环无关。

    private func startGlow() {
        guard metrics.mode == .notch else { return }
        glowView?.glow.appear()
        if logEnabled { NSLog("[NB] glow appear") }
    }

    /// 松手：冲到最亮再熄灭。
    private func burstGlow() {
        glowView?.glow.burst()
        if logEnabled { NSLog("[NB] glow burst") }
    }

    /// 拖出：立刻退场，不留残留
    private func fadeOutGlow() {
        glowView?.glow.fade()
        if logEnabled { NSLog("[NB] glow fade") }
    }


    // MARK: - 隔空投送

    /// 松手后的固定动作：只闪光，不展开面板。
    ///
    /// 拖入时面板全程保持收起——光晕本身就是「已接住」的完整反馈，
    /// 再弹一张卡片反而是多余的打扰。系统自己的隔空投送窗口会照常出现，
    /// 那是选投送对象必须的，不在这里干预。
    private func sendAirDrop(_ urls: [URL]) {
        cancelCollapse()
        model.dropping = false

        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            NSSound.beep()
            burstGlow()
            return
        }
        airdropService = service
        service.delegate = self

        // 光爆先走 100ms，再唤出系统的隔空投送窗口。
        // 同时开始的话，"闪"和系统窗口会糊成一团，先后才有先后感。
        burstGlow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
        }
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        NSLog("[Limen] AirDrop failed: \(error.localizedDescription)")
    }

    // MARK: - 屏幕变化

    private func observeScreens() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 跟着鼠标走：拔掉显示器后鼠标通常还在某块屏上，
            // 用 NSScreen.main 可能会把面板短暂放到别处。
            guard let screen = self.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first else { return }
            self.metrics = NotchMetrics.compute(for: screen, iconAnchor: self.menuBar?.iconRect)
            self.model.expanded = false
            self.rebuild()
        }
    }
}

/// 演示背景：高饱和色块 + 细白线，用来检验玻璃的模糊与折射
final class GlassBackdropView: NSView {
    private let colorful: Bool

    init(frame frameRect: NSRect, colorful: Bool) {
        self.colorful = colorful
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if !colorful {
            // 纯白：用来检查卡片的黑角有没有顶出刘海圆角
            NSColor.white.setFill()
            bounds.fill()
            return
        }
        let colors: [NSColor] = [
            .systemPink, .systemOrange, .systemYellow,
            .systemGreen, .systemTeal, .systemBlue, .systemPurple
        ]
        let n = colors.count
        let w = bounds.width / CGFloat(n)
        for i in 0..<n {
            colors[i].setFill()
            NSRect(x: CGFloat(i) * w, y: 0, width: w + 1, height: bounds.height).fill()
        }
        NSColor.white.withAlphaComponent(0.85).setFill()
        for i in 1..<10 {
            NSRect(x: bounds.width * CGFloat(i) / 10, y: 0, width: 2, height: bounds.height).fill()
        }
    }
}
