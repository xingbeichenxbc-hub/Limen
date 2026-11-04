import AppKit

@main
struct LimenMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = AppDelegate.shared
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private var controller: NotchController?
    private let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏图标**始终存在**，两种情况都建。
        //
        // 系统只会把第三方状态栏项画在「当前活动显示器」的菜单栏里，
        // 焦点换屏时图标会自己搬家。所以这里不需要按屏幕去建／拆，
        // 建一次就够，位置由 Controller 每次悬停前重新读取。
        //
        // 至于「有刘海时不弹面板」：那是 Controller 里按鼠标所在屏
        // 切换形态实现的——在刘海屏上形态是 .notch，热区是刘海而不是图标。
        menuBar.onLeftClick = { [weak self] in
            self?.controller?.handleIconClick() ?? false
        }
        menuBar.menuBuilder = { [weak self] in
            self?.controller?.makeMenuBarMenu() ?? NSMenu()
        }
        menuBar.activate()

        boot()
    }

    /// 等第一块屏幕就绪再建面板。
    ///
    /// 合盖、没有外接屏、刚好又开机自启时，启动的那一刻可能一块屏都没有。
    /// 这时去取 `NSScreen.screens[0]` 会越界崩溃——一个后台小组件崩溃是
    /// 完全无声的，用户只会发现「它没启动」。所以这里等屏幕出现再建。
    private func boot() {
        guard controller == nil else { return }

        // 纯逻辑自检，不需要屏幕也不需要窗口，最先跑
        if CommandLine.arguments.contains("--selftest") {
            let a = NotchController.runSelfTest()
            let b = NowPlayingService.runSelfTest()
            exit(a + b == 0 ? 0 : 1)
        }

        guard NSScreen.screens.first != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.boot()
            }
            return
        }

        let c = NotchController()
        controller = c
        c.start()
        c.attach(menuBar: menuBar)
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBar.deactivate()
        controller?.stop()
    }
}
