import Foundation
import XCTest
@testable import AgySwitchCore

final class AddAccountTests: XCTestCase {
    func testTerminalCommandsAreUniquePrivateAndExecTheQuotedPath() throws {
        try withSandbox { home in
            let fake = home.appendingPathComponent("agy's $HOME; space")
            try put("#!/bin/sh\nprintf 'fixture executed\\n'\n", at: fake)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            let first = try TerminalCommand.create(for: fake, in: home)
            let second = try TerminalCommand.create(for: fake, in: home)
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(first.pathExtension, "command")
            let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
            let source = try String(contentsOf: first, encoding: .utf8)
            XCTAssertTrue(source.contains(#"printf '\033[8;38;108t'"#))
            XCTAssertTrue(source.contains("\nclear\nexec '"))
            let process = Process(), output = Pipe()
            process.executableURL = first
            process.environment = ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"]
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let rendered = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertTrue(rendered.hasPrefix("\u{1B}[8;38;108t"))
            XCTAssertTrue(rendered.hasSuffix("fixture executed\n"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        }
    }

    func testSavedAccountBacksUpLatestBytesBeforeClearingAndRestoresThemExactly() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: directory), keychain: keychain)
            let email = "one@example.com"
            keychain.active = try credential(email)
            let account = try pool.save(alias: "original", expectedEmail: email).account
            let registry = try pool.snapshot().registry
            let refreshed = try encodedCredential(email, marker: "refreshed")
            keychain.active = refreshed

            try pool.beginAddAccount()

            XCTAssertEqual(keychain.activeClears, 1)
            XCTAssertNil(keychain.active)
            XCTAssertEqual(try keychain.read(service: MacKeychain.vaultService, account: account.id), refreshed)
            XCTAssertEqual(try pool.snapshot(), PoolSnapshot(registry: registry))
            XCTAssertTrue(try pool.switchTo(accountID: account.id).changed)
            XCTAssertEqual(keychain.active, refreshed)
        }
    }

    func testUnsavedAccountIsRegisteredWithAUniqueDefaultAliasBeforeClearing() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let store = RegistryStore(home: directory)
            let pool = AccountPool(store: store, keychain: keychain)
            let email = "person@example.com"
            keychain.active = try credential("other@example.com")
            let existing = try pool.save(alias: "person", expectedEmail: "other@example.com").account
            let original = try encodedCredential(email, marker: "original")
            keychain.active = original
            var saved: Account?
            keychain.beforeClearingActiveLogin = {
                let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: store.path))
                let newAccount = try XCTUnwrap(registry.accounts.last)
                XCTAssertEqual(registry.accounts.first, existing)
                XCTAssertEqual(newAccount.email, email)
                XCTAssertEqual(newAccount.alias, "person-2")
                XCTAssertEqual(try keychain.read(service: MacKeychain.vaultService, account: newAccount.id), original)
                saved = newAccount
            }

            try pool.beginAddAccount()
            keychain.beforeClearingActiveLogin = nil

            XCTAssertEqual(keychain.activeClears, 1)
            XCTAssertNil(keychain.active)
            let account = try XCTUnwrap(saved)
            XCTAssertTrue(try pool.switchTo(accountID: account.id).changed)
            XCTAssertEqual(keychain.active, original)
        }
    }

    func testSignedOutPreparationIsIdempotent() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let store = RegistryStore(home: directory)
            let pool = AccountPool(store: store, keychain: keychain)

            try pool.beginAddAccount()
            try pool.beginAddAccount()

            XCTAssertEqual(try pool.snapshot(), PoolSnapshot())
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path.path))
            XCTAssertEqual(keychain.activeClears, 0)
            XCTAssertEqual(keychain.activeWrites, 0)
        }
    }

    func testRefreshDuringPreparationIsBackedUpBeforeClearing() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: directory), keychain: keychain)
            let email = "one@example.com"
            keychain.active = try credential(email)
            let refreshed = try encodedCredential(email, marker: "background-refresh")
            keychain.afterSnapshotWrite = { [weak keychain] in
                keychain?.active = refreshed
                keychain?.afterSnapshotWrite = nil
            }

            try pool.beginAddAccount()

            XCTAssertEqual(keychain.activeClears, 1)
            XCTAssertNil(keychain.active)
            let account = try XCTUnwrap(pool.snapshot().registry.accounts.first)
            XCTAssertEqual(try keychain.read(service: MacKeychain.vaultService, account: account.id), refreshed)
        }
    }

    func testChangedIdentityKeepsTheNewLogin() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: directory), keychain: keychain)
            keychain.active = try credential("one@example.com")
            let other = try credential("two@example.com")
            keychain.afterSnapshotWrite = { [weak keychain] in keychain?.active = other }

            XCTAssertThrowsError(try pool.beginAddAccount()) { XCTAssertEqual($0 as? AppError, .activeChanged) }
            XCTAssertEqual(keychain.active, other)
            XCTAssertEqual(keychain.activeClears, 0)
            XCTAssertEqual(try pool.snapshot().registry.accounts.map(\.email), ["one@example.com"])
        }
    }

    func testUnverifiedBackupKeepsTheCurrentLogin() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: directory), keychain: keychain)
            let original = try credential("one@example.com")
            keychain.active = original
            keychain.skipSnapshotWrites = true

            XCTAssertThrowsError(try pool.beginAddAccount()) { XCTAssertEqual($0 as? AppError, .snapshotVerification) }
            XCTAssertEqual(keychain.active, original)
            XCTAssertEqual(keychain.activeClears, 0)
            XCTAssertTrue(try pool.snapshot().registry.accounts.isEmpty)
        }
    }

    func testRegistryWriteFailureKeepsTheCurrentLogin() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let store = RegistryStore(home: directory)
            let pool = AccountPool(store: store, keychain: keychain)
            let original = try credential("one@example.com")
            keychain.active = original
            keychain.afterSnapshotWrite = {
                try FileManager.default.createDirectory(at: store.path, withIntermediateDirectories: false)
            }

            XCTAssertThrowsError(try pool.beginAddAccount())
            XCTAssertEqual(keychain.active, original)
            XCTAssertEqual(keychain.activeClears, 0)
        }
    }

    func testClearMustBeVerifiedAndFailureLeavesTheBackupAvailable() throws {
        try withSandbox { directory in
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: directory), keychain: keychain)
            let original = try credential("one@example.com")
            keychain.active = original
            keychain.keepActiveLoginOnClear = true

            XCTAssertThrowsError(try pool.beginAddAccount()) { XCTAssertEqual($0 as? AppError, .activeLoginVerification) }
            let account = try XCTUnwrap(pool.snapshot().registry.accounts.first)
            XCTAssertEqual(try keychain.read(service: MacKeychain.vaultService, account: account.id), original)
            XCTAssertEqual(keychain.active, original)
        }
    }

    private func encodedCredential(_ email: String, marker: String) throws -> Data {
        Data(("go-keyring-base64:" + (try credential(email, marker: marker)).base64EncodedString()).utf8)
    }
}
