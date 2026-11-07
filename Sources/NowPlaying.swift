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

/// 一次封面读取的结果。
/// 把「播放器说这首没有图」和「这次没读成」分开，是整块逻辑的地基：
/// 前者可以慢慢重试，后者必须尽快重试，而两者都**不能**被当成结论。
enum ArtworkRead {
    case image(NSImage)
    case noArtwork
    case failed(String)
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
            probeArtwork(expectedTitle: snap.title)
        }
    }

    // MARK: - 封面

    /// 真的拿到过封面的那一首（`tag|曲名|歌手`）。
    /// **只有成功才写这里。**「没拿到」永远不是结论，只是这一次没成——
    /// 一旦把「没拿到」记成结论，封面就再也回不来了，直到再换一首歌。
    private var resolvedArtworkKey = ""

    /// 当前这首的重试状态。换曲时整体重置。
    private var attemptKey = ""
    private var attempts = 0

    /// 下一次允许尝试的时刻（指数退避）。
    ///
    /// 这个节流是「点下一首没有封面」的真正成因。切歌之后 `control()` 会在
    /// 0.35 / 0.9 / 1.6 秒各强制刷一拍——而这三拍几乎必然早于封面就绪，
    /// 它们注定失败。早前的写法把「一首歌最多试 6 次」直接套在轮询次数上，
    /// 于是这三拍就白烧掉一半预算，真正的重试窗口只剩到第 6 秒；
    /// 而键盘切歌没有这几拍抢跑，6 次全落在 2 秒的常规轮询上，能撑到第 12 秒。
    /// 这正是「键盘切歌有时正常、点按钮几乎必现」的来源：
    /// 不是读取方式不同，是**重试预算被抢跑的几拍吃掉了**。
    ///
    /// 现在改成按时间退避（0.5 → 1 → 2 → 4 → 8 → 10 秒封顶），
    /// 抢跑的那几拍只会落在退避窗口里被直接跳过，不再消耗任何预算。
    private var nextAttemptAt = Date.distantPast

    /// 退避上限。不再有「放弃」这个终态之后，间隔必须封顶，
    /// 否则一首真的没有封面的歌会一路退避到几分钟才试一次。
    /// 封顶 10 秒：比常规轮询（2 秒）稀疏，但封面一旦晚到，
    /// 最多 10 秒就能自己补上，不用等换歌。
    private static let artworkRetryCap: TimeInterval = 10

    /// 把封面挂到快照上。
    ///
    /// 不变式：**key 只在真的拿到图时才提交**；失败只影响「下一次什么时候再试」，
    /// 不影响「这一首是不是还有机会」。
    private func attachArtwork(
        _ snap: NowPlayingSnapshot,
        key: String,
        fetch: () -> ArtworkRead
    ) -> NowPlayingSnapshot {
        var s = snap

        // 这一首已经拿到过封面：直接用缓存
        if key == resolvedArtworkKey, cachedArtwork != nil {
            s.artwork = cachedArtwork
            s.palette = cachedPalette
            return s
        }

        // 换了一首：重试计数、退避时刻、缓存图全部归零
        if key != attemptKey {
            attemptKey = key
            attempts = 0
            nextAttemptAt = .distantPast
            cachedArtwork = nil
            cachedPalette = nil
        }

        // 还在退避窗口里：这一拍不读脚本，只把「暂时没有封面」交出去。
        // 界面照常跟着曲目信息刷新，但不会有任何一次读取被白白浪费。
        guard Date() >= nextAttemptAt else {
            s.artwork = nil
            s.palette = nil
            return s
        }
        attempts += 1

        // 先删掉上一首留下的文件。否则这一首读失败时，
        // 下面那句 NSImage(contentsOfFile:) 会捡起旧图当成新封面。
        try? FileManager.default.removeItem(atPath: artworkPath)

        let result = fetch()
        lastArtworkReason = result
        switch result {
        case .image(let img):
            cachedArtwork = img
            // 配色只在换封面时算一次，之后跟着快照走，
            // 避免每 2 秒轮询都重新做一次像素统计。
            cachedPalette = AlbumPalette.extract(from: img)
            resolvedArtworkKey = key
            attempts = 0
            nextAttemptAt = .distantPast
            if logEnabled { NSLog("[NP] artwork ok key=%@", key) }

        case .noArtwork, .failed:
            // 两种失败都不提交 key。区别在起跳间隔上：
            // 播放器说「这首没有图」时慢慢试（2 秒起跳），
            // 脚本报错/超时这类临时故障尽快再来（0.5 秒起跳）。
            cachedArtwork = nil
            cachedPalette = nil
            var base: TimeInterval = 0.5
            if case .noArtwork = result { base = 2 }
            let backoff = min(Self.artworkRetryCap,
                              base * pow(2, Double(max(0, attempts - 1))))
            nextAttemptAt = Date().addingTimeInterval(backoff)
            if logEnabled {
                NSLog("[NP] artwork miss try=%d backoff=%.1fs reason=%@",
                      attempts, backoff, Self.describe(lastArtworkReason))
            }
        }

        // 读完就擦掉，别让封面图一直躺在临时目录里
        try? FileManager.default.removeItem(atPath: artworkPath)

        s.artwork = cachedArtwork
        s.palette = cachedPalette
        return s
    }

    /// 上一次失败的原因，只用于日志
    private var lastArtworkReason: ArtworkRead = .failed("-")

    private static func describe(_ r: ArtworkRead) -> String {
        switch r {
        case .image: return "image"
        case .noArtwork: return "no-artwork"
        case .failed(let why): return "failed(\(why))"
        }
    }

    /// 面板展开时调用：用户正看着这块地方，没封面就立刻再试一次，不等退避。
    /// 退避最长 10 秒，而人展开面板只会等一两秒——没有这个入口，
    /// 封面晚到的那次尝试就永远赶不上用户看它的那一刻。
    func retryArtworkNow() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.attemptKey == self.resolvedArtworkKey, self.cachedArtwork != nil { return }
            self.attempts = 0
            self.nextAttemptAt = .distantPast
            DispatchQueue.main.async { self.tick() }
        }
    }

    /// 读一次封面。三种结果必须分开，否则「还没就绪」会被当成「这首没有封面」：
    /// - `.image`：拿到图
    /// - `.noArtwork`：播放器明确说这首没有 artwork（`count of artworks = 0`）
    /// - `.failed`：脚本报错 / 超时 / 曲名对不上 / 图解不开——**临时故障，值得重试**
    ///
    /// 返回曲名是为了自证一致性：读元数据和读封面是两次 AppleScript 调用，
    /// 中间用户可能又切了一首。如果封面脚本报回的曲名和刚读到的元数据不一致，
    /// 这张图就不能认——否则会把 B 歌的封面挂到 A 歌名下，一直错到下次换曲。
    private func probeArtwork(expectedTitle: String) -> ArtworkRead {
        guard let out = runOSA(artworkScriptMusic()) else {
            return .failed("osascript-nil")
        }
        let f = out.components(separatedBy: Self.fieldSeparator)
        guard f.count >= 3 else {
            return .failed("parse:" + String(out.prefix(80)))
        }
        // 失败先按脚本自报的原因分类，再校验曲名——
        // 否则「播放器刚停」这种正常情况会被误报成 title-mismatch。
        if f[0] != "1" {
            if f[2] == "no-artwork" { return .noArtwork }
            if f[2] != "ok" { return .failed(f[2]) }
        }
        guard f[1] == expectedTitle else {
            return .failed("title-mismatch")
        }
        guard let img = NSImage(contentsOfFile: artworkPath), img.size.width > 1 else {
            // 脚本说写成功了，但 NSImage 解不开。把字节数带上，
            // 下次再出问题可以直接判断是「空文件」还是「格式不认识」。
            let attrs = try? FileManager.default.attributesOfItem(atPath: artworkPath)
            let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            return .failed("decode:\(bytes)B")
        }
        return .image(img)
    }

    private func artworkScriptMusic() -> String {
        """
        if application "Music" is running then
            tell application "Music"
                set ps to player state
                if ps is playing or ps is paused then
                    set sep to (ASCII character 31)
                    set tname to name of current track
                    try
                        if (count of artworks of current track) is 0 then
                            return "0" & sep & tname & sep & "no-artwork"
                        end if
                        set d to raw data of artwork 1 of current track
                        set p to POSIX file "\(artworkPath)"
                        set fh to open for access p with write permission
                        set eof fh to 0
                        write d to fh
                        close access fh
                        return "1" & sep & tname & sep & "ok"
                    on error errMsg number errNum
                        try
                            close access (POSIX file "\(artworkPath)")
                        end try
                        return "0" & sep & tname & sep & ("err " & errNum & ": " & errMsg)
                    end try
                end if
            end tell
        end if
        return "0" & (ASCII character 31) & "" & (ASCII character 31) & "not-playing"
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
        // 这三拍只负责「让曲目信息尽快跟上」，**不再负责封面**：
        // 它们注定早于封面就绪，所以 `attachArtwork` 对这几拍做了退避节流，
        // 不会让它们吃掉任何一次真正的重试机会（见 `nextAttemptAt`）。
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
    /// 守的两条不变式：
    /// 1. **读失败时不能把这一首记成已解决**——记了，这一整首就再也不会重试。
    /// 2. **切歌瞬间连刷的那几拍不能消耗重试预算**——它们注定扑空，
    ///    吃掉预算就等于把重试窗口提前关掉，这正是「点下一首没封面」的成因。
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
        var deliver = false
        let fetch: () -> ArtworkRead = {
            calls += 1
            if deliver, let d = pngData, let img = NSImage(data: d) { return .image(img) }
            return .noArtwork
        }
        let keyB = "music|Song B|A"

        // ① 点下一首：播放器已换歌，封面还没解出来
        let miss = svc.attachArtwork(snapshot("Song B"), key: keyB, fetch: fetch)
        check("① 封面未就绪时不显示图", miss.artwork == nil)
        check("① 确实尝试过读取", calls == 1)

        // ② 紧接着的抢跑拍（control() 的 0.35/0.9s）：必须被退避挡掉，
        //    不能消耗重试机会——这条是本次的回归点
        _ = svc.attachArtwork(snapshot("Song B"), key: keyB, fetch: fetch)
        _ = svc.attachArtwork(snapshot("Song B"), key: keyB, fetch: fetch)
        _ = svc.attachArtwork(snapshot("Song B"), key: keyB, fetch: fetch)
        check("② 抢跑拍不再调用脚本", calls == 1)

        // ③ 退避窗口过去后：同一首仍在重试，并拿到封面
        svc.nextAttemptAt = .distantPast
        deliver = true
        let hit = svc.attachArtwork(snapshot("Song B"), key: keyB, fetch: fetch)
        check("③ 失败后同一首仍会重试", calls == 2)
        check("③ 重试拿到封面", hit.artwork != nil)
        check("③ 拿到封面后配色也生效", hit.palette != nil)

        // ④ 同一首再轮询：走缓存，不再执行脚本
        svc.nextAttemptAt = .distantPast
        _ = svc.attachArtwork(snapshot("Song B"), key: keyB, fetch: fetch)
        check("④ 已解决后不再调用脚本", calls == 2)

        // ⑤ 换成一首迟迟没有封面的歌：连试 10 次都必须真的去试
        //    （旧实现在第 6 次就永久判死，封面再也不会出现）
        deliver = false
        let keyNoArt = "music|NoArt|A"
        for _ in 0..<10 {
            svc.nextAttemptAt = .distantPast
            _ = svc.attachArtwork(snapshot("NoArt"), key: keyNoArt, fetch: fetch)
        }
        check("⑤ 一直没封面也不会永久放弃", calls == 12)

        // ⑥ 换曲必须重置：上一首的失败不能算到下一首头上
        deliver = true
        let keyC = "music|Song C|A"
        let resumed = svc.attachArtwork(snapshot("Song C"), key: keyC, fetch: fetch)
        check("⑥ 换曲后立刻重试并拿到图", resumed.artwork != nil && calls == 13)

        // 顺带清掉临时文件，别把痕迹留在磁盘上
        try? FileManager.default.removeItem(atPath: svc.artworkPath)

        print(failures == 0 ? "\n封面逻辑全部通过" : "\n封面逻辑 \(failures) 项失败")
        return failures
    }
}
