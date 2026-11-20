import Foundation
import XCTest
@testable import AgySwitchCore

final class KeychainTests: XCTestCase {
    func testFreshLoginRoundTripsUnchangedAndUsesOnlyRequiredKeychainCalls() throws {
        try withSandbox { home in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: home), keychain: keychain)
            let email = "new@example.com"
            let json = Data(#"{ "auth_method":"consumer", "id_token_email":"new@example.com", "token":{"test":"fixture"} }"#.utf8)
            let raw = Data(("go-keyring-base64:" + json.base64EncodedString()).utf8)
            keychain.active = raw
            let fresh = try pool.save(alias: "new", expectedEmail: email)
            XCTAssertEqual(fresh.account.authMethod, "consumer")
            XCTAssertEqual(fresh.snapshot.activeID, fresh.account.id)
            XCTAssertEqual(keychain.activeReads, 1)
            XCTAssertEqual(keychain.vaultWrites, 1)
            XCTAssertEqual(keychain.vaultReads, 1) // read-back
            XCTAssertFalse(try pool.switchTo(accountID: fresh.account.id).changed)
            let savedAgain = try pool.save(alias: "new", expectedEmail: email).snapshot
            XCTAssertEqual(savedAgain.activeID, fresh.account.id)
            XCTAssertEqual(keychain.vaultWrites, 1)
            let prepared = try pool.beginAddAccount()
            XCTAssertNil(prepared.currentEmail)
            XCTAssertEqual(prepared.registry, savedAgain.registry)
            XCTAssertEqual(keychain.vaultWrites, 1)
            let otherRaw = try credential("other@example.com")
            keychain.active = otherRaw
            let other = try pool.save(alias: "other", expectedEmail: "other@example.com")
            let reads = keychain.activeReads, vaultReads = keychain.vaultReads
            let switched = try pool.switchTo(accountID: fresh.account.id)
            XCTAssertEqual(switched.snapshot.currentEmail, email)
            XCTAssertEqual(keychain.active, raw)
            XCTAssertEqual(keychain.activeReads - reads, 3) // initial, pre-write race check, read-back
            XCTAssertEqual(keychain.vaultReads - vaultReads, 2) // target and old snapshot
            XCTAssertEqual(keychain.vaultWrites, 2)
            XCTAssertEqual(keychain.activeWrites, 1)

            let back = try pool.next()
            XCTAssertEqual(back.snapshot.activeID, other.account.id)
            XCTAssertEqual(keychain.active, otherRaw)
            XCTAssertEqual(keychain.vaultWrites, 2)
            XCTAssertEqual(keychain.activeWrites, 2)
            let beforeMetadata = keychain.activeReads
            XCTAssertEqual(try pool.rename(accountID: other.account.id, alias: "renamed").registry.accounts.last?.alias, "renamed")
            XCTAssertNotNil(try pool.cooldown(accountID: fresh.account.id, seconds: 60).registry.accounts.first?.cooldownUntil)
            let removed = try pool.remove(accountID: other.account.id)
            XCTAssertEqual(removed.currentEmail, "other@example.com")
            XCTAssertNil(removed.activeID)
            XCTAssertEqual(keychain.activeReads - beforeMetadata, 3)
        }
    }

    func testSwitchRetriesAConcurrentTokenRefreshAndLeavesAnExternalLoginAlone() throws {
        for changesEmail in [false, true] {
            try withSandbox { home in
                let keychain = MemoryKeychain()
                let pool = AccountPool(store: RegistryStore(home: home), keychain: keychain)
                keychain.active = try credential("target@example.com")
                let target = try pool.save(alias: "target", expectedEmail: "target@example.com").account
                keychain.active = try credential("current@example.com")
                let current = try pool.save(alias: "current", expectedEmail: "current@example.com").account
                keychain.active = try credential(current.email, marker: "refresh-one")
                let latest = try credential(changesEmail ? "external@example.com" : current.email, marker: "refresh-two")
                keychain.afterSnapshotWrite = { [weak keychain] in
                    keychain?.afterSnapshotWrite = nil
                    keychain?.active = latest
                }
                if changesEmail {
                    XCTAssertThrowsError(try pool.switchTo(accountID: target.id)) { XCTAssertEqual($0 as? AppError, .activeChanged) }
                    XCTAssertEqual(keychain.active, latest)
                    XCTAssertEqual(keychain.activeWrites, 0)
                } else {
                    XCTAssertEqual(try pool.switchTo(accountID: target.id).snapshot.activeID, target.id)
                    XCTAssertEqual(try keychain.read(service: MacKeychain.vaultService, account: current.id), latest)
                    XCTAssertEqual(keychain.activeWrites, 1)
                }
            }
        }
    }

    func testMethodIsOptionalAndTokenCanBeAnyNonNullJSONValue() throws {
        for token: Any in ["opaque", [], [:], 0, false] as [Any] {
            for method: Any? in [nil, "", NSNull(), 7, ["future": true], "consumer"] as [Any?] {
                var fields: [String: Any] = ["id_token_email": "new@example.com", "token": token, "extra": [1, 2]]
                fields["auth_method"] = method
                let plain = try JSONSerialization.data(withJSONObject: fields)
                let b64 = Data(("go-keyring-base64:" + plain.base64EncodedString()).utf8)
                for raw in [plain, b64, Data(plain.hex.utf8), Data(("0x" + b64.hex).utf8)] {
                    let parsed = try Identity.parse(raw)
                    XCTAssertEqual(parsed.email, "new@example.com")
                    XCTAssertEqual(parsed.authMethod, (method as? String) == "consumer" ? "consumer" : "oauth")
                }
            }
        }
        for json in [#"{"id_token_email":"new@example.com"}"#,
                     #"{"id_token_email":"new@example.com","token":null}"#,
                     #"{"id_token_email":"a@invalid domain","token":{}}"#,
                     #"{"token":"fixture"}"#] {
            XCTAssertThrowsError(try Identity.parse(Data(json.utf8))) { XCTAssertEqual($0 as? AppError, .invalidCredential) }
        }
    }

    func testAllCredentialEncodingsArePreservedWhenSwitching() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: directory), keychain: keychain)
            let json = try credential("json@example.com")
            let b64 = Data(("go-keyring-base64:" + (try credential("b64@example.com")).base64EncodedString()).utf8)
            let hex = Data(("0x" + (try credential("hex@example.com")).hex).utf8)
            var entries: [(Account, Data)] = []
            for (name, raw) in [("json", json), ("b64", b64), ("hex", hex)] {
                keychain.active = raw
                let email = try Identity.parse(raw).email
                let account = try pool.save(alias: name, expectedEmail: email).account
                entries.append((account, raw))
                XCTAssertEqual(try keychain.read(service: "agy-acct-vault", account: account.id), raw)
            }
            keychain.active = try credential("outside@example.com")
            for (account, original) in entries {
                XCTAssertTrue(try pool.switchTo(accountID: account.id).changed)
                XCTAssertEqual(keychain.active, original)
            }
            let refreshed = try credential("hex@example.com", marker: "updated-synthetic-credential")
            keychain.active = refreshed
            for (account, original) in entries.dropLast() {
                XCTAssertTrue(try pool.switchTo(accountID: account.id).changed)
                XCTAssertEqual(keychain.active, original)
            }
            XCTAssertEqual(try keychain.read(service: "agy-acct-vault", account: entries[2].0.id), refreshed)
            XCTAssertEqual(try pool.next().target, "hex")
            XCTAssertEqual(keychain.active, refreshed)
        }
    }

    func testSecuritySendsShortBinaryAndLongEscapedPrintableOverStdinOnly() throws {
        var seen: [Data] = []
        let keychain = MacKeychain(path: "/tmp/keychain \"space\"") { args, input in
            XCTAssertEqual(args, ["-i"])
            seen.append(try XCTUnwrap(input))
            return .init(status: 0, stdout: Data(), stderr: Data())
        }
        try keychain.write(service: "gemini", account: "antigravity", raw: Data([0, 255, 10]))
        XCTAssertEqual(String(decoding: seen[0], as: UTF8.self),
                       #"add-generic-password -U -s "gemini" -a "antigravity" -X 00ff0a "/tmp/keychain \"space\"""# + "\n")
        let printable = "fixture-\\\"-" + String(repeating: "s", count: 2400)
        try keychain.write(service: "gemini", account: "antigravity", raw: Data(printable.utf8))
        let line = String(decoding: seen[1], as: UTF8.self)
        XCTAssertTrue(line.contains(#" -w "fixture-\\\"-"#))
        XCTAssertLessThan(line.utf8.count, 4096)
        XCTAssertThrowsError(try keychain.write(service: "gemini", account: "antigravity",
                                               raw: Data(repeating: 0, count: 2500)))
        XCTAssertThrowsError(try keychain.write(service: "gemini", account: "antigravity",
                                               raw: Data(repeating: 65, count: 4100)))
        XCTAssertEqual(seen.count, 2)
    }

    func testSecurityReadDisambiguatesLiteralHexAndBinary() throws {
        for (detail, expected) in [(#"password: "DEAD""#, Data("DEAD".utf8)),
                                   ("password: 0xDEAD  ", Data([0xDE, 0xAD]))] {
            let keychain = MacKeychain(path: "/tmp/keychain") { args, data in
                XCTAssertNil(data)
                XCTAssertEqual(Array(args.dropFirst(2)), ["-s", "gemini", "-a", "antigravity", "/tmp/keychain"])
                return .init(status: 0, stdout: Data("DEAD\n".utf8), stderr: Data((detail + "\n").utf8))
            }
            XCTAssertEqual(try keychain.read(service: "gemini", account: "antigravity"), expected)
        }
    }

    func testSecurityErrorsAndParseDiagnosticsNeverIncludeRawData() throws {
        let secret = "synthetic-SENSITIVE-stdin-stderr"
        let raw = Data(secret.utf8)
        let keychain = MacKeychain(path: "/tmp/keychain") { args, _ in
            XCTAssertFalse(args.joined().contains(secret))
            return .init(status: 1, stdout: raw, stderr: raw)
        }
        for action in [
            { try keychain.write(service: "gemini", account: "antigravity", raw: raw) },
            { _ = try keychain.read(service: "gemini", account: "antigravity") },
            { _ = try Identity.parse(raw) }
        ] {
            XCTAssertThrowsError(try action()) { error in
                for language in DisplayLanguage.allCases {
                    XCTAssertFalse(AppError(redacting: error).text.localized(in: language).contains(secret))
                }
            }
        }
        XCTAssertThrowsError(try keychain.delete(service: "gemini", account: "antigravity"))
        let missing = MacKeychain(path: "/tmp/keychain") { _, _ in
            .init(status: 44, stdout: raw, stderr: raw)
        }
        XCTAssertNil(try missing.read(service: "gemini", account: "antigravity"))
    }

    func testClearActiveLoginTargetsOnlyTheNamedGenericPassword() throws {
        for status: Int32 in [0, 44, 1] {
            let keychain = MacKeychain(path: "/tmp/keychain") { args, input in
                XCTAssertEqual(args, ["delete-generic-password", "-s", "gemini", "-a", "antigravity", "/tmp/keychain"])
                XCTAssertNil(input)
                return .init(status: status, stdout: Data(), stderr: Data())
            }
            if status == 1 {
                XCTAssertThrowsError(try keychain.clearActiveLogin()) { XCTAssertEqual($0 as? AppError, .activeLoginDelete) }
            } else {
                try keychain.clearActiveLogin()
            }
        }
    }

    func testSwitchChecksReadbackBeforeUpdatingMetadataAndRemoveKeepsCurrentLogin() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: directory), keychain: keychain)
            let one = try credential("one@example.com")
            let two = try credential("two@example.com")
            keychain.active = one
            let first = try pool.save(alias: "one", expectedEmail: "one@example.com").account
            keychain.active = two
            let second = try pool.save(alias: "two", expectedEmail: "two@example.com").account
            keychain.active = one
            let initial = try pool.snapshot().registry
            keychain.replaceNextActiveWrite = true
            XCTAssertThrowsError(try pool.switchTo(accountID: second.id))
            XCTAssertEqual(try pool.snapshot().registry, initial)
            try pool.remove(accountID: first.id)
            XCTAssertEqual(keychain.active, one)
            XCTAssertEqual(try pool.snapshot().registry.accounts, [second])
        }
    }
}
