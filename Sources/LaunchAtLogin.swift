import AppKit
import ServiceManagement

/// 开机自启。
///
/// 用 `SMAppService.mainApp`：登记进系统「登录项」，用户能在
/// 「系统设置 › 通用 › 登录项」里看见、也能自己关掉。
///
/// 刻意不写 `~/Library/LaunchAgents` 里的 plist——那个位置用户看不见，
/// 应用被删掉后还会留下一条失效的启动项，对这么小的一个组件来说太脏。
enum LaunchAtLogin {

    /// 当前是否已登记并生效
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 已登记，但系统要求用户去「登录项」里再确认一次
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// 给诊断日志用
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    /// 当前运行位置是否不适合做登录项。
    ///
    /// 从 DMG 里直接运行时路径在 `/Volumes/...`，重启后那个卷已经不在了，
    /// 登录项必然失效；被 Gatekeeper 隔离时路径里会出现 `/AppTranslocation/`，
    /// 同理。这种情况要在用户点开关的当下就说清楚，而不是等下次开机才发现没启动。
    static var locationWarning: String? {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") {
            return "当前是从下载位置临时运行的。请把 Limen 拖到「应用程序」文件夹，再从那里打开。"
        }
        if path.hasPrefix("/Volumes/") {
            return "当前是从磁盘映像里运行的。请把 Limen 拖到「应用程序」文件夹，再从那里打开。"
        }
        return nil
    }

    /// 开或关。返回 `nil` 表示成功；否则是给用户看的原因。
    @discardableResult
    static func set(_ on: Bool) -> String? {
        // 从 DMG / 临时转写目录里运行时，登记了也撑不过一次重启
        // （卷已经不在了）。与其让它悄悄失效，不如当场说清楚。
        if on, let warning = locationWarning {
            return warning
        }

        let service = SMAppService.mainApp
        do {
            if on {
                guard service.status != .enabled else { return nil }
                try service.register()
                if service.status == .requiresApproval {
                    return "已经登记，但还需要你在「系统设置 › 通用 › 登录项」里允许 Limen。"
                }
                return nil
            } else {
                guard service.status != .notRegistered else { return nil }
                try service.unregister()
                return nil
            }
        } catch {
            let hint = locationWarning.map { "\n\n\($0)" } ?? ""
            return "系统没有接受这次改动：\(error.localizedDescription)\(hint)"
        }
    }

    /// 跳到「登录项」设置页
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
