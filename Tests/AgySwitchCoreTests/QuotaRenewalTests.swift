import XCTest
@testable import AgySwitchCore

final class QuotaRenewalTests: XCTestCase {
    private let email = "saved@example.invalid"
    private let fresh = #"{"id_token_email":"saved@example.invalid","token":{"access_token":"new","expiry":"2031-01-01T00:00:00Z"}}"#

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quota-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func setup(expiry: String) throws -> (AccountPool, MemoryKeychain, Account) {
        let keychain = MemoryKeychain()
        let pool = AccountPool(store: RegistryStore(home: try directory()), keychain: keychain, clock: { 1_893_456_000 })
        keychain.active = try JSONSerialization.data(withJSONObject: [
            "id_token_email": email, "writer_id": "original", "custom_field": true,
            "token": ["access_token": "old", "refresh_token": "long-lived", "expiry": expiry]
        ])
        let account = try pool.save(alias: "saved", expectedEmail: email).account
        keychain.active = try credential("active@example.invalid")
        return (pool, keychain, account)
    }

    func testExpiredAndNearExpirySkipRejectedRequestAndPreserveVault() async throws {
        // Fixture clock is 2030-01-01 00:00:00 UTC.
        for expiry in ["2029-12-31T23:59:59Z", "2030-01-01T08:00:59.123+08:00", "2029-12-31T19:00:30-05:00"] {
            let (pool, keychain, account) = try setup(expiry: expiry)
            let active = keychain.active
            var requests = [String]()
            _ = try await pool.loadQuota(accountID: account.id) { bearer in
                requests.append(bearer)
                return []
            } renew: { input in
                let sent = try Identity.credentialObject(XCTUnwrap(input))
                let fields = try XCTUnwrap(sent["token"] as? [String: Any])
                XCTAssertEqual(fields["refresh_token"] as? String, "long-lived")
                return Data(self.fresh.utf8)
            }
            XCTAssertEqual(requests, ["new"])
            let raw = try XCTUnwrap(keychain.read(service: "agy-acct-vault", account: account.id))
            XCTAssertTrue(raw.starts(with: Data("go-keyring-base64:".utf8)))
            let output = try Identity.credentialObject(raw)
            XCTAssertEqual((output["token"] as? [String: Any])?["refresh_token"] as? String, "long-lived")
            XCTAssertEqual(output["writer_id"] as? String, "original")
            XCTAssertEqual(output["custom_field"] as? Bool, true)
            XCTAssertEqual(keychain.active, active)
            XCTAssertEqual(keychain.activeWrites, 0)
        }
    }

    func testFreshBearerAnd401RetryBudget() async throws {
        let (pool, _, account) = try setup(expiry: "2030-01-01T00:01:00Z")
        _ = try await pool.loadQuota(accountID: account.id) { bearer in
            XCTAssertEqual(bearer, "old")
            return []
        } renew: { _ in XCTFail("Exactly 60 seconds remains usable"); return nil }
        var requests = [String]()
        var renewals = 0
        do {
            _ = try await pool.loadQuota(accountID: account.id) { bearer in
                requests.append(bearer)
                throw QuotaError.expired
            } renew: { _ in
                renewals += 1
                return Data(self.fresh.utf8)
            }
            XCTFail("Second rejection must propagate")
        } catch QuotaError.expired {}
        XCTAssertEqual(requests, ["old", "new"])
        XCTAssertEqual(renewals, 1)
    }

    func testMismatchedIdentityAndUnchangedOrEmptyBearerCannotOverwriteVault() async throws {
        for output in [fresh.replacingOccurrences(of: email, with: "other@example.invalid"),
                       fresh.replacingOccurrences(of: "new", with: "old"), fresh.replacingOccurrences(of: "new", with: "")] {
            let (pool, keychain, account) = try setup(expiry: "2029-01-01T00:00:00Z")
            let original = try keychain.read(service: "agy-acct-vault", account: account.id)
            do {
                _ = try await pool.loadQuota(accountID: account.id) { _ in XCTFail(); return [] }
                    renew: { _ in Data(output.utf8) }
                XCTFail("Invalid output accepted")
            } catch {}
            XCTAssertEqual(try keychain.read(service: "agy-acct-vault", account: account.id), original)
        }
    }

    func testRecheckAfterUnlockedRefreshProtectsChangedRemovedAndSelectedAccounts() async throws {
        for change in ["replace", "remove", "select"] {
            let (pool, keychain, account) = try setup(expiry: "2029-01-01T00:00:00Z")
            var expected = try keychain.read(service: "agy-acct-vault", account: account.id)
            do {
                _ = try await pool.loadQuota(accountID: account.id) { _ in XCTFail(); return [] } renew: { _ in
                    switch change {
                    case "replace":
                        expected = try credential(self.email, marker: "concurrent-update")
                        try pool.store.locked(write: true) { _ in
                            try keychain.write(service: "agy-acct-vault", account: account.id, raw: try XCTUnwrap(expected))
                        }
                    case "remove":
                        _ = try pool.remove(accountID: account.id)
                        expected = nil
                    default: _ = try pool.switchTo(accountID: account.id)
                    }
                    return Data(self.fresh.utf8)
                }
                XCTFail("Stale result accepted")
            } catch {}
            XCTAssertEqual(try keychain.read(service: "agy-acct-vault", account: account.id), expected)
        }
    }

    func testActiveCLIKeepingNearExpiryBearerUsesIsolatedRefreshAndSyncsBothCopies() async throws {
        let (pool, keychain, account) = try setup(expiry: "2030-01-01T00:00:30Z")
        keychain.active = try keychain.read(service: "agy-acct-vault", account: account.id)
        var isolated = [Bool]()
        _ = try await pool.loadQuota(accountID: account.id) { bearer in
            XCTAssertEqual(bearer, "new")
            return []
        } renew: { input in
            isolated.append(input != nil)
            return input == nil ? nil : Data(self.fresh.utf8)
        }
        XCTAssertEqual(isolated, [false, true])
        XCTAssertEqual(keychain.active, try keychain.read(service: "agy-acct-vault", account: account.id))
        XCTAssertEqual(try pool.quotaAccessToken(accountID: account.id), "new")
    }

    func testActiveRenewalPreservesOriginalLongLivedFieldsEvenWithMissingVault() throws {
        let (pool, keychain, account) = try setup(expiry: "2029-01-01T00:00:00Z")
        keychain.active = try keychain.read(service: "agy-acct-vault", account: account.id)
        try keychain.delete(service: "agy-acct-vault", account: account.id)
        _ = try pool.renewActiveQuotaToken(accountID: account.id, rejected: "old") {
            keychain.active = Data(fresh.utf8)
        }
        let stored = try Identity.credentialObject(XCTUnwrap(keychain.read(service: "agy-acct-vault", account: account.id)))
        XCTAssertEqual((stored["token"] as? [String: Any])?["refresh_token"] as? String, "long-lived")
        XCTAssertEqual(stored["writer_id"] as? String, "original")
    }

    func testWrongOriginalIdentityRefusesToLaunchHelper() async throws {
        let (pool, keychain, account) = try setup(expiry: "2030-01-01T00:00:30Z")
        try keychain.write(service: "agy-acct-vault", account: account.id, raw: credential("other@example.invalid"))
        do {
            _ = try await pool.loadQuota(accountID: account.id) { _ in XCTFail(); return [] }
                renew: { _ in XCTFail(); return nil }
            XCTFail()
        } catch AppError.invalidCredential {}
    }

    func testCancellationReapsBackendInItsOwnProcessGroup() async throws {
        let root = try directory()
        let helper = root.appendingPathComponent("helper")
        let pidFile = root.appendingPathComponent("backend")
        let script = """
        #!/usr/bin/perl
        use POSIX;
        if (fork() == 0) {
            POSIX::setsid();
            open(my $pid, '>', '../backend') or die;
            print $pid $$;
            close($pid);
            sleep 30;
            exit;
        }
        wait;
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let runner = QuotaRenewer(executable: helper, temporaryDirectory: root)
        let task = Task.detached { try runner.renew(input: Data(), checkCancellation: Task.checkCancellation) }
        defer { task.cancel() }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        task.cancel()
        do { _ = try await task.value; XCTFail() }
        catch is CancellationError {}
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["helper", "backend"])
    }

    func testSubprocessCancellationTimeoutAndDeniedLoginCleanPrivateFiles() async throws {
        let root = try directory()
        let executable = root.appendingPathComponent("helper")
        let marker = root.appendingPathComponent("pid")
        let input = Data(fresh.utf8)
        for outcome in ["cancel", "timeout", "denied"] {
            let body = """
            #!/bin/sh
            set -eu
            test "$1" = models
            test "." -ef "$HOME"
            test "$AGY_CLI_FORCE_FILE_TOKEN_STORAGE" = 1
            test -z "${ELECTRON_RUN_AS_NODE:-}"
            test "$(/usr/bin/stat -f %Lp "$HOME")" = 700
            test "$(/usr/bin/stat -f %Lp "$HOME/.gemini/antigravity-cli/antigravity-oauth-token")" = 600
            echo $$ > '../pid'
            """ + "\n" + (outcome == "denied" ? "echo 'invalid_grant' >&2\nexit 1\n" : "exec /bin/sleep 30\n")
            try body.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let runner = QuotaRenewer(executable: executable, temporaryDirectory: root, timeout: outcome == "timeout" ? 2 : 10)
            let task = Task.detached { try runner.renew(input: input, checkCancellation: Task.checkCancellation) }
            for _ in 0..<500 where !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let pid = try XCTUnwrap(Int32(String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
            if outcome == "cancel" { task.cancel() }
            do { _ = try await task.value; XCTFail() }
            catch {
                if outcome == "cancel" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? QuotaError, outcome == "denied" ? .expired : .unavailable) }
            }
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
            try FileManager.default.removeItem(at: marker)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["helper"])
        }
    }
}
