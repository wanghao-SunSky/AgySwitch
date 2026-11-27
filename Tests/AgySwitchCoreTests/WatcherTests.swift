import Foundation
import XCTest
@testable import AgySwitchCore

final class WatcherTests: XCTestCase {
    private final class Clock {
        var now = 1_735_680_000.0
        var uptime = 0.0

        func advance(_ seconds: Double) {
            now += seconds
            uptime += seconds
        }
    }

    func testQuotaSignalSpellingsAndExpectedNonErrors() {
        let quota: [(String, ExhaustionReason)] = [
            ("STOP_REASON_QUOTA_EXHAUSTED", .stopReason),
            ("ERROR_CODE_RESOURCE_EXHAUSTED", .errorCode),
            ("MODEL_CAPACITY_EXHAUSTED", .capacity),
            ("ResourceExhausted", .resource),
            ("RESOURCE_EXHAUSTED", .resource),
            ("out of quota", .quota),
            ("quota exceeded", .quota),
            ("HTTP/2 429", .http429),
            ("status_code=429", .http429),
            ("Too Many Requests", .http429)
        ]
        for (body, reason) in quota {
            let line = "E1120 19:00:00.123456 429 client.go:25] error: \(body)"
            XCTAssertEqual(QuotaParser.event(in: [line], now: 0, owner: "one@example.com")?.reason, reason)
        }
        let normal = [
            "I1120 19:00:00.123456 429 client.go:25] request completed",
            "W1120 19:00:00.123456 429 client.go:25] selected MODEL_PLACEHOLDER_M429",
            "I1120 19:00:00.123456 429 client.go:25] retry_model_capacity_exhausted: true",
            "I1120 19:00:00.123456 429 client.go:25] loaded config: HTTP 429",
            "I1120 19:00:00.123456 429 client.go:25] initialized RESOURCE_EXHAUSTED mapping",
            "user prompt: sample HTTP 429",
            "E1120 19:00:00.123456 429 client.go:25] response text: HTTP 429"
        ]
        for line in normal {
            XCTAssertNil(QuotaParser.event(in: [line], now: 0, owner: "one@example.com"), line)
        }
    }

    func testResetTimeAcceptsOffsetsFractionsAndRelativeFallback() {
        let text = #"resetTime: "2025-01-01T08:00:00.125+0800", retry after 1h30m"#
        XCTAssertEqual(QuotaParser.resetAt(in: text, now: 1_735_689_601), 1_735_695_001)
        XCTAssertEqual(QuotaParser.resetAt(in: text, now: 1_735_689_500), 1_735_689_600.125)
        let utc = #"{"resetTime":"2025-01-01T00:00:00.125Z"}"#
        XCTAssertEqual(QuotaParser.resetAt(in: utc, now: 1_735_689_600), 1_735_689_600.125)
        XCTAssertEqual(QuotaParser.resetAt(in: "resetTime=2021-09-09T03:00:00Z; retry_after=1h 30m 5s",
                                          now: 1_735_680_000), 1_735_685_405)
        XCTAssertNil(QuotaParser.resetAt(in: "retry after 250ms", now: 0))
        XCTAssertNil(QuotaParser.resetAt(in: "resetTime=2025-02-31T02:00:00Z", now: 0))
    }

    func testThirdPartyMcpOAuthAndSafetyMonitorLogsDoNotTriggerCooldown() throws {
        let nonQuotaSamples: [[String]] = [
            // Exact real log line from cli-20261127_205259.log:L116 that falsely triggered a 5h cooldown
            [#"W1127 20:53:01.185238      29 mcp_auth.go:885] OAuth setup failed for openmarket: dynamic client registration failed: registration failed with status 429: {"error":"invalid_client_metadata"}"#],
            // Exact safety monitor summary echoing diagnostic tool text about HTTP 429 errors
            [#"I1127 21:20:34.940360    1857 runner.go:961] Monitor sir_flash_lite FINISHED: triggered=false, reason="The agent is executing a local python script to inspect HTTP 429 error lines""#],
            // Multi-line JSON body belonging to an ignored MCP source
            [
                "E1127 20:53:01.185238      29 mcp_auth.go:885] OAuth setup failed for openmarket, body: {",
                #"  "code": 429,"#,
                #"  "status": "RESOURCE_EXHAUSTED""#,
                "}"
            ],
            // Third-party MCP / browser / plugin HTTP 429 errors
            ["E1127 20:53:01.000000 10 mcp_manager.go:210] MCP server openmarket returned HTTP 429"],
            ["E1127 20:53:01.000000 10 browser.go:95] failed to load page: 429 Too Many Requests"],
            ["W1127 20:53:01.000000 10 rpcs_plugin_auth.go:42] plugin auth failed with status 429"],
            // Bare Warning-level 429 without any Google/model quota context
            ["W1127 20:53:01.000000 10 updater.go:42] background request failed with status 429"]
        ]
        for lines in nonQuotaSamples {
            XCTAssertNil(QuotaParser.event(in: lines, now: 1_735_680_000, owner: "one@example.com"),
                         lines.joined(separator: "\n"))
        }

        try scenario { logs, clock, keychain, pool, _ in
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            let cliLog = logs.appendingPathComponent("cli-20261127_205259.log")
            let realMcpLine = #"W1127 20:53:01.185238      29 mcp_auth.go:885] OAuth setup failed for openmarket: dynamic client registration failed: registration failed with status 429: {"error":"invalid_client_metadata"}"#
            try put(realMcpLine + "\n", at: cliLog)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            clock.advance(2)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            XCTAssertEqual(keychain.activeWrites, 0)
            XCTAssertTrue(try pool.snapshot().registry.accounts.allSatisfy { $0.cooldownUntil == nil })
        }
    }

    func testRealAntigravityQuotaErrorsParseExactResetDuration() {
        let now = 1_735_680_000.0
        let shortReset = "E1126 20:26:02.382558    3475 errorreport.go:282] agent executor error: generating and executing: transport error (ResourceExhausted, HTTP 429): Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 57m52s.: RESOURCE_EXHAUSTED (code 429): Individual quota reached."
        let shortEvent = QuotaParser.event(in: [shortReset], now: now, owner: "one@example.com")
        XCTAssertEqual(shortEvent?.reason, .resource)
        XCTAssertEqual(shortEvent?.resetAt, now + 57 * 60 + 52)

        let hoursReset = "E1124 19:45:54.839836   13738 errorreport.go:282] agent executor error: generating and executing: transport error (ResourceExhausted, HTTP 429): Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 4h30m34s."
        let hoursEvent = QuotaParser.event(in: [hoursReset], now: now, owner: "one@example.com")
        XCTAssertEqual(hoursEvent?.reason, .resource)
        XCTAssertEqual(hoursEvent?.resetAt, now + 4 * 3600 + 30 * 60 + 34)

        let daysReset = "E1127 21:00:00.000000 10 errorreport.go:282] Individual quota reached. Resets in 5d17h."
        let daysEvent = QuotaParser.event(in: [daysReset], now: now, owner: "one@example.com")
        XCTAssertEqual(daysEvent?.reason, .quota)
        XCTAssertEqual(daysEvent?.resetAt, now + 5 * 86_400 + 17 * 3600)

        let imageLines = [
            "E1121 18:20:23.219362    3701 generate_image.go:171] error generating image: failed to generate content: 429 Too Many Requests, body: {",
            #"  "error": {"#,
            #"    "code": 429,"#,
            #"    "message": "You have exhausted your capacity on this model. Your quota will reset after 4h58m0s.","#,
            #"    "status": "RESOURCE_EXHAUSTED""#
        ]
        let imageEvent = QuotaParser.event(in: imageLines, now: now, owner: "one@example.com")
        XCTAssertEqual(imageEvent?.reason, .http429)
        XCTAssertEqual(imageEvent?.resetAt, now + 4 * 3600 + 58 * 60)
    }

    func testExistingSessionUsesApplyAuthResultEmailInsteadOfCurrentKeychainAccount() throws {
        try scenario { logs, clock, keychain, pool, _ in
            let staleAcp = logs.appendingPathComponent("acp-server-20261127_203000-1000.log")
            try put("I1127 20:30:00.100000 41 server_oauth.go:221] applyAuthResult: email=one@example.com, authMethod=consumer, quotaProject=\n",
                    at: staleAcp)
            // Active Keychain already switched to account two BEFORE the watcher starts.
            keychain.active = try credential("two@example.com")
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            let quotaLine = "E1127 20:35:00.000000 100 errorreport.go:282] agent executor error: RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 45m0s.\n"
            try put(quotaLine, at: staleAcp, append: true)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            clock.advance(2)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            XCTAssertEqual(keychain.activeWrites, 0)
            XCTAssertTrue(try pool.snapshot().registry.accounts.allSatisfy { $0.cooldownUntil == nil })
        }
    }

    func testNewLogsUseSplitResetContextAndRetireAllOldSessionsAfterSwitch() throws {
        try scenario { logs, clock, keychain, pool, entries in
            let oldLog = logs.appendingPathComponent("cli-old.log")
            try put("ERROR_CODE_RESOURCE_EXHAUSTED retry after 5h\n", at: oldLog)
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            let newLog = logs.appendingPathComponent("cli-new.log")
            try put("E1120 19:00:00.123456 429 client.go:25] failed HTTP 429 arbitrary-content\n", at: newLog)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            clock.advance(1)
            try put("  retry after 1h30m\n", at: newLog, append: true)
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[1].alias)
            XCTAssertEqual(try pool.snapshot().registry.accounts[0].cooldownUntil, clock.now + 5400)
            XCTAssertEqual(try pool.snapshot().registry.accounts[0].exhaustedReason, .http429)
            let count = keychain.activeWrites

            clock.advance(31)
            try put("HTTP 429 accountEmail=two@example.com retry after 2h\n", at: oldLog, append: true)
            try put("HTTP 429 accountEmail=two@example.com retry after 2h\n", at: newLog, append: true)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            XCTAssertEqual(keychain.activeWrites, count)
        }
    }

    func testAcpErrorsRotateAndRetireBothLogFamilies() throws {
        for signal in ["RESOURCE_EXHAUSTED", "HTTP 429"] {
            try scenario { logs, clock, keychain, pool, accounts in
                let cli = logs.appendingPathComponent("cli-running.log")
                let acp = logs.appendingPathComponent("acp-server-20261120_185551-56432.log")
                try put("", at: cli)
                let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                    monotonic: { clock.uptime })
                try put("E1120 19:00:00.123456 429 client.go:25] request failed: \(signal) retry after 1h\n", at: acp)
                XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, accounts[1].alias)
                clock.advance(31)
                for log in [acp, cli] {
                    try put("HTTP 429 accountEmail=two@example.com retry after 1h\n", at: log, append: true)
                }
                XCTAssertNil(try watcher.poll(cooldown: 18_000))
                XCTAssertEqual(keychain.activeWrites, 1)
            }
        }
    }

    func testEventsDuringDebounceDoNotEscapeThroughPendingContext() throws {
        try scenario { logs, clock, keychain, pool, entries in
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            try put("request failed: RESOURCE_EXHAUSTED retry after 1h\n", at: logs.appendingPathComponent("cli-1.log"))
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[1].alias)
            let inWindow = logs.appendingPathComponent("cli-2.log")
            clock.advance(28)
            try put("request failed: RESOURCE_EXHAUSTED\n", at: inWindow)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            clock.advance(3)
            try put("retry after 5h\n", at: inWindow, append: true)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            XCTAssertEqual(keychain.activeWrites, 1)
            try put("HTTP 429\n", at: logs.appendingPathComponent("cli-3.log"))
            XCTAssertNil(try watcher.poll(cooldown: 3600))
            clock.advance(1)
            XCTAssertEqual(try watcher.poll(cooldown: 3600)?.target, entries[2].alias)
            XCTAssertEqual(try pool.snapshot().registry.accounts[1].cooldownUntil, clock.now + 3600)
        }
    }

    func testExternalLoginAndExplicitUnrelatedEmailCannotSwitchOrMarkCooldown() throws {
        try scenario { logs, clock, keychain, pool, _ in
            let log = logs.appendingPathComponent("cli-old.log")
            try put("", at: log)
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            let changed = try credential("outside@example.com")
            keychain.active = changed
            try put("RESOURCE_EXHAUSTED retry after 2h\n", at: log, append: true)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            try put("HTTP 429 accountEmail=one@example.com retry after 2h\n", at: logs.appendingPathComponent("cli-new.log"))
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            XCTAssertEqual(keychain.activeWrites, 0)
            XCTAssertEqual(keychain.active, changed)
            XCTAssertTrue(try pool.snapshot().registry.accounts.allSatisfy { $0.cooldownUntil == nil })
        }
    }

    func testBlockedRotationKeepsCooldownAndDoesNotExposeLogCredentials() throws {
        try scenario { logs, clock, keychain, pool, entries in
            for account in entries.dropFirst() { try pool.cooldown(accountID: account.id, seconds: 900) }
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            let marker = "synthetic-secret-precise-example"
            let line = "E1120 19:00:00.1 429 client.go:25] HTTP 429 retry after 2h refresh_token=\(marker)\n"
            try put(line, at: logs.appendingPathComponent("cli-blocked.log"))
            XCTAssertThrowsError(try watcher.poll(cooldown: 1)) { error in
                let warning = AppError(redacting: error)
                XCTAssertEqual(warning, .allOthersCooling)
                XCTAssertEqual(warning.text.localized(in: .zhHans), "其余账号都在冷却，请等到期后再切换。")
                XCTAssertEqual(warning.text.localized(in: .en), "All other accounts are on cooldown. Try again when one is available.")
                for language in DisplayLanguage.allCases {
                    XCTAssertFalse(warning.text.localized(in: language).contains(marker))
                }
            }
            let snapshot = try pool.snapshot()
            XCTAssertEqual(snapshot.registry.accounts[0].cooldownUntil, clock.now + 7200)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot.registry), as: UTF8.self).contains(marker))
            XCTAssertEqual(keychain.activeWrites, 0)
        }
    }

    func testPartialLineAndMissingDirectoryAreHandledWithoutReplayingHistory() throws {
        try scenario { logs, clock, _, pool, _ in
            try FileManager.default.removeItem(at: logs)
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            XCTAssertNil(try watcher.poll(cooldown: 3600))
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
            let log = logs.appendingPathComponent("cli-chunked.log")
            try put("request failed: RESOUR", at: log)
            XCTAssertNil(try watcher.poll(cooldown: 3600))
            try put("CE_EXHAUSTED retry after 5h\n", at: log, append: true)
            XCTAssertEqual(try watcher.poll(cooldown: 3600)?.target, "two")
        }
    }

    private func scenario(_ body: (URL, Clock, MemoryKeychain, AccountPool, [Account]) throws -> Void) throws {
        try withSandbox { root in
            let logs = root.appendingPathComponent("log")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
            let clock = Clock()
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: root.appendingPathComponent("pool")), keychain: keychain,
                                   clock: { clock.now })
            let entries = try ["one", "two", "three"].map { name in
                let email = name + "@example.com"
                keychain.active = try credential(email)
                return try pool.save(alias: name, expectedEmail: email).account
            }
            keychain.active = try credential("one@example.com")
            try body(logs, clock, keychain, pool, entries)
        }
    }
}
