import Foundation

public enum AppError: CaseIterable, LocalizedError {
    case invalidCredential, invalidRegistry, insecureDirectory, insecureFile, fileIO
    case keychainUnavailable, keychainRead, keychainWrite, keychainPath, credentialTooLong
    case keychainHexCheck, keychainHexFormat, protectedKeychainEntry, keychainDelete
    case snapshotVerification, snapshotDeletionVerification, watchUnreadable
    case signInRequired, unsavedAccount, activeChanged, accountMissing, invalidAlias, duplicateAlias
    case emptyPool, noOtherAccounts, allOthersCooling, missingSnapshot, snapshotMismatch
    case switchVerification, switchMetadataWrite, credentialRefreshing, localOperationFailed

    public init(redacting error: Error) {
        self = error as? Self ?? .localOperationFailed
    }

    public var errorDescription: String? { text.localized(in: AppLanguage.system.resolved()) }

    public var text: LocalizedText {
        switch self {
        case .invalidCredential:
            return .init("The agy credential has an invalid format or fields.", "agy 凭证格式或字段无效。")
        case .invalidRegistry:
            return .init("registry.json is invalid. Check the account pool metadata.", "registry.json 格式无效，请检查账号池元数据。")
        case .insecureDirectory:
            return .init("You must own the account pool and vault folders. Set their permissions to 0700.",
                         "账号池或 vault 目录必须归当前用户所有，且权限为 0700。")
        case .insecureFile:
            return .init("You must own the account pool and vault files. Set their permissions to 0600.",
                         "账号池或 vault 文件必须归当前用户所有，且权限为 0600。")
        case .fileIO:
            return .init("File operation failed. Check folder permissions and free disk space.", "本地文件操作失败，请检查目录权限与磁盘空间。")
        case .keychainUnavailable:
            return .init("Couldn’t run security, or the login Keychain timed out.", "无法执行 security，或登录钥匙串响应超时。")
        case .keychainRead:
            return .init("Couldn’t read the login Keychain. Check that it’s unlocked and accessible.", "读取登录钥匙串失败，请检查解锁状态及访问权限。")
        case .keychainWrite:
            return .init("Couldn’t write to the login Keychain. Check that it’s unlocked and accessible.", "写入登录钥匙串失败，请检查解锁状态及访问权限。")
        case .keychainPath:
            return .init("The login Keychain path is incompatible with security’s interactive mode.", "登录钥匙串路径不适用于 security 交互模式。")
        case .credentialTooLong:
            return .init("The credential exceeds the line limit in security’s interactive mode.", "凭证超过 security 交互模式单行上限。")
        case .keychainHexCheck:
            return .init("Couldn’t verify the Keychain credential’s hex encoding.", "无法核对钥匙串凭证的十六进制格式。")
        case .keychainHexFormat:
            return .init("Unrecognized hex encoding for the Keychain credential.", "无法识别钥匙串凭证的十六进制格式。")
        case .protectedKeychainEntry:
            return .init("Only saved account snapshots can be deleted.", "只能删除账号池快照。")
        case .keychainDelete:
            return .init("Couldn’t delete the saved snapshot. Check Keychain access.", "删除凭证快照失败，请检查钥匙串权限。")
        case .snapshotVerification:
            return .init("Couldn’t verify the saved credential snapshot.", "凭证快照回读校验失败。")
        case .snapshotDeletionVerification:
            return .init("The credential snapshot is still present after deletion.", "删除凭证快照后回读仍可见。")
        case .watchUnreadable:
            return .init("The logs or Keychain are temporarily unreadable.", "本轮日志或钥匙串暂不可读。")
        case .signInRequired:
            return .init("Sign in to agy before saving your account.", "当前 agy 未登录，请先完成 agy 登录。")
        case .unsavedAccount:
            return .init("Save your current account before switching.", "当前账号未纳管，请先保存当前账号。")
        case .activeChanged:
            return .init("Your agy login changed. Refresh and try again.", "当前 agy 登录已变化，请刷新后重试。")
        case .accountMissing:
            return .init("That account was removed. Refresh and try again.", "账号已从账号池移除，请刷新后重试。")
        case .invalidAlias:
            return .init("Start the alias with a letter or number. Use up to 48 letters, numbers, dots, underscores, or hyphens.",
                         "别名须以字母或数字开头，最多 48 个字符，可包含 . _ -。")
        case .duplicateAlias:
            return .init("Another account already uses that alias.", "该别名已被其他账号使用。")
        case .emptyPool:
            return .init("No saved accounts. Save your current account first.", "账号池为空，请先保存当前账号。")
        case .noOtherAccounts:
            return .init("There are no other accounts to switch to.", "账号池没有其他账号可切换。")
        case .allOthersCooling:
            return .init("All other accounts are on cooldown. Try again when one is available.", "其余账号都在冷却，请等到期后再切换。")
        case .missingSnapshot:
            return .init("The target account has no saved credentials. Sign in to it and save it again.", "目标账号缺少凭证快照，请重新登录该账号后保存。")
        case .snapshotMismatch:
            return .init("The saved credentials don’t match the target account.", "目标凭证快照与账号池记录不匹配。")
        case .switchVerification:
            return .init("Couldn’t verify the switch in the Keychain. Refresh to check the active account.", "切换后钥匙串回读不一致，请刷新确认当前账号。")
        case .switchMetadataWrite:
            return .init("Switched accounts, but couldn’t update the account’s last-used record.", "钥匙串已切换并通过回读，账号池使用记录写入失败。")
        case .credentialRefreshing:
            return .init("agy is refreshing its credentials. Try again shortly.", "当前 agy 凭证正在刷新，请稍后重试。")
        case .localOperationFailed:
            return .init("Local operation failed. Check access permissions and try again.", "本地操作失败，请检查访问权限后重试。")
        }
    }
}
