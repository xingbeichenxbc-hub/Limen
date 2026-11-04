import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var model: NotchModel
    let metrics: NotchMetrics

    @Environment(\.colorScheme) private var systemScheme

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

    /// 展开：稍慢、略带弹性，像从刘海里被"拉"出来
    private var expandAnim: Animation {
        .spring(response: 0.32, dampingFraction: 0.78)
    }

    /// 收回：更快、阻尼更大，干脆地"吸"回去
    private var collapseAnim: Animation {
        .spring(response: 0.24, dampingFraction: 0.95)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            VStack(spacing: 0) {
                Color.clear.frame(height: metrics.notchHeight)

                ZStack(alignment: .top) {
                    CardSurface(shape: shape, style: model.style, palette: palette)

                    // 关键：把纯黑的刘海"融化"进玻璃。
                    // 这层在玻璃之上、内容之下，所以文字不会被压黑。
                    // 菜单栏形态没有刘海，这里只是顶部留白，不画黑边。
                    if metrics.mode == .notch {
                        NotchFade(height: metrics.fadeHeight + 3)
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
                    .environment(\.colorScheme, palette == nil ? systemScheme : .dark)
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
        if model.cardMode == .settings {
            SettingsPanel(model: model)
                .transition(.opacity)
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
            .transition(.opacity)
        } else {
            HintRow(icon: "music.note", text: "没有正在播放的内容")
        }
    }
}

// MARK: - 刘海到玻璃的过渡

/// 纯黑渐隐到透明。卡在卡片顶部，让刘海看起来是自然延伸下来的，
/// 而不是在一块玻璃上突然断开。只在很短的距离内完成，避免视觉上"变厚"。
struct NotchFade: View {
    var height: CGFloat = 10

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black, location: 0.00),
                .init(color: Color.black.opacity(0.88), location: 0.20),
                .init(color: Color.black.opacity(0.58), location: 0.42),
                .init(color: Color.black.opacity(0.24), location: 0.66),
                .init(color: Color.black.opacity(0.00), location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

// MARK: - 媒体

struct MediaRow: View {
    let snapshot: NowPlayingSnapshot
    var onOpen: () -> Void

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
                    .legibleOnGlass()

                Text(snapshot.artist.isEmpty ? snapshot.album : snapshot.artist)
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .legibleOnGlass()
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
                model.musicEnabled.toggle()
                model.onMusicToggled?(model.musicEnabled)
            }

            ActionIcon(
                system: "dot.radiowaves.left.and.right",
                isOn: model.airDropEnabled,
                dot: true,
                help: model.airDropEnabled ? "关闭隔空投送" : "开启隔空投送"
            ) {
                model.airDropEnabled.toggle()
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
                withAnimation(.easeOut(duration: 0.16)) {
                    model.cardMode = model.cardMode == .settings ? .main : .settings
                }
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
                        .fill(Color.primary.opacity(isOn ? 0.55 : 0.10))
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

    // 两行：26 + 19。内容区有 64pt，多出来的由 VStack 居中吸收
    // （上下各 9.5pt），不必为此改面板高度——面板高度一旦跟着设置页变，
    // 窗口、命中区、收起判定全都要跟着动。
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

/// 玻璃亮度完全跟着壁纸走，可能是浅色也可能是深色。
/// 给文字叠两层深色阴影当"描边"，这样无论背后是白是黑都能读清；
/// 在深色壁纸上这两层几乎看不出来，不会污染画面。
extension View {
    func legibleOnGlass() -> some View {
        self
            .shadow(color: Color.black.opacity(0.50), radius: 1.6, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.32), radius: 0.4, x: 0, y: 0.5)
    }
}
