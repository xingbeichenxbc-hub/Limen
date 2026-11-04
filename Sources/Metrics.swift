import AppKit

/// 两种存在形态。
///
/// - `notch`：机器有刘海。面板从缺口下方长出来，宽度贴合刘海平直底边。
/// - `menuBar`：无刘海（外接屏、无刘海机型、合盖使用）。驻留在菜单栏，
///   面板从图标正下方垂下来。高度只有 27pt——因为菜单栏下方的每一 pt
///   都会实打实盖住窗口内容，这和刘海形态完全不同。
enum BarMode: String {
    case notch
    case menuBar
}

extension CGRect {

    /// 把边界算在内的包含判定。
    ///
    /// `CGRect.contains` 在 maxX / maxY 上返回 **false**。鼠标贴着屏幕顶边时，
    /// 它的 y 恰好等于刘海窗口的顶边，于是「在刘海里」被判成「不在」：
    /// 悬停不展开、拖拽时 `accepts` 变假、光晕跟着灭——表现就是
    /// 「手一甩到屏幕最上面，彩虹就没了」。
    ///
    /// 容差 0.5pt（2x 屏上一个物理像素）：视觉上还在里面，判定就该算在里面。
    func containsInclusive(_ p: CGPoint, epsilon: CGFloat = 0.5) -> Bool {
        p.x >= minX - epsilon && p.x <= maxX + epsilon
            && p.y >= minY - epsilon && p.y <= maxY + epsilon
    }
}

extension NSScreen {

    /// 是否有刘海。
    ///
    /// 不靠机型字符串判断——那对外接屏、合盖、以后的新机型全都不成立。
    /// 用几何特征：有刘海时系统会把顶部两侧划成 `auxiliaryTopLeftArea` /
    /// `auxiliaryTopRightArea`，两者之间剩下的就是缺口。
    /// 实测 14" Pro：左 663.5×32、右 663.5×32，反推缺口 185×32。
    var hasNotch: Bool {
        guard let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea else { return false }
        let gap = frame.width - l.width - r.width
        // 加宽度和高度约束，避免把「菜单栏被划成两段」的其它情形误判成刘海
        return gap > 120 && gap < 320 && safeAreaInsets.top >= 20
    }

    /// 菜单栏高度。用 frame 与 visibleFrame 的顶部差值推导，两种机型都对。
    var menuBarHeight: CGFloat {
        max(20, frame.maxY - visibleFrame.maxY)
    }
}

/// 几何：全部从系统真实数据推导，不猜测。
struct NotchMetrics {
    let screen: NSScreen
    let mode: BarMode
    let notchRect: CGRect      // AppKit 屏幕坐标（原点左下）
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// 菜单栏形态下，图标在屏幕上的位置。每次展开前由 Controller 刷新，
    /// 因为菜单栏图标的 x 会随着状态栏项增减、分辨率变化而移动。
    var iconAnchor: CGRect?

    // MARK: - 刘海形态的圆角

    /// 刘海底部两个圆角的半径。
    /// 14"/16" MacBook Pro 的摄像头外壳是「圆底」的：底边中段平直，
    /// 两端各用约 10pt 的圆角向上收进。卡片若与刘海等宽，
    /// 就会在这两个圆角外侧露出黑角，浅色菜单栏下割裂明显。
    var notchCornerRadius: CGFloat { 10 }

    // MARK: - 尺寸

    /// 卡片宽度。
    /// 刘海形态取刘海底边平直段（185 − 2×10 = 165）。
    /// 菜单栏形态也用 165：与刘海面板同宽，两套界面才像同一个应用。
    static let menuCardWidth: CGFloat = 165

    /// 内容区两行的高度。写在 Metrics 里，View 直接引用，
    /// 免得「42 / 22」在布局和总高计算里各写一份、改一处忘一处。
    static let mediaRowHeight: CGFloat = 42
    static let controlRowHeight: CGFloat = 22

    /// 面板与屏幕左右边缘的最小留白
    static let edgeInset: CGFloat = 6

    var cardWidth: CGFloat {
        mode == .notch ? notchWidth - notchCornerRadius * 2 : Self.menuCardWidth
    }

    /// 底角圆角。两种形态用同一个值，视觉才连续。
    var cardCornerRadius: CGFloat { 21 }

    /// 卡片顶部留白 / 刘海衔接过渡带。
    /// 刘海形态：黑色渐隐到透明的过渡带，抹掉那道硬边。
    /// 菜单栏形态：同样的 7pt，但纯粹是顶部留白——这里没有黑色刘海要融，
    /// 保留同样的高度是为了两套界面的第一行文字落在相同位置。
    var fadeHeight: CGFloat { 7 }

    /// 底部功能栏高度
    var actionBarHeight: CGFloat { 26 }

    /// 展开区高度。
    /// 两种形态完全一致：7 留白 + 42 媒体 + 22 控制 + 26 功能栏 = 97。
    /// 菜单栏形态不再砍功能——音乐/隔空投送开关、设置、退出都在，
    /// 玻璃与专辑配色也照旧，差别只在于没有刘海那段黑边。
    var extensionHeight: CGFloat {
        fadeHeight + Self.mediaRowHeight + Self.controlRowHeight + actionBarHeight
    }

    /// 窗口总高
    var panelHeight: CGFloat {
        mode == .notch ? notchHeight + extensionHeight : extensionHeight
    }

    /// 光晕向外弥散所需的留白。
    ///
    /// 光晕画在刘海**外面**（刘海是物理挖空，内部没有像素），
    /// 最外层弥散到边缘外约 7.5pt，所以画光晕的那个窗口要比刘海宽出一圈，
    /// 否则左右和下方会被窗口边界裁掉。上方是屏幕顶边，没有空间也不需要。
    ///
    /// 注意：这个留白**只属于光晕窗口**。面板窗口不再为了它放大——
    /// 窗口是整块参与事件路由的，放大 24pt 就等于在刘海下方凭空多出
    /// 一块点不动的死区。详见 `windowFrame(expanded:)`。
    var glowPad: CGFloat { mode == .notch ? 12 : 0 }

    /// 光晕窗口的 frame。它只负责画，`ignoresMouseEvents = true`，从不接收事件。
    var glowFrame: CGRect {
        guard mode == .notch else { return .zero }
        let pad = glowPad
        return CGRect(
            x: notchRect.minX - pad,
            y: screen.frame.maxY - notchHeight - pad,
            width: notchWidth + pad * 2,
            height: notchHeight + pad
        )
    }

    /// 面板窗口的宽度。
    ///
    /// 收起时取刘海全宽（185）——拖放要能落在刘海最左最右那几 pt 上；
    /// 展开时收成卡片宽度（165）——窗口多出来的每一点都会压住下方内容，
    /// 而卡片本身只有 165。
    func windowWidth(expanded: Bool) -> CGFloat {
        switch mode {
        case .notch: return expanded ? cardWidth : notchWidth
        case .menuBar: return cardWidth
        }
    }

    /// 面板窗口的高度。
    ///
    /// 收起时恰好等于刘海本身——刘海是物理挖空，那里没有像素也没有可点的内容，
    /// 窗口占着完全无感。只要往下多给 1pt，就开始压住菜单栏下方的内容。
    func windowHeight(expanded: Bool) -> CGFloat {
        switch mode {
        case .notch: return expanded ? panelHeight : notchHeight
        case .menuBar: return expanded ? extensionHeight : 1
        }
    }

    /// 展开时的面板 frame
    var panelFrame: CGRect { windowFrame(expanded: true) }

    /// 界面内容的排版尺寸（永远按展开态算）。
    ///
    /// 窗口会随展开/收起改变大小，但内容不该跟着重排——否则收起动画
    /// 会在半路被窗口边缘切断。内容固定成这个尺寸，由窗口负责裁剪。
    var designSize: CGSize {
        CGSize(width: cardWidth, height: mode == .notch ? panelHeight : extensionHeight)
    }

    /// 面板窗口**实际**的 frame。
    ///
    /// 收起时窗口只覆盖刘海本身（菜单栏形态退化成一条 1pt 的线），
    /// 于是窗口下方的内容完全不被挡住。
    ///
    /// 这一点不能靠视图的 `hitTest` 返回 nil 来做：窗口 server 是按
    /// **窗口**投递事件的，视图层拒绝只是把事件丢掉，不会转给下层 App。
    /// 所以「不挡」只能靠「窗口确实不在那里」。
    func windowFrame(expanded: Bool) -> CGRect {
        let top = screen.frame.maxY
        let w = windowWidth(expanded: expanded)
        let h = windowHeight(expanded: expanded)

        switch mode {
        case .notch:
            return CGRect(x: notchRect.midX - w / 2, y: top - h, width: w, height: h)
        case .menuBar:
            let barTop = top - screen.menuBarHeight
            let centerX = iconAnchor?.midX ?? (screen.frame.maxX - 40)
            var x = centerX - cardWidth / 2
            // 图标贴近屏幕边缘时居中会溢出，此时向内收，优先保证完整可见
            x = min(x, screen.frame.maxX - cardWidth - Self.edgeInset)
            x = max(x, screen.frame.minX + Self.edgeInset)
            return CGRect(x: x, y: barTop - h, width: cardWidth, height: h)
        }
    }

    /// 命中判定用的矩形：展开后的完整面板。
    ///
    /// 收起时窗口只有刘海那么高，鼠标本来就不可能落在别的窗口区域里，
    /// 所以这里只需要展开态的形状。留 2/3pt 余量防边界抖动。
    var hitFrame: CGRect { panelFrame }

    static func compute(
        for screen: NSScreen,
        forceMenuBar: Bool = false,
        iconAnchor: CGRect? = nil
    ) -> NotchMetrics {
        if screen.hasNotch && !forceMenuBar {
            let height = screen.safeAreaInsets.top
            let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightW = screen.auxiliaryTopRightArea?.width ?? 0
            let width = max(1, screen.frame.width - leftW - rightW)
            let rect = CGRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: height
            )
            return NotchMetrics(
                screen: screen, mode: .notch,
                notchRect: rect, notchWidth: width, notchHeight: height,
                iconAnchor: nil
            )
        }

        // 无刘海：菜单栏形态。notchRect 在这里退化成菜单栏区域，
        // 让沿用它的旧逻辑自然退化。notchHeight 为 0 —— 没有刘海，
        // 卡片直接从菜单栏下沿开始，所以窗口内不需要预留那一段。
        let h = screen.menuBarHeight
        let rect = CGRect(
            x: screen.frame.maxX - Self.menuCardWidth,
            y: screen.frame.maxY - h,
            width: Self.menuCardWidth,
            height: h
        )
        return NotchMetrics(
            screen: screen, mode: .menuBar,
            notchRect: rect, notchWidth: Self.menuCardWidth, notchHeight: 0,
            iconAnchor: iconAnchor
        )
    }
}
