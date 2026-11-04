import AppKit

struct NowPlayingSnapshot {
    var title: String
    var artist: String
    var album: String
    var position: Double
    var duration: Double
    var isPlaying: Bool
    var artwork: NSImage?
    /// 从封面提取出的配色。nil = 没有封面（如 Spotify），此时界面用默认玻璃
    var palette: AlbumPalette?
}

/// 通过 AppleScript 读取正在播放的媒体。
/// 目前支持「音乐 Music」与「Spotify」——这两个覆盖了绝大多数本地播放场景。
/// 后续若要支持浏览器等任意播放源，需要在运行时接 MediaRemote（私有接口，稳定性差），
/// 这里先不做，避免崩溃。
final class NowPlayingService {

    var onUpdate: ((NowPlayingSnapshot?) -> Void)?
    var onPermissionIssue: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "app.limen.nowplaying", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var cachedArtwork: NSImage?
    private var cachedPalette: AlbumPalette?
    private var denied = false

    private let logEnabled = ProcessInfo.processInfo.environment["LIMEN_LOG"] == "1"

    private let artworkPath = NSTemporaryDirectory() + "limen-artwork.bin"

    /// 字段分隔符用 ASCII 31（Unit Separator），不用制表符。
    /// 曲名里真的可能出现制表符，一旦出现，后面的字段会整体错位，
    /// 表现成「歌手变成专辑、时长变成 0」这种莫名其妙的错乱。
    private static let fieldSeparator = "\u{1F}"

    func start() {
        stop()
        tick()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !inFlight else { return }
        inFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.readNowPlaying()
            DispatchQueue.main.async {
                self.inFlight = false
                self.onUpdate?(result)
            }
        }
    }

    // MARK: - 读取

    private func readNowPlaying() -> NowPlayingSnapshot? {
        if let snap = read(app: "Music", tag: "music", supportsArtwork: true) {
            return snap
        }
        return read(app: "Spotify", tag: "spotify", supportsArtwork: false)
    }

    /// 两个播放器的 AppleScript 字典在「这几项」上完全一致，
    /// 所以用同一段脚本、只换应用名。字段用控制字符分隔（见 fieldSeparator）。
    private func read(app: String, tag: String, supportsArtwork: Bool) -> NowPlayingSnapshot? {
        let script = """
        if application "\(app)" is running then
            tell application "\(app)"
                set ps to player state
                if ps is playing or ps is paused then
                    set sep to (ASCII character 31)
                    set tname to name of current track
                    set tartist to artist of current track
                    set talbum to album of current track
                    set tpos to player position
                    set tdur to duration of current track
                    set isPaused to "0"
                    if ps is paused then set isPaused to "1"
                    return tname & sep & tartist & sep & talbum & sep & (tpos as text) & sep & (tdur as text) & sep & isPaused
                end if
            end tell
        end if
        return ""
        """
        guard let out = runOSA(script), !out.isEmpty else { return nil }
        let f = out.components(separatedBy: Self.fieldSeparator)
        guard f.count >= 6 else { return nil }

        let snap = NowPlayingSnapshot(
            title: f[0],
            artist: f[1],
            album: f[2],
            position: Double(f[3]) ?? 0,
            duration: Double(f[4]) ?? 0,
            isPlaying: f[5] == "0",
            artwork: nil
        )
        guard supportsArtwork else { return snap }
        return attachArtwork(snap, key: "\(tag)|\(snap.title)|\(snap.artist)") {
            self.fetchArtwork { self.artworkScriptMusic() }
        }
    }

    // MARK: - 封面

    /// 已经「下过结论」的曲目。结论可以是「拿到封面」，
    /// 也可以是「确定这一首没有封面」——后者要记住，否则没封面的歌会让
    /// 脚本每 2 秒空跑一次。
    private var resolvedArtworkKey = ""

    /// 当前正在重试的那首，以及试了几次、从什么时候开始试。
    /// 这三个字段必须绑定同一首歌，换曲时要一起清零，
    /// 否则上一首的失败次数会算到下一首头上。
    private var missKey = ""
    private var artworkMisses = 0
    private var artworkMissSince = Date()

    /// 一首歌最多试几次就认定「它没有封面」。
    /// 6 次 ≈ 12 秒，够播放器把封面解出来，又不会无限空转。
    private static let maxArtworkMisses = 6
    private static let artworkGiveUpAfter: TimeInterval = 12

    /// 把封面挂到快照上。
    ///
    /// **只有真的拿到图，才把 key 记成已解决。**
    ///
    /// 这是「点下一首没有封面」的根因。点下一首之后，播放器的 current track
    /// 立刻变成新歌，但 artwork 往往还要几十到几百毫秒才就绪，这时候读
    /// 只能拿到空数据。早前的写法在读失败时也把 key 提交了，于是下一次轮询
    /// 看到 key 相同，直接跳过封面读取、把 nil 当作答案返回——封面就再也不
    /// 出现，直到再换一首歌才有机会重试。
    ///
    /// 这也解释了为什么「键盘切歌有时正常、点按钮几乎必现」：`control()` 在
    /// 0.35 秒后强制刷新一次，这个时机几乎必然早于封面就绪；而键盘切歌只能
    /// 撞上 2 秒的常规轮询，反而经常落在封面就绪之后。
    ///
    /// 现在改成：没拿到就留着重试，但设上限（见 `maxArtworkMisses`）。
    private func attachArtwork(
        _ snap: NowPlayingSnapshot,
        key: String,
        fetch: () -> String?
    ) -> NowPlayingSnapshot {        var s = snap

        // 这一首已经有结论了：直接用缓存，可能是「确实没有封面」
        if key == resolvedArtworkKey {
            s.artwork = cachedArtwork
            s.palette = cachedPalette
            return s
        }

        // 换了一首（或仍是上次没读成的那首）：只有换歌才重置重试计数
        if key != missKey {
            missKey = key
            artworkMisses = 0
            artworkMissSince = Date()
        }

        // 先删掉上一首留下的文件。否则这一首读失败时，
        // 下面那句 NSImage(contentsOfFile:) 会捡起旧图当成新封面。
        try? FileManager.default.removeItem(atPath: artworkPath)

        var image: NSImage?
        if let title = fetch(), title == snap.title,
           let img = NSImage(contentsOfFile: artworkPath), img.size.width > 1 {
            image = img
        }
        // 读完就擦掉，别让封面图一直躺在临时目录里
        try? FileManager.default.removeItem(atPath: artworkPath)

        if let img = image {
            cachedArtwork = img
            // 配色只在换封面时算一次，之后跟着快照走，
            // 避免每 2 秒轮询都重新做一次像素统计。
            cachedPalette = AlbumPalette.extract(from: img)
            resolvedArtworkKey = key
            artworkMisses = 0
            if logEnabled {
                NSLog("[NP] artwork ok key=%@ tries=%d", key, artworkMisses)
            }
        } else {
            // 关键：**不提交 key**，下一次轮询继续试
            cachedArtwork = nil
            cachedPalette = nil
            artworkMisses += 1
            let elapsed = Date().timeIntervalSince(artworkMissSince)
            let giveUp = artworkMisses >= Self.maxArtworkMisses
                || elapsed >= Self.artworkGiveUpAfter
            if giveUp {
                // 真的没有封面。记下结论，免得一直空转。
                resolvedArtworkKey = key
                artworkMisses = 0
            }
            if logEnabled {
                NSLog("[NP] artwork miss key=%@ tries=%d elapsed=%.1fs giveUp=%@",
                      key, artworkMisses, elapsed, String(giveUp))
            }
        }

        s.artwork = cachedArtwork
        s.palette = cachedPalette
        return s
    }

    /// 让播放器把封面写到临时文件，返回**它当时正在播的那首曲名**。
    ///
    /// 返回曲名是为了自证一致性：读元数据和读封面是两次 AppleScript 调用，
    /// 中间用户可能又切了一首。如果封面脚本报回的曲名和刚读到的元数据不一致，
    /// 这张图就不能认——否则会把 B 歌的封面挂到 A 歌名下，一直错到下次换曲。
    ///
    /// 返回 nil 表示没有封面可读（播放器没运行 / 没在播 / 这首没有 artwork）。
    private func fetchArtwork(_ script: () -> String) -> String? {
        let out = runOSA(script()) ?? ""
        let parts = out.components(separatedBy: Self.fieldSeparator)
        guard parts.count >= 2, parts[1] == "1" else { return nil }
        return parts[0]
    }

    private func artworkScriptMusic() -> String {
        """
        if application "Music" is running then
            tell application "Music"
                set ps to player state
                if ps is playing or ps is paused then
                    if (count of artworks of current track) > 0 then
                        set sep to (ASCII character 31)
                        set tname to name of current track
                        set d to raw data of artwork 1 of current track
                        set p to POSIX file "\(artworkPath)"
                        set fh to open for access p with write permission
                        set eof fh to 0
                        write d to fh
                        close access fh
                        return tname & sep & "1"
                    end if
                end if
            end tell
        end if
        return "0"
        """
    }

    // MARK: - 播放控制

    func togglePlayPause() {
        queue.async {
            _ = self.runOSA("""
            if application "Music" is running then
                tell application "Music"
                    if player state is playing then
                        pause
                    else
                        play
                    end if
                end tell
            end if
            """)
            _ = self.runOSA("""
            if application "Spotify" is running then
                tell application "Spotify" to playpause
            end if
            """)
        }
    }

    func openSourceApp() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: "com.apple.Music"), isRunning("com.apple.Music") {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = ws.urlForApplication(withBundleIdentifier: "com.spotify.client"), isRunning("com.spotify.client") {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func nextTrack() {
        control("next track")
    }

    func previousTrack() {
        control("previous track")
    }

    /// 两个播放器的「下一首 / 上一首」语法相同，一条命令发给两边，
    /// 只有真正在运行的那个会响应。
    private func control(_ command: String) {
        queue.async {
            for app in ["Music", "Spotify"] {
                _ = self.runOSA("""
                if application "\(app)" is running then
                    tell application "\(app)" to \(command)
                end if
                """)
            }
        }
        // 立刻刷新几次：界面不用等满 2 秒。
        //
        // 只刷一次不够——切歌之后封面往往要几十到几百毫秒才就绪，
        // 单次 0.35 秒的刷新很容易正好扑空，那一拍读到的就是「没有封面」。
        // 分三拍能让界面尽快跟上，也把「封面恰好在第几拍就绪」这件事
        // 交给 `attachArtwork` 的重试逻辑兜住。
        for delay in [0.35, 0.9, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tick()
            }
        }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - osascript

    @discardableResult
    private func runOSA(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        // osascript 会把 AppleScript 运行期错误写到 stderr。
        // 合并到同一个管道，否则权限被拒（-1743）这类错误会被悄悄丢掉，
        // 界面就永远不知道该提示用户去授权。
        p.standardError = out
        do {
            try p.run()
        } catch {
            return nil
        }

        // 播放器如果卡在某个模态对话框上，osascript 会一直不返回，
        // 这个串行队列就会被永久占住，界面从此不再更新。
        // 5 秒还没结束就收掉它——读不到就当作没在播放，下一轮再来。
        let killer = DispatchWorkItem { [weak p] in
            if p?.isRunning == true { p?.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: killer)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let lower = text.lowercased()
        let permissionDenied = text.contains("-1743")
            || lower.contains("not authorized")
            || lower.contains("not allowed")
            || text.contains("不允许")
            || text.contains("权限违例")
            || text.contains("未获授权")

        if permissionDenied {
            DispatchQueue.main.async {
                if !self.denied {
                    self.denied = true
                    self.onPermissionIssue?(true)
                }
            }
            return nil
        }

        // 授权是可以在系统设置里补上的。之前被拒过、现在又能读通了，
        // 就要把提示撤掉——否则用户明明点了允许，界面还一直说「需要允许」。
        DispatchQueue.main.async {
            if self.denied {
                self.denied = false
                self.onPermissionIssue?(false)
            }
        }
        return text
    }

    // MARK: - 自检

    /// 验证封面重试状态机。**驱动的是真实的 `attachArtwork`**，
    /// 只是把 AppleScript 换成注入的闭包——不需要播放器，也不需要出声。
    ///
    /// 守的核心不变式：**读失败时不能把这一首记成已解决**。
    /// 一旦记了，后面每次轮询都会跳过读取、把「没有封面」当成结论，
    /// 直到再换一首歌。那就是「点下一首没封面、再点几次又有了」的成因。
    static func runSelfTest() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(name)")
        }

        func snapshot(_ title: String) -> NowPlayingSnapshot {
            NowPlayingSnapshot(title: title, artist: "A", album: "B",
                               position: 0, duration: 100, isPlaying: true,
                               artwork: nil, palette: nil)
        }

        // 造一张能真的被 NSImage 解出来的图
        let png = NSTemporaryDirectory() + "limen-selftest-artwork.png"
        let probe = NSImage(size: NSSize(width: 8, height: 8))
        probe.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        probe.unlockFocus()
        var pngData: Data?
        if let tiff = probe.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            pngData = rep.representation(using: .png, properties: [:])
        }
        check("自检用图片已生成", pngData != nil)

        let svc = NowPlayingService()
        var calls = 0
        var reply: String? = nil
        var deliverImage = false
        let fetch: () -> String? = {
            calls += 1
            if deliverImage, let d = pngData {
                try? d.write(to: URL(fileURLWithPath: svc.artworkPath))
            }
            return reply
        }
        let keyB = "music|Song B|A"

        // ① 点下一首：播放器已换歌，封面还没解出来
        reply = nil
        deliverImage = false
        let miss = svc.attachArtwork(snapshot("Song B"), key: keyB, fetch: fetch)
        check("① 封面未就绪时不显示图", miss.artwork == nil)
        check("① 确实尝试过读取", calls == 1)

        // ② 下一次轮询：同一首，封面就绪 —— 必须**重试**才拿得到
        reply = "Song B"
        deliverImage = true
        let before = calls
        let hit = svc.attachArtwork(snapshot("Song B"), key: keyB, fetch: fetch)
        check("② 失败后同一首仍会重试", calls == before + 1)
        check("② 重试拿到封面", hit.artwork != nil)
        check("② 拿到封面后配色也生效", hit.palette != nil)

        // ③ 同一首再轮询：走缓存，不再执行脚本
        let before3 = calls
        _ = svc.attachArtwork(snapshot("Song B"), key: keyB, fetch: fetch)
        check("③ 已解决后不再调用脚本", calls == before3)

        // ④ 又切了一首，脚本报回的却是另一首的曲名（两次调用之间又换歌了）
        reply = "Song D"
        deliverImage = true
        let mismatch = svc.attachArtwork(snapshot("Song C"), key: "music|Song C|A", fetch: fetch)
        check("④ 曲名对不上时不采用这张图", mismatch.artwork == nil)

        // ⑤ 真的没有封面的歌：连续失败到上限后停止重试，不许无限空转
        reply = nil
        deliverImage = false
        let keyNoArt = "music|NoArt|A"
        for _ in 0..<maxArtworkMisses {
            _ = svc.attachArtwork(snapshot("NoArt"), key: keyNoArt, fetch: fetch)
        }
        let before5 = calls
        _ = svc.attachArtwork(snapshot("NoArt"), key: keyNoArt, fetch: fetch)
        check("⑤ 放弃之后不再空转", calls == before5)

        // 顺带清掉临时文件，别把痕迹留在磁盘上
        try? FileManager.default.removeItem(atPath: png)
        try? FileManager.default.removeItem(atPath: svc.artworkPath)

        print(failures == 0 ? "\n封面逻辑全部通过" : "\n封面逻辑 \(failures) 项失败")
        return failures
    }
}
