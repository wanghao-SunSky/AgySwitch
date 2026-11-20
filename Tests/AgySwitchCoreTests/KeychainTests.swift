import Foundation
import XCTest
@testable import AgySwitchCore

final class KeychainTests: XCTestCase {
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
                let account = try pool.save(alias: name, expectedEmail: email)
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

    func testSwitchChecksReadbackBeforeUpdatingMetadataAndRemoveKeepsCurrentLogin() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: directory), keychain: keychain)
            let one = try credential("one@example.com")
            let two = try credential("two@example.com")
            keychain.active = one
            let first = try pool.save(alias: "one", expectedEmail: "one@example.com")
            keychain.active = two
            let second = try pool.save(alias: "two", expectedEmail: "two@example.com")
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
