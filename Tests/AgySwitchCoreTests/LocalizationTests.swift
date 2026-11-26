import XCTest
@testable import AgySwitchCore

final class LocalizationTests: XCTestCase {
    func testSystemFollowsOnlyTheFirstPreferredLanguage() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]), .zhHans)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-US"]), .en)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ja-JP", "zh-Hans"]), .en)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ja-JP"]), .en)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), .en)
    }

    func testExplicitLanguageOverridesSystemPreference() {
        XCTAssertEqual(AppLanguage.en.resolved(preferredLanguages: ["zh-Hans-CN"]), .en)
        XCTAssertEqual(AppLanguage.zhHans.resolved(preferredLanguages: ["en-US"]), .zhHans)
    }

    func testEveryLabelHasBothTranslations() {
        for label in AppLabel.allCases { assertBilingual(label.text) }

        XCTAssertEqual(DisplayLanguage.en[.unsavedAccount], "Unsaved account")
        XCTAssertEqual(DisplayLanguage.zhHans[.unsavedAccount], "当前账号尚未保存")
        XCTAssertEqual(DisplayLanguage.en[.switchNext], "Switch to Next Available")
        XCTAssertEqual(DisplayLanguage.zhHans[.switchNext], "切到下一个可用账号")
        XCTAssertEqual(AppLanguage.system.menuTitle(in: .en), "Follow System")
        XCTAssertEqual(AppLanguage.system.menuTitle(in: .zhHans), "跟随系统")
        for language in DisplayLanguage.allCases {
            XCTAssertEqual(AppLanguage.en.menuTitle(in: language), "English")
            XCTAssertEqual(AppLanguage.zhHans.menuTitle(in: language), "简体中文")
        }
    }

    func testQuotaRiskLabels() {
        for (label, english, chinese) in [
            (AppLabel.quotaRiskMenu, "Quota Check Disabled (Safety)", "额度查询已停用（防风控）"),
            (.quotaRiskTitle, "Internal quota API check removed", "已移除内部额度接口查询"),
            (.quotaRiskDetail, "Google warns calling internal quota APIs may flag accounts. Check limits in official clients.",
             "Google 提示调用内部配额接口可能触发账号标记，请在官方客户端查看额度")
        ] {
            XCTAssertEqual(DisplayLanguage.en[label], english)
            XCTAssertEqual(DisplayLanguage.zhHans[label], chinese)
        }
    }

    func testReloadLabelsAndResultVariants() {
        for (label, english, chinese) in [
            (AppLabel.autoReload, "Auto-Reload Clients on Switch", "切号后自动重载客户端"),
            (.reloadMenu, "Reload agy & Desktop", "重载 agy 与桌面版"),
            (.reloadClients, "Reload Clients", "立即重载"),
            (.reloadingClients, "Reloading clients…", "正在重载客户端…"),
            (.reloadResult, "Client reload", "客户端重载结果")
        ] {
            XCTAssertEqual(label.text.localized(in: .en), english)
            XCTAssertEqual(label.text.localized(in: .zhHans), chinese)
        }
        var result = ClientReloadOutcome()
        func check(_ english: String, _ chinese: String) {
            let text = LocalizedText.reloadSummary(result)
            XCTAssertEqual(text.localized(in: .en), english)
            XCTAssertEqual(text.localized(in: .zhHans), chinese)
            assertBilingual(text)
        }
        check("No running clients found", "未检测到运行中的客户端")
        result.desktop = .stillRunning
        check("Antigravity is still running", "桌面版仍在运行")
        result.desktop = .failed
        check("Couldn’t reopen Antigravity", "桌面版重开失败")
        result.desktop = .restarted
        result.reloadedAcpCount = 2
        result.stoppedCliCount = 1
        check("Antigravity restarted · T3 backends stopped (2) · agy sessions stopped (1)",
              "桌面版已重开 · T3 后端已退出 (2) · agy 会话已退出 (1)")
        result = ClientReloadOutcome()
        result.unfinishedProcesses = 2
        result.processScanFailed = true
        check("Still running (2) · Couldn’t check agy processes", "仍在运行 (2) · 无法检查 agy 进程")
    }

    func testParameterizedMessagesUseLocalizedGrammarAndInterpolateValues() {
        let examples: [(LocalizedText, String, String)] = [
            (.hours(1), "1 hour", "1 小时"),
            (.hours(5), "5 hours", "5 小时"),
            (.cooldownCountdown(37), "37s", "37 秒"),
            (.cooldownCountdown(60), "1m", "1 分钟"),
            (.cooldownCountdown(3600), "1h", "1 小时"),
            (.cooldownEndsIn(.cooldownCountdown(15120)), "Cooldown ends in 4h 12m", "冷却剩余 4 小时 12 分钟"),
            (.removeConfirmation("backup"), "This removes backup and its saved credentials.", "将移除 backup 及其保存的登录信息。"),
            (.saved("backup"), "Saved backup", "已保存 backup"),
            (.alreadyUsing("backup"), "Already using backup", "正在使用 backup"),
            (.switched("backup"), "Switched to backup", "已切至 backup"),
            (.statusTitle(signedIn: true, accountCount: 1), "Signed in · 1 account", "已登录 · 1 个账号"),
            (.statusTitle(signedIn: false, accountCount: 0), "Not signed in · 0 accounts", "未登录 · 0 个账号"),
            (.statusDetail(logsReadable: true, invalidVaultCount: 0), "Logs readable · Snapshots verified", "日志可读 · 已保存的登录信息正常"),
            (.statusDetail(logsReadable: false, invalidVaultCount: 1), "Logs missing or unreadable · 1 invalid snapshot",
             "日志目录缺失或不可读 · 1 个账号的登录信息有问题"),
            (.statusDetail(logsReadable: true, invalidVaultCount: 3), "Logs readable · 3 invalid snapshots",
             "日志可读 · 3 个账号的登录信息有问题")
        ]
        for (text, english, chinese) in examples {
            XCTAssertEqual(text.localized(in: .en), english)
            XCTAssertEqual(text.localized(in: .zhHans), chinese)
            assertNoPlaceholders(text)
            assertPlainChinese(text)
        }
    }

    func testAddAccountCopyExplainsBothSignInPathsAndHowToSwitchBack() {
        XCTAssertEqual(DisplayLanguage.en[.addAccount], "Add Account")
        XCTAssertEqual(DisplayLanguage.zhHans[.addAccount], "添加账号")
        XCTAssertEqual(DisplayLanguage.en[.signInToAnotherAccount], "Sign In to Another Account")
        XCTAssertEqual(DisplayLanguage.zhHans[.signInToAnotherAccount], "登录新账号")
        for language in DisplayLanguage.allCases {
            XCTAssertTrue(language[.manualSignInGuide].contains("/logout"))
            XCTAssertTrue(language[.addAccountAfterLaunch].contains(language[.save]))
            XCTAssertTrue(language[.addFirstAccountAfterLaunch].contains(language[.save]))
        }
        XCTAssertTrue(DisplayLanguage.en[.addAccountAfterLaunch].contains("switch back"))
        XCTAssertTrue(DisplayLanguage.zhHans[.addAccountAfterLaunch].contains("点下方原账号切回"))
    }

    func testEveryTypedErrorHasSafeTranslationsAndUnknownErrorsAreRedacted() {
        for error in AppError.allCases {
            XCTAssertEqual(AppError(redacting: error), error)
            assertBilingual(error.text)
        }
        XCTAssertEqual(AppError.unsavedAccount.text.localized(in: .en), "Save your current account before switching.")
        XCTAssertEqual(AppError.unsavedAccount.text.localized(in: .zhHans), "当前账号尚未保存，请先保存后再切换。")

        let marker = "synthetic-refresh-token-do-not-display"
        let unknown = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: marker])
        let safeError = AppError(redacting: unknown)
        XCTAssertEqual(safeError, .localOperationFailed)
        for language in DisplayLanguage.allCases {
            XCTAssertFalse(safeError.text.localized(in: language).contains(marker))
        }
    }

    private func assertBilingual(_ text: LocalizedText, file: StaticString = #filePath, line: UInt = #line) {
        let english = text.localized(in: .en)
        let chinese = text.localized(in: .zhHans)
        XCTAssertNotNil(english.range(of: "[A-Za-z]", options: .regularExpression), english, file: file, line: line)
        XCTAssertNil(english.range(of: #"\p{sc=Han}"#, options: .regularExpression), english, file: file, line: line)
        XCTAssertNotNil(chinese.range(of: #"\p{sc=Han}"#, options: .regularExpression), chinese, file: file, line: line)
        assertNoPlaceholders(text, file: file, line: line)
        assertPlainChinese(text, file: file, line: line)
    }

    private func assertPlainChinese(_ text: LocalizedText, file: StaticString = #filePath, line: UInt = #line) {
        let chinese = text.localized(in: .zhHans)
        for term in ["\u{7EB3}\u{7BA1}", "\u{69FD}\u{4F4D}", "vault"] {
            XCTAssertFalse(chinese.localizedCaseInsensitiveContains(term), chinese, file: file, line: line)
        }
    }

    private func assertNoPlaceholders(_ text: LocalizedText, file: StaticString = #filePath, line: UInt = #line) {
        for language in DisplayLanguage.allCases {
            let value = text.localized(in: language)
            XCTAssertNil(value.range(of: #"%(?:[0-9]+\$)?[@a-zA-Z]|\{\{[^}]+\}\}|\\\("#, options: .regularExpression),
                         value, file: file, line: line)
        }
    }
}
