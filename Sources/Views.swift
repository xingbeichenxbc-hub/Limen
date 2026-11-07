import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var model: NotchModel
    let metrics: NotchMetrics

    @Environment(\.colorScheme) private var systemScheme

    /// 这张卡片到底按深色还是浅色渲染。
    /// 专辑档会把整棵树强制成深色，其余档跟着系统走。
    /// `LIMEN_APPEARANCE` 只是调试覆盖，正常运行时不生效。
    private var cardIsDark: Bool {
        if let forced = AppearanceOverride.forced { return forced == .dark }
        return palette != nil || systemScheme == .dark
    }

    private var effectiveScheme: ColorScheme {
        palette == nil ? (AppearanceOverride.forced ?? systemScheme) : .dark
    }

    private var cardHeight: CGFloat {
        model.expanded ? metrics.extensionHeight : 0
    }

    private var shape: NotchCardShape {
        NotchCardShape(height: cardHeight, radius: metrics.cardCornerRadius)
    }

    /// 过渡带之下的内容区高度（媒体 + 控制）
    private var contentHeight: CGFloat {
        NotchMetrics.mediaRowHeight + NotchMetrics.controlRowHeight
    }

    /// 当前生效的专辑配色。只有选中「专辑」这一档、且有封面时才生效；
    /// 没有封面就自动回退成通透玻璃。
    private var palette: AlbumPalette? {
        guard model.style.usesAlbumPalette else { return nil }
        return model.snapshot?.palette
    }

    // MARK: 动效

    /// 动画时长倍率。`LIMEN_ANIM_SLOW=8` 可把收起放慢到能逐帧截图分析。
    /// 只影响时长，曲线形状不变，所以慢放看到的就是原速发生的同一件事。
    private var animScale: Double {
        ProcessInfo.processInfo.environment["LIMEN_ANIM_SLOW"].flatMap(Double.init) ?? 1
    }

    /// 展开：稍慢、略带弹性，像从刘海里被"拉"出来
    private var expandAnim: Animation {
        .spring(response: 0.32 * animScale, dampingFraction: 0.78)
    }

    /// 收回：更快、阻尼更大，干脆地"吸"回去
    private var collapseAnim: Animation {
        .spring(response: 0.24 * animScale, dampingFraction: 0.95)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            VStack(spacing: 0) {
                Color.clear.frame(height: metrics.notchHeight)

                ZStack(alignment: .top) {
                    // 用 `SquashFade` 包一层，是为了拿到**插值中的**高度。
                    // `cardHeight` 本身只有 129/0 两个值（靠 model.expanded 布尔切换），
                    // 直接传进去的话，收起瞬间它就是 0，卡片的"压扁"逻辑根本没机会
                    // 跟着动画走。详见 `SquashFade`。
                    SquashFade(height: cardHeight) { h in
                        CardSurface(shape: shape, style: model.style, palette: palette,
                                    dark: cardIsDark, cardHeight: h)
                    }

                    // 关键：把纯黑的刘海"融化"进玻璃。
                    // 这层在玻璃之上、内容之下，所以文字不会被压黑。
                    // 菜单栏形态没有刘海，这里只是顶部留白，不画黑边。
                    if metrics.mode == .notch {
                        NotchFade()
                            // 过渡带必须跟着卡片一起"压缩"，而不是被裁剪切断。
                            // 详见 `BandClamp`。
                            .modifier(BandClamp(
                                cardHeight: cardHeight,
                                full: metrics.fadeHeight + 3
                            ))
                            .frame(maxHeight: .infinity, alignment: .top)
                    }

                    VStack(spacing: 0) {
                        Color.clear.frame(height: metrics.fadeHeight)

                        contentArea
                            .frame(height: contentHeight)

                        Spacer(minLength: 0)

                        Rectangle()
                            .fill(Color.primary.opacity(0.09))
                            .frame(height: 0.5)
                            .padding(.horizontal, 10)

                        ActionBar(model: model)
                            .frame(height: metrics.actionBarHeight)
                    }
                    // 有专辑配色时强制深色外观：卡片底色被钉在暗区间，
                    // 这样 .primary 一定是白色，文字对比度不需要靠猜壁纸。
                    .environment(\.colorScheme, effectiveScheme)
                    // 内容不做淡入淡出：完全靠外层形状裁剪来"揭示"，
                    // 这样看起来是面板从刘海下面被拉出来，而不是一块卡片淡入。
                    .allowsHitTesting(model.expanded)
                }
                .frame(width: metrics.cardWidth, height: metrics.extensionHeight)
                .clipShape(shape)
                .animation(model.expanded ? expandAnim : collapseAnim, value: model.expanded)
                .animation(.easeInOut(duration: 0.45), value: palette)
            }
        }
        // 内容始终按**展开态**排版，由窗口去裁。
        // 若这里跟着窗口一起缩，收起动画会在半路被窗口边缘切断；
        // 让它保持原尺寸、由窗口裁，动画就能完整放完再被收走。
        .frame(width: metrics.designSize.width,
               height: metrics.designSize.height,
               alignment: .top)
    }

    @ViewBuilder
    private var contentArea: some View {
        // 所有页面切换一律即时完成，不做淡入淡出过渡：
        // `transition(.opacity)` 在部分 macOS 版本上会把新插入的内容
        // 卡在透明度 0（面板变成一块空玻璃，字全看不见）。
        if model.cardMode == .settings {
            SettingsPanel(model: model)
        } else if model.cardMode == .countdown {
            CountdownPanel(model: model)
        } else if !model.musicEnabled && !model.airDropEnabled {
            HintRow(icon: "minus.circle", text: "功能都已关闭")
        } else if !model.musicEnabled {
            HintRow(icon: "dot.radiowaves.left.and.right", text: "拖入文件即可隔空投送")
        } else if model.permissionHint {
            HintRow(icon: "lock.circle", text: "需要允许 Limen 访问音乐",
                    action: { model.onOpenAutomationSettings?() })
        } else if let s = model.snapshot {
            VStack(spacing: 0) {
                MediaRow(snapshot: s, onOpen: { model.onOpenSource?() })
                    .frame(height: NotchMetrics.mediaRowHeight)
                ControlRow(
                    isPlaying: s.isPlaying,
                    onPrevious: { model.onPrevious?() },
                    onToggle: { model.onTogglePlay?() },
                    onNext: { model.onNext?() }
                )
                .frame(height: NotchMetrics.controlRowHeight)
            }
        } else {
            HintRow(icon: "music.note", text: "没有正在播放的内容")
        }
    }
}

// MARK: - 刘海到玻璃的过渡

/// 纯黑渐隐到透明。卡在卡片顶部，让刘海看起来是自然延伸下来的，
/// 而不是在一块玻璃上突然断开。只在很短的距离内完成，避免视觉上"变厚"。
struct NotchFade: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black, location: 0.00),
                .init(color: Color.black.opacity(0.82), location: 0.22),
                .init(color: Color.black.opacity(0.48), location: 0.46),
                .init(color: Color.black.opacity(0.18), location: 0.70),
                .init(color: Color.black.opacity(0.00), location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

/// 把"动画中的高度"喂给内容。
///
/// `cardHeight` 是个计算属性（`model.expanded ? 129 : 0`），它没有中间值：
/// 收起一开始就是 0。而卡片形状的高度是靠 `NotchCardShape.animatableData`
/// 插值的，两者并不同步——于是"卡片正在被压扁"这件事，内容侧完全感知不到。
///
/// 这个 View 自己做 `Animatable`，`height` 会被 SwiftUI 按动画曲线插值，
/// 再把每一帧的值传给闭包。卡片边缘的白色细节就能真正随压扁过程淡出。
struct SquashFade<Content: View>: View, Animatable {
    var height: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    var body: some View { content(height) }
}

/// 让刘海过渡带随卡片高度一起收缩。
///
/// **它解决的是收起的最后一瞬间"黑色长方体"的问题。**
///
/// 过渡带原本是固定 10pt 的渐变，靠外层的 `clipShape` 裁切。卡片缩短时，
/// 裁剪线从下往上切过这条渐变——切掉的是渐变最淡的尾巴，留下的是最黑的头部，
/// 于是屏幕上出现一块**底边是硬边**的黑色。实测：
///
/// ```
/// 卡片还高： 66:0.07 70:0.27 74:0.52 78:0.74 82:0.88 85:1.00   ← 完整渐变
/// 缩到一半： 66:0.07 70:0.28 73:0.48 74:0.77 75:1.00           ← 4pt，硬切
/// 快贴底：   66:0.08 67:1.00                                   ← 1pt 纯黑顶，硬边
/// ```
///
/// 做法是**压缩**：高度取 `min(带宽, 卡片高)`，渐变永远铺满剩余高度，
/// 底边始终是渐变的透明端，不再是刀切口。卡片缩到多小，过渡带就跟着多小，
/// 最后和刘海连成一片黑一起收走。
///
/// **不要在这里加 opacity 淡出。** 第一版加了，结果原速下白边闪现一帧：
/// 黑一淡，就露出它下面那条玻璃顶部内缘高光（0.55 白）。
/// 缩回刘海时顶部本来就该是连续的黑，淡出等于把最不该露的层露了出来。
///
/// 必须是 `Animatable`：`cardHeight` 本身只有 0 和 129 两个值，
/// 不动画插值的话，压缩只会在动画结束时突变一次——比不修还难看。
private struct BandClamp: ViewModifier, Animatable {
    /// 卡片当前高度（展开 129、收起 0），由 SwiftUI 沿收起曲线插值
    var cardHeight: CGFloat
    /// 过渡带的完整高度
    let full: CGFloat

    var animatableData: CGFloat {
        get { cardHeight }
        set { cardHeight = newValue }
    }

    func body(content: Content) -> some View {
        // 高度跟着卡片走：渐变永远铺满剩余高度，底边始终落在透明的尾端。
        //
        // **不要在这里加 opacity 淡出。** 试过，原速下白边闪现一帧：
        // 黑过渡带一淡，就露出它下面那条玻璃顶部内缘高光（0.55 白）。
        // 实测白底环境 y=64 从 0.03 跳到 0.23，整条带从 0.11 涨到 0.58。
        // 淡出的对象是错的——卡片缩回刘海时，顶部本来就该是连续的黑。
        content.frame(height: min(full, max(0, cardHeight)), alignment: .top)
    }
}

// MARK: - 媒体

struct MediaRow: View {
    let snapshot: NowPlayingSnapshot
    var onOpen: () -> Void

    /// 卡片会把外观强制成深色（有专辑配色时），所以这里读到的
    /// 就是"文字实际所处的明暗"，不需要再往上要参数。
    @Environment(\.colorScheme) private var scheme

    private var onDark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: 8) {
            artwork
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5)
                )
                .onTapGesture(perform: onOpen)

            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .legibleOnGlass(dark: onDark)

                Text(snapshot.artist.isEmpty ? snapshot.album : snapshot.artist)
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .legibleOnGlass(dark: onDark)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var artwork: some View {
        if let img = snapshot.artwork {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.42), Color(white: 0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

struct ControlRow: View {
    let isPlaying: Bool
    var onPrevious: () -> Void
    var onToggle: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack(spacing: 26) {
            Button(action: onPrevious) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())

            Button(action: onToggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())

            Button(action: onNext) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 底部功能栏

struct ActionBar: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 2) {
            ActionIcon(
                system: "music.note",
                isOn: model.musicEnabled,
                dot: true,
                help: model.musicEnabled ? "关闭音乐" : "开启音乐"
            ) {
                if model.cardMode == .countdown {
                    // 倒计时页上点音乐：先切回音乐显示（这一下**不改**开关），
                    // 之后再点才是「关 / 开」的常规切换。
                    model.cardMode = .main
                } else {
                    model.musicEnabled.toggle()
                    model.onMusicToggled?(model.musicEnabled)
                }
            }

            ActionIcon(
                system: "dot.radiowaves.left.and.right",
                isOn: model.airDropEnabled,
                dot: true,
                help: model.airDropEnabled ? "关闭隔空投送" : "开启隔空投送"
            ) {
                model.airDropEnabled.toggle()
            }

            ActionIcon(
                system: "timer",
                isOn: true,
                dot: true,
                dotOn: model.countdownPhase != .idle,
                help: "倒计时"
            ) {
                model.cardMode = model.cardMode == .countdown ? .main : .countdown
            }

            Spacer(minLength: 4)

            Rectangle()
                .fill(Color.primary.opacity(0.13))
                .frame(width: 0.5, height: 11)

            Spacer(minLength: 4)

            ActionIcon(
                system: "gearshape",
                isOn: true,
                dot: false,
                active: model.cardMode == .settings,
                help: "设置"
            ) {
                model.cardMode = model.cardMode == .settings ? .main : .settings
            }

            ActionIcon(
                system: "power",
                isOn: true,
                dot: false,
                help: "退出 Limen"
            ) {
                model.onQuit?()
            }
        }
        .padding(.horizontal, 10)
    }
}

struct ActionIcon: View {
    let system: String
    let isOn: Bool
    let dot: Bool
    /// 小圆点要不要亮。默认跟着 `isOn` 走；
    /// 倒计时图标需要「图标常亮、圆点只在计时中亮」，用这个覆盖。
    var dotOn: Bool? = nil
    var active: Bool = false
    let help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1.5) {
                Image(systemName: system)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(isOn ? 0.90 : 0.24))

                if dot {
                    Circle()
                        .fill(Color.primary.opacity((dotOn ?? isOn) ? 0.55 : 0.10))
                        .frame(width: 2.5, height: 2.5)
                } else if active {
                    Circle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2.5, height: 2.5)
                } else {
                    Color.clear.frame(width: 2.5, height: 2.5)
                }
            }
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }
}

// MARK: - 设置面板

struct SettingsPanel: View {
    @ObservedObject var model: NotchModel

    // 三行：26 + 19 + 19 = 64，正好等于内容区高度（媒体行 42 + 功能栏 22）。
    // 不要再加第四行——面板高度一旦跟着设置页变，窗口、命中区、
    // 收起判定全都要跟着动。
    var body: some View {
        VStack(spacing: 0) {
            // 四档外观均分整行。去掉左边标签，否则 165pt 宽度放不下 4 个选项。
            HStack(spacing: 3) {
                ForEach(GlassStyle.allCases, id: \.rawValue) { s in
                    Button {
                        model.style = s
                    } label: {
                        Text(s.shortTitle)
                            .font(.system(size: 9, weight: model.style == s ? .medium : .regular))
                            .foregroundStyle(.primary.opacity(model.style == s ? 0.92 : 0.42))
                            .frame(maxWidth: .infinity)
                            .frame(height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(model.style == s ? 0.16 : 0.04))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)

            SettingToggleRow(title: "电量显示", isOn: model.batteryEnabled) {
                model.batteryEnabled.toggle()
            }
            .frame(height: 19)

            SettingToggleRow(title: "登录时启动", isOn: model.launchAtLogin) {
                model.requestLaunchAtLogin(!model.launchAtLogin)
            }
            .frame(height: 19)
        }
    }
}

/// 设置页的「标签 + 小开关」一行。两行共用，免得把同一段 HStack 抄两遍。
struct SettingToggleRow: View {
    let title: String
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            MiniToggle(isOn: isOn, action: action)
                .accessibilityLabel(title)
                .accessibilityValue(isOn ? "开" : "关")
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }
}

struct MiniToggle: View {
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(isOn ? 0.55 : 0.16))
                .frame(width: 26, height: 14)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 11, height: 11)
                        .padding(.horizontal, 1.5)
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - 倒计时页

/// 倒计时在弹窗里的三个页面：输入 / 计时中 / 时间到。
/// 内容区只有 64pt 高，布局按「行」均分，不新增面板高度。
///
/// 注意：倒计时页的切换**不做淡入淡出过渡**——`transition(.opacity)`
/// 搭配带 TextField / FocusState 的子树，在某些 macOS 版本上会把
/// 刚插入的内容卡在透明度 0（面板变成一块空玻璃，字全看不见）。
/// 页面切换一律即时完成。
struct CountdownPanel: View {
    @ObservedObject var model: NotchModel
    @FocusState private var inputFocused: Bool

    private var totalMinutes: Int { Int(model.countdownTotal / 60) }

    var body: some View {
        Group {
            switch model.countdownPhase {
            case .idle:
                setupView
            case .running:
                runningView
            case .finished:
                finishedView
            }
        }
        // 焦点进出 → 通知 Controller 切换面板的 key 能力
        .onChange(of: inputFocused) { _, newValue in
            model.countdownFieldFocused = newValue
            model.onCountdownFocusChange?(newValue)
        }
        .onChange(of: model.countdownFieldFocused) { _, newValue in
            if inputFocused != newValue { inputFocused = newValue }
        }
    }

    // MARK: 输入

    /// 输入行 + 历史胶囊。整体在 64pt 内容区内垂直居中；
    /// 历史最多 6 个，超出一行自动换行。所有元素左缘对齐（同 12pt 内边距）。
    private var setupView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("", text: Binding(
                    get: { model.countdownInputText },
                    set: { model.setCountdownInput($0) }
                ))
                .focused($inputFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(width: 58, height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            fieldBorderColor,
                            lineWidth: model.countdownInputBad ? 1.2 : (inputFocused ? 1.0 : 0.7)
                        )
                )
                .onSubmit { model.startCountdown() }

                Text("分钟")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .baselineOffset(0.5)

                Spacer(minLength: 2)

                Button {
                    model.startCountdown()
                } label: {
                    Text("开始")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(model.countdownCanStart
                            ? Color.white
                            : Color.primary.opacity(0.35))
                        .padding(.horizontal, 11)
                        .frame(height: 21)
                        .background(
                            Capsule().fill(model.countdownCanStart
                                ? Color.accentColor.opacity(0.9)
                                : Color.primary.opacity(0.08))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!model.countdownCanStart)
            }
            .frame(height: 22)

            if !model.countdownHistory.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 32), spacing: 4, alignment: .leading)],
                    alignment: .leading,
                    spacing: 4
                ) {
                    ForEach(model.countdownHistory, id: \.self) { v in
                        historyChip(v)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 历史胶囊：当前值高亮为强调色，点击回填
    private func historyChip(_ v: Int) -> some View {
        let selected = String(v) == model.countdownInputText
        return Button {
            model.setCountdownInput(String(v))
        } label: {
            Text("\(v)")
                .font(.system(size: 9.5, weight: selected ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(
                    Capsule().fill(selected
                        ? Color.accentColor.opacity(0.14)
                        : Color.primary.opacity(0.08))
                )
                .overlay(
                    Capsule().strokeBorder(
                        selected ? Color.accentColor.opacity(0.45) : .clear,
                        lineWidth: 0.8
                    )
                )
        }
        .buttonStyle(PressableButtonStyle())
    }

    /// 输入框描边：超上限闪红 → 红；持焦 → 强调色；平时 → 细灰边
    private var fieldBorderColor: Color {
        if model.countdownInputBad { return Color.red.opacity(0.9) }
        if inputFocused { return Color.accentColor.opacity(0.85) }
        return Color.primary.opacity(0.15)
    }

    // MARK: 计时中

    /// 只有两样东西：剩余时间 + 停止按钮。
    /// 时间居中在「左缘与停止按钮之间」，有按钮在右侧时视觉上才是正的。
    private var runningView: some View {
        HStack(spacing: 0) {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(CountdownFormat.clock(seconds: model.countdownRemaining))
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            Spacer()
            Button {
                model.stopCountdown()
            } label: {
                Text("停止")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 17)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(PressableButtonStyle())
            .help("停止计时")
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }

    // MARK: 时间到

    /// 徽章 + 标题 + 副题 + 按钮，全部同一水平中心线对齐
    private var finishedView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 1.00, green: 0.80, blue: 0.45),
                                    Color(red: 1.00, green: 0.58, blue: 0.18)
                                ],
                                center: .topLeading,
                                startRadius: 1,
                                endRadius: 12
                            )
                        )
                        .frame(width: 18, height: 18)
                    Image(systemName: "bell.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text("时间到")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Text("已计时 \(totalMinutes) 分钟")
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)

            Button {
                model.stopCountdown()
            } label: {
                Text("关闭计时")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 19)
                    .background(Capsule().fill(Color.accentColor.opacity(0.92)))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 其他行

struct HintRow: View {
    let icon: String
    let text: String
    /// 给了动作就变成可点的提示（例如权限被拒 → 打开系统设置）
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .help("打开系统设置")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 玻璃亮度跟着背景走，可能是浅色也可能是深色。文字需要一点"保护"，
/// 但**保护方式不能是给黑色文字加黑色阴影**（浅色卡片 + 深色文字会被
/// 阴影涂糊）。实现见 `legibleOnGlass`。
extension View {
    /// 玻璃上的文字对比保护。
    ///
    /// 深色外观下是白字，背后可能是任何亮度的背景（通透玻璃几乎不模糊）。
    /// 单层小阴影不够——用「紧 + 松」两层：紧的一层把笔画从贴着的背景里
    /// 抠出来，松的一层给整行字一个柔和的暗底，明亮背景上也不糊。
    /// 浅色外观下是深字，本身对比足够，不加阴影以免弄脏。
    func legibleOnGlass(dark: Bool) -> some View {
        shadow(
            color: dark ? Color.black.opacity(0.55) : .clear,
            radius: dark ? 1.4 : 0,
            x: 0,
            y: dark ? 0.6 : 0
        )
        .shadow(
            color: dark ? Color.black.opacity(0.35) : .clear,
            radius: dark ? 0.4 : 0,
            x: 0,
            y: dark ? 0.3 : 0
        )
    }
}
