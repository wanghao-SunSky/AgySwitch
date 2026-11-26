import Foundation

public struct LocalizedText: Equatable {
    private let english: String
    private let chinese: String

    init(_ english: String, _ chinese: String) {
        self.english = english
        self.chinese = chinese
    }

    public func localized(in language: DisplayLanguage) -> String {
        switch language {
        case .en: return english
        case .zhHans: return chinese
        }
    }

    public static func hours(_ hours: Int) -> Self {
        Self(hours == 1 ? "1 hour" : "\(hours) hours", "\(hours) 小时")
    }

    public static func cooldownCountdown(_ seconds: Double) -> Self {
        let total = max(1, Int(ceil(seconds)))
        if total < 60 { return Self("\(total)s", "\(total) 秒") }
        let minutes = total / 60
        if minutes < 60 { return Self("\(minutes)m", "\(minutes) 分钟") }
        let hours = minutes / 60
        if hours >= 24 {
            let days = hours / 24, rest = hours % 24
            return rest == 0 ? Self("\(days)d", "\(days) 天")
                : Self("\(days)d \(rest)h", "\(days) 天 \(rest) 小时")
        }
        let remainder = minutes % 60
        if remainder == 0 { return Self("\(hours)h", "\(hours) 小时") }
        return Self("\(hours)h \(remainder)m", "\(hours) 小时 \(remainder) 分钟")
    }

    public static func cooldownEndsIn(_ duration: Self) -> Self {
        Self("Cooldown ends in \(duration.english)", "冷却剩余 \(duration.chinese)")
    }

    public static func removeConfirmation(_ alias: String) -> Self {
        Self("This removes \(alias) and its saved credentials.", "将移除 \(alias) 及其保存的登录信息。")
    }

    public static func saved(_ alias: String) -> Self {
        Self("Saved \(alias)", "已保存 \(alias)")
    }

    public static func alreadyUsing(_ alias: String) -> Self {
        Self("Already using \(alias)", "正在使用 \(alias)")
    }

    public static func switched(_ alias: String) -> Self {
        Self("Switched to \(alias)", "已切至 \(alias)")
    }

    public static func reloadSummary(_ result: ClientReloadOutcome) -> Self {
        var parts: [Self] = []
        switch result.desktop {
        case .absent: break
        case .restarted: parts.append(Self("Antigravity restarted", "桌面版已重开"))
        case .stillRunning: parts.append(Self("Antigravity is still running", "桌面版仍在运行"))
        case .failed: parts.append(Self("Couldn’t reopen Antigravity", "桌面版重开失败"))
        }
        if result.reloadedAcpCount > 0 {
            parts.append(Self("T3 backends stopped (\(result.reloadedAcpCount))", "T3 后端已退出 (\(result.reloadedAcpCount))"))
        }
        if result.stoppedCliCount > 0 {
            parts.append(Self("agy sessions stopped (\(result.stoppedCliCount))", "agy 会话已退出 (\(result.stoppedCliCount))"))
        }
        if result.unfinishedProcesses > 0 {
            parts.append(Self("Still running (\(result.unfinishedProcesses))", "仍在运行 (\(result.unfinishedProcesses))"))
        }
        if result.credentialVerificationFailed { parts.append(Self("Login verification failed", "钥匙串账号复核失败")) }
        if result.processScanFailed { parts.append(Self("Couldn’t check agy processes", "无法检查 agy 进程")) }
        guard !parts.isEmpty else { return Self("No running clients found", "未检测到运行中的客户端") }
        return Self(parts.map(\.english).joined(separator: " · "), parts.map(\.chinese).joined(separator: " · "))
    }

    public static func statusTitle(signedIn: Bool, accountCount: Int) -> Self {
        let login = (signedIn ? AppLabel.signedIn : .signedOut).text
        let accounts = accountCount == 1 ? "1 account" : "\(accountCount) accounts"
        return Self("\(login.english) · \(accounts)", "\(login.chinese) · \(accountCount) 个账号")
    }

    public static func statusDetail(logsReadable: Bool, invalidVaultCount: Int) -> Self {
        let logs = (logsReadable ? AppLabel.logsReadable : .logsUnavailable).text
        let vault: Self
        switch invalidVaultCount {
        case 0: vault = AppLabel.snapshotsVerified.text
        case 1: vault = Self("1 invalid snapshot", "1 个账号的登录信息有问题")
        default: vault = Self("\(invalidVaultCount) invalid snapshots", "\(invalidVaultCount) 个账号的登录信息有问题")
        }
        return Self("\(logs.english) · \(vault.english)", "\(logs.chinese) · \(vault.chinese)")
    }
}

public enum AppLabel: CaseIterable {
    case autoReload, reloadMenu, reloadClients, reloadingClients, reloadResult
    case fiveHourRemaining, weeklyRemaining
    case quotaOnHover, loadingQuota, quotaFailed, quotaExpired, resetsIn
    case language, followSystem
    case listening, listenerStopped, refresh
    case enableLoginItem, disableLoginItem, openLogs, inspect, quit, more
    case addAccount, signInToAnotherAccount, addAccountGuide, manualSignInGuide
    case addAccountAfterLaunch, addFirstAccountAfterLaunch, reopenSignIn
    case unsavedAccount, save, noAccounts, noAccountsHint
    case autoSwitch, defaultCooldown, switchNext, working
    case aliasPlaceholder, newAliasPlaceholder, rename, cancelEdit, confirmRemove, cancel, remove
    case active, available, clearCooldown, markCooldown, renameAlias, removeAccount
    case logsMissing, logsMissingHint, loginItemEnabled, loginItemDisabled, loginItemFailed
    case aliasUpdated, accountRemoved, cooldownMarked, cooldownCleared, poolRefreshed, reopenSession
    case signedOut, monitoring, signedIn, logsReadable, logsUnavailable, snapshotsVerified

    public var text: LocalizedText {
        switch self {
        case .fiveHourRemaining: return .init("5h remaining", "5 小时剩余")
        case .weeklyRemaining: return .init("Weekly remaining", "周额度剩余")
        case .quotaOnHover: return .init("Quota on Hover", "悬停查看额度")
        case .loadingQuota: return .init("Loading quota…", "正在获取额度…")
        case .quotaFailed: return .init("Quota unavailable", "暂时无法获取额度")
        case .quotaExpired: return .init("Sign-in expired. Switch to this account and sign in again in agy", "登录已失效，请切到此账号并重新登录 agy")
        case .resetsIn: return .init("Resets in", "重置剩余")
        case .autoReload: return .init("Auto-Reload Clients on Switch", "切号后自动重载客户端")
        case .reloadMenu: return .init("Reload agy & Desktop", "重载 agy 与桌面版")
        case .reloadClients: return .init("Reload Clients", "立即重载")
        case .reloadingClients: return .init("Reloading clients…", "正在重载客户端…")
        case .reloadResult: return .init("Client reload", "客户端重载结果")
        case .language: return .init("Language", "语言")
        case .followSystem: return .init("Follow System", "跟随系统")
        case .listening: return .init("Watching local logs", "正在监听本地日志")
        case .listenerStopped: return .init("Log monitoring inactive", "日志监听未运行")
        case .refresh: return .init("Refresh", "刷新")
        case .enableLoginItem: return .init("Open at Login", "登录时启动")
        case .disableLoginItem: return .init("Turn Off Open at Login", "关闭登录时启动")
        case .openLogs: return .init("Open Log Folder", "打开日志目录")
        case .inspect: return .init("Check Status", "检查状态")
        case .quit: return .init("Quit AgySwitch", "退出 AgySwitch")
        case .more: return .init("More", "更多")
        case .addAccount: return .init("Add Account", "添加账号")
        case .signInToAnotherAccount: return .init("Sign In to Another Account", "登录新账号")
        case .addAccountGuide:
            return .init("Quit any running agy sessions first. Your current account is saved before Terminal opens. After signing in, come back and click Save.",
                         "先退出正在运行的 agy。AgySwitch 会先保存当前账号。浏览器登录新账号后，回来点「保存」。")
        case .manualSignInGuide:
            return .init("To sign in manually, save your current account, run /logout in agy, then restart agy.",
                         "也可先保存当前账号，在 agy 中运行 /logout，再重新启动 agy。")
        case .addAccountAfterLaunch:
            return .init("agy sign-in opened in Terminal. Finish in your browser, then come back and click Save. Click a saved account below to switch back.",
                         "已在终端启动 agy。请在浏览器完成登录，再回来点「保存」。随时可点下方原账号切回。")
        case .addFirstAccountAfterLaunch:
            return .init("agy sign-in opened in Terminal. Finish in your browser, then come back and click Save.",
                         "已在终端启动 agy。请在浏览器完成登录，再回来点「保存」。")
        case .reopenSignIn: return .init("Reopen Sign-In", "重新打开登录")
        case .unsavedAccount: return .init("Unsaved account", "当前账号尚未保存")
        case .save: return .init("Save", "保存")
        case .noAccounts: return .init("No saved accounts", "还没有账号")
        case .noAccountsHint: return .init("Sign in to agy to save your account here.", "登录 agy 后，可在这里保存当前账号。")
        case .autoSwitch: return .init("Auto-switch on quota limit", "额度耗尽自动切换")
        case .defaultCooldown: return .init("Default cooldown", "默认冷却时长")
        case .switchNext: return .init("Switch to Next Available", "切到下一个可用账号")
        case .working: return .init("Working on your request", "正在处理")
        case .aliasPlaceholder: return .init("Account alias", "账号别名")
        case .newAliasPlaceholder: return .init("New alias", "新别名")
        case .rename: return .init("Rename", "更名")
        case .cancelEdit: return .init("Cancel editing", "取消编辑")
        case .confirmRemove: return .init("Remove Account?", "移除账号？")
        case .cancel: return .init("Cancel", "取消")
        case .remove: return .init("Remove", "移除")
        case .active: return .init("Active", "使用中")
        case .available: return .init("Available", "可用")
        case .clearCooldown: return .init("Clear Cooldown", "清除冷却")
        case .markCooldown: return .init("Start Cooldown", "标记冷却")
        case .renameAlias: return .init("Rename Account", "修改账号别名")
        case .removeAccount: return .init("Remove Account", "移除账号")
        case .logsMissing: return .init("Log folder hasn’t been created yet", "日志目录尚未创建")
        case .logsMissingHint: return .init("Run agy to create it.", "运行 agy 后可在这里打开。")
        case .loginItemEnabled: return .init("AgySwitch will open at your next login", "下次登录时启动")
        case .loginItemDisabled: return .init("Open at Login turned off", "已关闭登录时启动")
        case .loginItemFailed: return .init("Couldn’t update Open at Login", "无法更新登录时启动设置")
        case .aliasUpdated: return .init("Alias updated", "别名已更新")
        case .accountRemoved: return .init("Account removed", "已移除账号")
        case .cooldownMarked: return .init("Cooldown started", "已标记冷却")
        case .cooldownCleared: return .init("Cooldown cleared", "已清除冷却")
        case .poolRefreshed: return .init("Accounts refreshed", "已刷新账号列表")
        case .reopenSession: return .init("Reopen or restart your agy / T3 session", "新开或重启 agy / T3 会话生效")
        case .signedOut: return .init("Not signed in", "未登录")
        case .monitoring: return .init("Monitoring logs", "监听中")
        case .signedIn: return .init("Signed in", "已登录")
        case .logsReadable: return .init("Logs readable", "日志可读")
        case .logsUnavailable: return .init("Logs missing or unreadable", "日志目录缺失或不可读")
        case .snapshotsVerified: return .init("Snapshots verified", "已保存的登录信息正常")
        }
    }
}
