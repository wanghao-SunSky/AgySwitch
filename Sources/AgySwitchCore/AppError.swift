import Foundation

public enum AppError: CaseIterable, LocalizedError {
    case invalidCredential, invalidRegistry, insecureDirectory, insecureFile, fileIO
    case keychainUnavailable, keychainRead, keychainWrite, keychainPath, credentialTooLong
    case keychainHexCheck, keychainHexFormat, protectedKeychainEntry, keychainDelete
    case snapshotVerification, snapshotDeletionVerification, watchUnreadable
    case signInRequired, unsavedAccount, activeChanged, accountMissing, invalidAlias, duplicateAlias
    case emptyPool, noOtherAccounts, allOthersCooling, missingSnapshot, snapshotMismatch
    case switchVerification, switchMetadataWrite, credentialRefreshing, localOperationFailed
    case activeLoginDelete, activeLoginVerification, agyNotFound, terminalLaunch

    public init(redacting error: Error) {
        self = error as? Self ?? .localOperationFailed
    }

    public var errorDescription: String? { text.localized(in: AppLanguage.system.resolved()) }

    public var text: LocalizedText {
        switch self {
        case .invalidCredential:
            return .init("The agy credential has an invalid format or fields.", "无法识别 agy 的登录信息。")
        case .invalidRegistry:
            return .init("registry.json is invalid. Check the account pool metadata.", "账号列表文件 registry.json 有误，请检查文件内容。")
        case .insecureDirectory:
            return .init("You must own the account pool and vault folders. Set their permissions to 0700.",
                         "账号数据文件夹必须归当前用户所有，且仅允许当前用户访问（权限 0700）。")
        case .insecureFile:
            return .init("You must own the account pool and vault files. Set their permissions to 0600.",
                         "账号数据文件必须归当前用户所有，且仅允许当前用户读写（权限 0600）。")
        case .fileIO:
            return .init("File operation failed. Check folder permissions and free disk space.", "本地文件操作失败，请检查目录权限与磁盘空间。")
        case .keychainUnavailable:
            return .init("Couldn’t run security, or the login Keychain timed out.", "系统钥匙串暂时没有响应，请稍后重试。")
        case .keychainRead:
            return .init("Couldn’t read the login Keychain. Check that it’s unlocked and accessible.", "读取登录钥匙串失败，请检查解锁状态及访问权限。")
        case .keychainWrite:
            return .init("Couldn’t write to the login Keychain. Check that it’s unlocked and accessible.", "写入登录钥匙串失败，请检查解锁状态及访问权限。")
        case .keychainPath:
            return .init("The login Keychain path is incompatible with security’s interactive mode.", "无法从当前位置打开登录钥匙串。")
        case .credentialTooLong:
            return .init("The credential exceeds the line limit in security’s interactive mode.", "账号登录信息太长，无法写入钥匙串。")
        case .keychainHexCheck:
            return .init("Couldn’t verify the Keychain credential’s hex encoding.", "无法确认钥匙串里的登录信息。")
        case .keychainHexFormat:
            return .init("Unrecognized hex encoding for the Keychain credential.", "无法识别钥匙串里的登录信息。")
        case .protectedKeychainEntry:
            return .init("Only saved account snapshots can be deleted.", "此操作只能移除已保存的登录信息。")
        case .keychainDelete:
            return .init("Couldn’t delete the saved snapshot. Check Keychain access.", "无法移除已保存的登录信息，请检查钥匙串权限。")
        case .snapshotVerification:
            return .init("Couldn’t verify the saved credential snapshot.", "无法确认账号已保存，请重试。")
        case .snapshotDeletionVerification:
            return .init("The credential snapshot is still present after deletion.", "保存的登录信息仍在，请重试移除操作。")
        case .watchUnreadable:
            return .init("The logs or Keychain are temporarily unreadable.", "暂时无法读取日志或钥匙串。")
        case .signInRequired:
            return .init("Sign in to agy before saving your account.", "当前 agy 未登录，请先完成 agy 登录。")
        case .unsavedAccount:
            return .init("Save your current account before switching.", "当前账号尚未保存，请先保存后再切换。")
        case .activeChanged:
            return .init("Your agy login changed. Refresh and try again.", "当前 agy 登录已变化，请刷新后重试。")
        case .accountMissing:
            return .init("That account was removed. Refresh and try again.", "这个账号已被移除，请刷新列表。")
        case .invalidAlias:
            return .init("Start the alias with a letter or number. Use up to 48 letters, numbers, dots, underscores, or hyphens.",
                         "别名须以字母或数字开头，最多 48 个字符，可包含 . _ -。")
        case .duplicateAlias:
            return .init("Another account already uses that alias.", "该别名已被其他账号使用。")
        case .emptyPool:
            return .init("No saved accounts. Save your current account first.", "还没有保存的账号，请先保存当前账号。")
        case .noOtherAccounts:
            return .init("There are no other accounts to switch to.", "还没有其他账号可以切换。")
        case .allOthersCooling:
            return .init("All other accounts are on cooldown. Try again when one is available.", "其余账号都在冷却，请等到期后再切换。")
        case .missingSnapshot:
            return .init("The target account has no saved credentials. Sign in to it and save it again.", "找不到这个账号的登录信息，请重新登录后保存。")
        case .snapshotMismatch:
            return .init("The saved credentials don’t match the target account.", "保存的登录信息与要切换的账号不符。")
        case .switchVerification:
            return .init("Couldn’t verify the switch in the Keychain. Refresh to check the active account.", "无法确认切换成功，请刷新查看当前账号。")
        case .switchMetadataWrite:
            return .init("Switched accounts, but couldn’t update the account’s last-used record.", "已切换账号，上次使用时间未能更新。")
        case .credentialRefreshing:
            return .init("agy is refreshing its credentials. Try again shortly.", "agy 正在更新登录信息，请稍后重试。")
        case .localOperationFailed:
            return .init("Local operation failed. Check access permissions and try again.", "本地操作失败，请检查访问权限后重试。")
        case .activeLoginDelete:
            return .init("Couldn’t sign out of the current agy account. Check Keychain access and try again.",
                         "无法退出当前 agy 账号，请检查钥匙串权限后重试。")
        case .activeLoginVerification:
            return .init("The current agy account is still signed in. Close any running agy sessions and try again.",
                         "agy 仍处于登录状态，请退出正在运行的 agy 后重试。")
        case .agyNotFound:
            return .init("Couldn’t find agy. Install the Antigravity CLI and try again.",
                         "找不到 agy，请安装 Antigravity 命令行工具后重试。")
        case .terminalLaunch:
            return .init("Couldn’t start agy in Terminal. Open Terminal and run agy to sign in.",
                         "未能在终端启动 agy。可以打开终端，手动运行 agy 登录。")
        }
    }
}
