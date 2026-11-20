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
        let remainder = minutes % 60
        if remainder == 0 { return Self("\(hours)h", "\(hours) 小时") }
        return Self("\(hours)h \(remainder)m", "\(hours) 小时 \(remainder) 分钟")
    }

    public static func cooldownEndsIn(_ duration: Self) -> Self {
        Self("Cooldown ends in \(duration.english)", "冷却剩余 \(duration.chinese)")
    }

    public static func removeConfirmation(_ alias: String) -> Self {
        Self("This removes \(alias) and its saved credentials.", "将移除 \(alias) 的账号记录与凭证快照。")
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
        case 1: vault = Self("1 invalid snapshot", "1 个快照异常")
        default: vault = Self("\(invalidVaultCount) invalid snapshots", "\(invalidVaultCount) 个快照异常")
        }
        return Self("\(logs.english) · \(vault.english)", "\(logs.chinese) · \(vault.chinese)")
    }
}

public enum AppLabel: CaseIterable {
    case language, followSystem
    case listening, listenerUnavailable, listenerStopped, refresh, refreshHelp
    case enableLoginItem, disableLoginItem, openLogs, inspect, quit, more, moreHelp
    case unsavedAccount, save, noAccounts, noAccountsHint
    case autoSwitch, defaultCooldown, defaultCooldownHelp, autoSwitchHelp, switchNext, loadingPool
    case aliasPlaceholder, newAliasPlaceholder, rename, cancelEdit, confirmRemove, cancel, remove
    case active, available, clearCooldown, markCooldown, renameAlias, removeAccount
    case logsMissing, logsMissingHint, loginItemEnabled, loginItemDisabled, loginItemFailed
    case aliasUpdated, accountRemoved, cooldownMarked, cooldownCleared, poolRefreshed, reopenSession
    case signedOut, monitoring, signedIn, logsReadable, logsUnavailable, snapshotsVerified

    public var text: LocalizedText {
        switch self {
        case .language: return .init("Language", "语言")
        case .followSystem: return .init("Follow System", "跟随系统")
        case .listening: return .init("Watching local logs", "正在监听本地日志")
        case .listenerUnavailable: return .init("Log monitoring is off or unavailable", "日志监听已关闭或暂未连接")
        case .listenerStopped: return .init("Log monitoring inactive", "日志监听未运行")
        case .refresh: return .init("Refresh", "刷新")
        case .refreshHelp: return .init("Reload accounts and read the Keychain", "重读账号池与钥匙串")
        case .enableLoginItem: return .init("Open at Login", "登录时启动")
        case .disableLoginItem: return .init("Turn Off Open at Login", "关闭登录时启动")
        case .openLogs: return .init("Open Log Folder", "打开日志目录")
        case .inspect: return .init("Check Status", "检查状态")
        case .quit: return .init("Quit AgySwitch", "退出 AgySwitch")
        case .more: return .init("More", "更多")
        case .moreHelp: return .init("More actions", "更多操作")
        case .unsavedAccount: return .init("Unsaved account", "当前账号未纳管")
        case .save: return .init("Save", "保存")
        case .noAccounts: return .init("No saved accounts", "还没有账号")
        case .noAccountsHint: return .init("Sign in to agy to save your account here.", "登录 agy 后，可在这里保存当前账号。")
        case .autoSwitch: return .init("Auto-switch on quota limit", "额度耗尽自动切换")
        case .defaultCooldown: return .init("Default cooldown", "默认冷却时长")
        case .defaultCooldownHelp: return .init("Used when the logs give no reset time", "日志没有重置时间时使用此冷却时长")
        case .autoSwitchHelp: return .init("Watch local agy logs and skip accounts on cooldown", "读取本机 agy 日志，跳过冷却中的账号")
        case .switchNext: return .init("Switch to Next Available", "切到下一个可用账号")
        case .loadingPool: return .init("Accessing saved accounts", "正在访问账号池")
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
        case .renameAlias: return .init("Rename Account", "重命名别名")
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
        case .poolRefreshed: return .init("Accounts refreshed", "账号池已刷新")
        case .reopenSession: return .init("Reopen or restart your agy / T3 session", "新开或重启 agy / T3 会话生效")
        case .signedOut: return .init("Not signed in", "未登录")
        case .monitoring: return .init("Monitoring logs", "监听中")
        case .signedIn: return .init("Signed in", "当前登录可读")
        case .logsReadable: return .init("Logs readable", "日志可读")
        case .logsUnavailable: return .init("Logs missing or unreadable", "日志目录缺失或不可读")
        case .snapshotsVerified: return .init("Snapshots verified", "快照检查通过")
        }
    }
}
