import Darwin
import Foundation
import XCTest
@testable import AgySwitchCore

final class RegistryStoreTests: XCTestCase {
    func testRegistryAndVaultPreserveRefreshMetadataAndPermissions() throws {
        try withSandbox { root in
            let home = root.appendingPathComponent("account pool")
            let store = RegistryStore(home: home)
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: store, keychain: keychain, clock: { 1800 })
            let primary = try credential("Primary@example.com")
            let refreshed = try credential("Primary@example.com", marker: "synthetic-refresh")
            let backup = try credential("backup@example.com")

            keychain.active = primary
            let savedPrimary = try pool.save(alias: "primary", expectedEmail: "Primary@example.com").account
            XCTAssertEqual(savedPrimary.store, .keychain)
            XCTAssertEqual(savedPrimary.alias, "primary")

            keychain.active = backup
            let savedBackup = try pool.save(alias: "backup", expectedEmail: "backup@example.com").account
            XCTAssertEqual(savedBackup.store, .keychain)

            keychain.active = refreshed
            XCTAssertTrue(try pool.switchTo(accountID: savedBackup.id).changed)
            XCTAssertEqual(keychain.active, backup)

            try pool.rename(accountID: savedPrimary.id, alias: "work")
            try pool.cooldown(accountID: savedPrimary.id, seconds: 3600)

            let homeMode = try FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions] as? Int
            let registryPath = home.appendingPathComponent("registry.json")
            let fileMode = try FileManager.default.attributesOfItem(atPath: registryPath.path)[.posixPermissions] as? Int
            XCTAssertEqual(homeMode, 0o700)
            XCTAssertEqual(fileMode, 0o600)
            let registryText = try String(contentsOf: registryPath, encoding: .utf8)
            XCTAssertFalse(registryText.contains("synthetic"))

            let snapshot = try pool.snapshot()
            XCTAssertEqual(snapshot.registry.lastActiveAlias, "work")
            XCTAssertEqual(snapshot.registry.accounts.first?.cooldownUntil, 5400)
            XCTAssertEqual(snapshot.registry.accounts.first?.exhaustedReason, .manual)

            XCTAssertTrue(try pool.switchTo(accountID: savedPrimary.id).changed)
            XCTAssertEqual(keychain.active, refreshed)
        }
    }

    func testDirectoryLockContendsWithFlockAndRejectsInsecurePermissions() throws {
        try withSandbox { directory in
            let store = RegistryStore(home: directory)
            try store.locked(write: true) { _ in
                let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
                XCTAssertGreaterThanOrEqual(fd, 0)
                defer { close(fd) }
                let lockResult = flock(fd, LOCK_SH | LOCK_NB)
                XCTAssertEqual(lockResult, -1)
                XCTAssertEqual(errno, EWOULDBLOCK)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            XCTAssertThrowsError(try store.locked { _ in })
        }
    }

    func testRegistryRejectsForeignKeysSymlinksAndInvalidVersions() throws {
        try withSandbox { directory in
            let store = RegistryStore(home: directory)
            let path = directory.appendingPathComponent("registry.json")
            for invalid in ["1.0", "1e0", "true", "2", "\"1\""] {
                try put("{\"version\":\(invalid),\"accounts\":[],\"last_active_alias\":null}", at: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                XCTAssertThrowsError(try store.locked { _ in }, "Accepted version \(invalid)")
            }
            try put(#"{"version":1,"accounts":[],"last_active_alias":null,"foreign":true}"#, at: path)
            XCTAssertThrowsError(try store.locked { _ in })
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: directory.appendingPathComponent("target"))
            XCTAssertThrowsError(try store.locked { _ in })
        }
    }

    func testRegistryHomeHonorsEnvironmentOverride() {
        XCTAssertEqual(RegistryStore.defaultHome(environment: ["AGY_ACCT_HOME": "/tmp/agy swift"]).path, "/tmp/agy swift")
        XCTAssertTrue(RegistryStore.defaultHome(environment: ["AGY_ACCT_HOME": ""]).path.hasSuffix("/.config/agy-acct"))
    }
}
