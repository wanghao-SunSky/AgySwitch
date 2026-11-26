import XCTest
@testable import AgySwitchCore

final class QuotaTests: XCTestCase {
    func testBothQuotaSummaryFormatsAndOptionalFields() throws {
        let summary = #"""
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"window":"5h","remainingFraction":0.408,"resetTime":"2026-11-21T10:30:00Z"},
            {"window":"weekly","remainingFraction":0.226,"resetTime":"2026-11-27T10:30:00.000Z"}]},
          {"displayName":"Claude and GPT models","buckets":[
            {"window":"weekly","remainingFraction":1},{"window":"5h","remainingFraction":1}]},
          {"displayName":"Gemini 4 Argon","buckets":[{"window":"weekly"}]},
          {"displayName":"New family","buckets":[{"window":"daily","remainingFraction":0.5},
            {"window":"bad","remainingFraction":1.1},{"window":"bad","remainingFraction":-0.2}]}
        ]}
        """#
        let wrapped = #"{"buckets":[],"quotaSummary":"# +
            summary.replacingOccurrences(of: #""window""#, with: #""refreshWindowLabel""#) + "}"
        for json in [summary, wrapped] {
            let rows = try QuotaClient.parse(Data(json.utf8))
            XCTAssertEqual(rows.map(\.family), ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon", "New family"])
            XCTAssertEqual(rows[0].buckets.map(\.window), ["5h", "weekly"])
            XCTAssertEqual(rows[0].buckets.map(\.fraction), [0.408, 0.226])
            XCTAssertEqual(rows[0].buckets.compactMap(\.reset).count, 2)
            XCTAssertEqual(rows[1].buckets.map(\.fraction), [1, 1])
            XCTAssertTrue(rows[1].buckets.compactMap(\.reset).isEmpty)
            XCTAssertEqual(rows[2].buckets.first?.fraction, 0)
            XCTAssertEqual(rows[3].buckets.map(\.window), ["daily"])
        }
        XCTAssertThrowsError(try QuotaClient.parse(Data(#"{"buckets":[]}"#.utf8)))
    }

    func testHubCanAddGroupsButCannotReplacePrimaryWithFreshDefaults() throws {
        let reset = Date(timeIntervalSince1970: 900_000)
        let primary = ModelQuota(family: "Gemini", buckets: [.init(window: "weekly", fraction: 0.48, reset: reset)])
        let drift = ModelQuota(family: "Gemini", buckets: [.init(window: "weekly", fraction: 0.49, reset: reset)])
        let fresh = ModelQuota(family: "Gemini", buckets: [.init(window: "weekly", fraction: 1)])
        let argon = ModelQuota(family: "Argon", buckets: [.init(window: "weekly", fraction: 0.67, reset: reset)])
        XCTAssertEqual(QuotaClient.supplement([primary], with: [drift, argon]), [primary, argon])
        XCTAssertNil(QuotaClient.supplement([primary], with: [fresh, argon]))
        XCTAssertNil(QuotaClient.supplement([primary], with: [argon]))
    }

    func testHTTPStatusAndMultiDayCountdown() {
        for (code, expected) in [(401, QuotaError.expired), (302, .unavailable), (503, .unavailable)] {
            XCTAssertThrowsError(try QuotaClient.decode(Data(), status: code)) {
                XCTAssertEqual($0 as? QuotaError, expected)
            }
        }
        let duration = LocalizedText.cooldownCountdown(145 * 3600)
        XCTAssertEqual(duration.localized(in: .en), "6d 1h")
        XCTAssertEqual(duration.localized(in: .zhHans), "6 天 1 小时")
    }

    @MainActor func testFiveMinuteCacheAndConcurrentRequests() async throws {
        var now = Date()
        let cache = QuotaCache(now: { now })
        var calls = 0
        @MainActor @Sendable func load() async throws -> [ModelQuota] {
            calls += 1
            try await Task.sleep(for: .milliseconds(5))
            return [ModelQuota(family: "Gemini", buckets: [.init(window: "weekly", fraction: 1)])]
        }
        async let first = cache.rows(for: "a", load: load)
        async let second = cache.rows(for: "a", load: load)
        _ = try await (first, second)
        XCTAssertEqual(calls, 1)
        now.addTimeInterval(299)
        _ = try await cache.rows(for: "a", load: load)
        _ = try await cache.rows(for: "b", load: load)
        XCTAssertEqual(calls, 2)
        now.addTimeInterval(1)
        _ = try await cache.rows(for: "a", load: load)
        XCTAssertEqual(calls, 3)
        cache.invalidate()
        _ = try await cache.rows(for: "a", load: load)
        XCTAssertEqual(calls, 4)
    }

    func testRenewalRunsOnlyForSelectedAccountAndRequiresNewToken() throws {
        try withSandbox { home in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: home), keychain: keychain)
            keychain.active = try credential("a@example.com", marker: "fixture-a")
            let a = try pool.save(alias: "a", expectedEmail: "a@example.com").account
            keychain.active = try credential("b@example.com", marker: "fixture-b")
            let b = try pool.save(alias: "b", expectedEmail: "b@example.com").account
            XCTAssertThrowsError(try pool.renewActiveQuotaToken(accountID: a.id, rejected: "fixture-a") {
                XCTFail("An inactive account must never trigger a global login change")
            })
            let fresh = try pool.renewActiveQuotaToken(accountID: b.id, rejected: "fixture-b") {
                keychain.active = try credential(b.email, marker: "fixture-new")
            }
            XCTAssertEqual(fresh, "fixture-new")
            XCTAssertEqual(try keychain.read(service: "agy-acct-vault", account: b.id), keychain.active)
            XCTAssertThrowsError(try pool.renewActiveQuotaToken(accountID: b.id, rejected: fresh) {})
        }
    }

    func testRepairLateOldLoginAndPreserveExternalLogin() throws {
        try withSandbox { home in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: home), keychain: keychain)
            let a = try credential("a@example.com"), b = try credential("b@example.com")
            keychain.active = a
            let target = try pool.save(alias: "a", expectedEmail: "a@example.com").account
            keychain.active = b
            try pool.save(alias: "b", expectedEmail: "b@example.com")
            let receipt = try XCTUnwrap(pool.switchTo(accountID: target.id).reloadLogin)
            keychain.active = b
            try pool.verifyAfterReload(receipt)
            XCTAssertEqual(keychain.active, a)
            keychain.active = try credential("external@example.com")
            XCTAssertThrowsError(try pool.verifyAfterReload(receipt))
            XCTAssertEqual(try pool.currentEmail(), "external@example.com")
        }
    }
}
