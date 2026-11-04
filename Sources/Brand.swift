import AppKit

/// 品牌资源：图标都来自应用包内的资源文件，不硬编码绘制。
///
/// - app 图标由 `tools/IconGen.swift` 从原始设计图生成 `AppIcon.icns`
/// - 菜单栏图标是一张**模板图**（纯黑 + alpha），交给系统按明暗自动着色，
///   所以浅色/深色菜单栏下都能正确显示，不需要准备两套
enum Brand {

    /// 菜单栏图标的逻辑尺寸（pt）。    /// 设计稿比例 565:288 ≈ 1.962，取 14pt 高 → 27.47，圆整到 27。
    /// 之前用过 35×18，比一般状态栏图标宽出一截，和旁边那些不成比例。
    /// 必须与 `IconGen.swift` 产出的尺寸严格一致，否则会被拉伸。
    static let menuBarIconSize = NSSize(width: 27, height: 14)

    /// 取菜单栏模板图标；找不到资源时返回 nil，调用方可自行退回系统符号
    ///
    /// 注意：`NSImage(contentsOf:)` 对散放的 PNG **不会**自动合并 @2x / @3x，
    /// 只会拿到 1x 那一张，在 Retina 屏上会被放大成模糊。
    /// 所以这里逐个把各倍率的位图 add 进同一个 NSImage，并统一逻辑尺寸。
    static func menuBarIcon() -> NSImage? {
        let names = ["MenuBarIcon", "MenuBarIcon@2x", "MenuBarIcon@3x"]
        let img = NSImage(size: menuBarIconSize)
        var loaded = 0

        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            // 逻辑尺寸统一，像素尺寸保持原样 → 系统按屏幕倍率挑最合适的一张
            rep.size = menuBarIconSize
            img.addRepresentation(rep)
            loaded += 1
        }

        guard loaded > 0 else { return nil }
        img.size = menuBarIconSize
        // 关键：模板图。系统会把不透明部分统一染成当前菜单栏前景色。
        img.isTemplate = true
        return img
    }
}

/// 菜单栏图标的承载者。**只在无刘海设备上启用**（见 `BarMode`）。
///
/// 交互分工：
/// - 左键 / 悬停 → 单行条面板（由 Controller 的鼠标轮询驱动，不经过这里）
/// - 右键 → 菜单：外观档位、音乐开关、退出
///
/// 功能栏那四个图标之所以能从这里消失，正是因为有了这个右键菜单。
///
/// 继承 NSObject 是必须的：`target/action` 走的是 Objective-C runtime，
/// 非 NSObject 的类型即使编译通过，selector 也发不出去，点击会毫无反应。
final class MenuBarController: NSObject {

    private var item: NSStatusItem?

    /// 左键点击。返回 true 表示已处理，不再弹菜单。
    var onLeftClick: (() -> Bool)?
    /// 右键时现构建菜单，这样每次打开都是最新的勾选状态
    var menuBuilder: (() -> NSMenu)?

    override init() {
        super.init()
    }
    /// 图标在屏幕上的位置。每次展开前读，因为菜单栏项的 x 会随着
    /// 状态栏项增减、分辨率变化而移动，不能在启动时写死。
    var iconRect: CGRect? {
        guard let w = item?.button?.window else { return nil }
        let f = w.frame
        guard f.width > 1, f.height > 1 else { return nil }
        return f
    }

    func activate() {
        guard item == nil else { return }

        let status = NSStatusBar.system.statusItem(
            withLength: Brand.menuBarIconSize.width + 8
        )
        guard let button = status.button else { return }

        if let icon = Brand.menuBarIcon() {
            button.image = icon
        } else {
            // 资源缺失时的兜底，保证功能不会因此完全不可用
            button.image = NSImage(systemSymbolName: "capsule.portrait",
                                   accessibilityDescription: "Limen")
        }
        button.imagePosition = .imageOnly
        button.toolTip = "Limen"
        button.setAccessibilityLabel("Limen")

        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        status.isVisible = true
        item = status
    }

    func deactivate() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
    }

    // MARK: - 点击

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else {
            if onLeftClick?() != true { showMenu() }
            return
        }
        let isRight = event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)

        if isRight {
            showMenu()
        } else if onLeftClick?() != true {
            // 刘海屏上图标不弹面板，左键也给菜单，否则这个图标就是死的
            showMenu()
        }
    }

    /// 右键弹菜单的惯用做法：**平时不给 statusItem 挂 menu**，
    /// 否则左键也会弹菜单。只在需要时临时挂上、点一下、立刻摘掉。
    private func showMenu() {
        guard let item, let menu = menuBuilder?() else { return }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: - 菜单构建

    static func makeMenu(
        style: GlassStyle,
        onStyle: @escaping (GlassStyle) -> Void,
        launchAtLogin: Bool,
        onToggleLaunchAtLogin: @escaping () -> Void,
        musicEnabled: Bool,
        onToggleMusic: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()

        let styleItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for s in GlassStyle.allCases {
            let mi = actionItem(s.shortTitle, { onStyle(s) })
            mi.state = (s == style) ? .on : .off
            styleMenu.addItem(mi)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let login = actionItem("登录时启动", onToggleLaunchAtLogin)
        login.state = launchAtLogin ? .on : .off
        menu.addItem(login)

        let music = actionItem("播放时控制音乐", onToggleMusic)
        music.state = musicEnabled ? .on : .off
        menu.addItem(music)

        menu.addItem(.separator())

        let quit = actionItem("退出 Limen", onQuit)
        quit.keyEquivalent = "q"
        menu.addItem(quit)

        return menu
    }

    private static func actionItem(_ title: String, _ act: @escaping () -> Void) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(MenuActionRelay.handle(_:)), keyEquivalent: "")
        mi.target = MenuActionRelay.shared
        mi.representedObject = act
        return mi
    }
}

/// 菜单项闭包转发（NSMenuItem 只能接 selector，需要一个中转对象）
final class MenuActionRelay: NSObject {
    static let shared = MenuActionRelay()

    @objc func handle(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }
}
