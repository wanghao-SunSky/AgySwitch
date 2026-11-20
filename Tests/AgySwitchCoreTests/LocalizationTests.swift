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
        XCTAssertEqual(DisplayLanguage.zhHans[.unsavedAccount], "当前账号未纳管")
        XCTAssertEqual(DisplayLanguage.en[.switchNext], "Switch to Next Available")
        XCTAssertEqual(DisplayLanguage.zhHans[.switchNext], "切到下一个可用账号")
        XCTAssertEqual(AppLanguage.system.menuTitle(in: .en), "Follow System")
        XCTAssertEqual(AppLanguage.system.menuTitle(in: .zhHans), "跟随系统")
        for language in DisplayLanguage.allCases {
            XCTAssertEqual(AppLanguage.en.menuTitle(in: language), "English")
            XCTAssertEqual(AppLanguage.zhHans.menuTitle(in: language), "简体中文")
        }
    }

    func testParameterizedMessagesUseLocalizedGrammarAndInterpolateValues() {
        let examples: [(LocalizedText, String, String)] = [
            (.hours(1), "1 hour", "1 小时"),
            (.hours(5), "5 hours", "5 小时"),
            (.cooldownCountdown(37), "37s", "37 秒"),
            (.cooldownCountdown(60), "1m", "1 分钟"),
            (.cooldownCountdown(3600), "1h", "1 小时"),
            (.cooldownEndsIn(.cooldownCountdown(15120)), "Cooldown ends in 4h 12m", "冷却剩余 4 小时 12 分钟"),
            (.removeConfirmation("backup"), "This removes backup and its saved credentials.", "将移除 backup 的账号记录与凭证快照。"),
            (.saved("backup"), "Saved backup", "已保存 backup"),
            (.alreadyUsing("backup"), "Already using backup", "正在使用 backup"),
            (.switched("backup"), "Switched to backup", "已切至 backup"),
            (.statusTitle(signedIn: true, accountCount: 1), "Signed in · 1 account", "当前登录可读 · 1 个账号"),
            (.statusTitle(signedIn: false, accountCount: 0), "Not signed in · 0 accounts", "未登录 · 0 个账号"),
            (.statusDetail(logsReadable: true, invalidVaultCount: 0), "Logs readable · Snapshots verified", "日志可读 · 快照检查通过"),
            (.statusDetail(logsReadable: false, invalidVaultCount: 1), "Logs missing or unreadable · 1 invalid snapshot",
             "日志目录缺失或不可读 · 1 个快照异常"),
            (.statusDetail(logsReadable: true, invalidVaultCount: 3), "Logs readable · 3 invalid snapshots", "日志可读 · 3 个快照异常")
        ]
        for (text, english, chinese) in examples {
            XCTAssertEqual(text.localized(in: .en), english)
            XCTAssertEqual(text.localized(in: .zhHans), chinese)
            assertNoPlaceholders(text)
        }
    }

    func testEveryTypedErrorHasSafeTranslationsAndUnknownErrorsAreRedacted() {
        for error in AppError.allCases {
            XCTAssertEqual(AppError(redacting: error), error)
            assertBilingual(error.text)
        }
        XCTAssertEqual(AppError.unsavedAccount.text.localized(in: .en), "Save your current account before switching.")

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
        XCTAssertNil(english.range(of: #"\p{Han}"#, options: .regularExpression), english, file: file, line: line)
        XCTAssertNotNil(chinese.range(of: #"\p{Han}"#, options: .regularExpression), chinese, file: file, line: line)
        assertNoPlaceholders(text, file: file, line: line)
    }

    private func assertNoPlaceholders(_ text: LocalizedText, file: StaticString = #filePath, line: UInt = #line) {
        for language in DisplayLanguage.allCases {
            let value = text.localized(in: language)
            XCTAssertNil(value.range(of: #"%(?:[0-9]+\$)?[@a-zA-Z]|\{\{[^}]+\}\}|\\\("#, options: .regularExpression),
                         value, file: file, line: line)
        }
    }
}
