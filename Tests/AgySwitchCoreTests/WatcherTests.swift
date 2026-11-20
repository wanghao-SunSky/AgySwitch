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
                return try pool.save(alias: name, expectedEmail: email)
            }
            keychain.active = try credential("one@example.com")
            try body(logs, clock, keychain, pool, entries)
        }
    }
}
