import CryptoKit
import Foundation

public struct PoolSnapshot {
    public let registry: Registry
    public let currentEmail: String?

    public init(registry: Registry = Registry(), currentEmail: String? = nil) {
        self.registry = registry
        self.currentEmail = currentEmail
    }

    public var activeID: String? {
        guard let currentEmail, let index = registry.index(email: currentEmail) else { return nil }
        return registry.accounts[index].accountID
    }

    public var suggestedAlias: String {
        guard let currentEmail else { return "" }
        return AccountPool.defaultAlias(registry: registry, email: currentEmail)
    }
}

public struct SwitchOutcome: Equatable {
    public let target: String
    public let changed: Bool
}

public struct PoolCheck {
    public let accountCount: Int
    public let hasLogin: Bool
    public let logsReadable: Bool
    public let invalidVaultCount: Int
}

public final class AccountPool {
    public let store: RegistryStore
    private let keychain: any Keychain
    private let vault: Vault
    private let clock: () -> Double

    public init(store: RegistryStore = RegistryStore(), keychain: any Keychain = MacKeychain(),
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store
        self.keychain = keychain
        self.clock = clock
        vault = Vault(home: store.home, keychain: keychain)
    }

    public func snapshot() throws -> PoolSnapshot {
        try store.locked { registry in
            PoolSnapshot(registry: registry, currentEmail: try active()?.identity.email)
        }
    }

    public func currentEmail() throws -> String? { try active()?.identity.email.lowercased() }

    public func inspect(logDirectory: URL) throws -> PoolCheck {
        try store.locked { registry in
            let active = try active()
            let invalid = registry.accounts.filter { account in
                guard let raw = try? vault.read(account), let identity = try? Identity.parse(raw) else { return true }
                return identity.email.lowercased() != account.email.lowercased()
            }
            var isDirectory: ObjCBool = false
            let logsReadable = FileManager.default.fileExists(atPath: logDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue && access(logDirectory.path, R_OK | X_OK) == 0
            return PoolCheck(accountCount: registry.accounts.count, hasLogin: active != nil,
                             logsReadable: logsReadable,
                             invalidVaultCount: invalid.count)
        }
    }

    @discardableResult
    public func save(alias: String, expectedEmail: String) throws -> Account {
        try store.locked(write: true) { registry in
            guard let active = try active() else { throw AppError.signInRequired }
            guard active.identity.email.lowercased() == expectedEmail.lowercased() else { throw Self.activeChanged }
            let existing = registry.index(email: active.identity.email)
            try check(alias: alias, in: registry, except: existing)
            let index = existing ?? registry.accounts.count
            let now = clock()
            if existing == nil {
                let id = Data(SHA256.hash(data: Data(active.identity.email.lowercased().utf8))).hex
                registry.accounts.append(Account(accountID: id, alias: alias, email: active.identity.email,
                                                 authMethod: active.identity.authMethod, addedAt: now, lastUsedAt: now))
            } else {
                rename(&registry, at: index, to: alias)
                recordUse(&registry.accounts[index], identity: active.identity, now: now)
            }
            let account = registry.accounts[index]
            try vault.write(account, raw: active.raw)
            do { try store.save(registry) }
            catch {
                if existing == nil { try? vault.delete(account) }
                throw error
            }
            return account
        }
    }

    public func rename(accountID: String, alias: String) throws {
        try store.locked(write: true) { registry in
            let index = try index(for: accountID, in: registry)
            try check(alias: alias, in: registry, except: index)
            rename(&registry, at: index, to: alias)
            try store.save(registry)
        }
    }

    public func cooldown(accountID: String, seconds: Double?) throws {
        try store.locked(write: true) { registry in
            let index = try index(for: accountID, in: registry)
            registry.accounts[index].cooldownUntil = seconds.map { clock() + $0 }
            registry.accounts[index].exhaustedReason = seconds == nil ? nil : .manual
            try store.save(registry)
        }
    }

    public func remove(accountID: String) throws {
        try store.locked(write: true) { registry in
            let index = try index(for: accountID, in: registry)
            let account = registry.accounts[index]
            let snapshot = try vault.read(account)
            try vault.delete(account)
            registry.accounts.remove(at: index)
            if registry.lastActiveAlias == account.alias { registry.lastActiveAlias = nil }
            do { try store.save(registry) }
            catch {
                if let snapshot { try vault.write(account, raw: snapshot) }
                throw error
            }
        }
    }

    public func switchTo(accountID: String) throws -> SwitchOutcome {
        try store.locked(write: true) { registry in
            let target = try index(for: accountID, in: registry)
            return try switchTo(target, in: &registry, identity: active()?.identity, now: clock())
        }
    }

    public func next() throws -> SwitchOutcome {
        try store.locked(write: true) { registry in
            let identity = try active()?.identity
            let now = clock()
            let current = identity.flatMap { registry.index(email: $0.email) }
            let target = try nextTarget(in: registry, current: current, now: now)
            return try switchTo(target, in: &registry, identity: identity, now: now)
        }
    }

    public func onQuota(email: String, until: Double, reason: ExhaustionReason) throws -> SwitchOutcome? {
        try store.locked(write: true) { registry in
            guard let identity = try active()?.identity, identity.email.lowercased() == email.lowercased() else {
                return nil
            }
            guard let current = registry.index(email: identity.email) else {
                throw AppError.unsavedAccount
            }
            registry.accounts[current].cooldownUntil = until
            registry.accounts[current].exhaustedReason = reason
            try store.save(registry)
            let now = clock()
            let target = try nextTarget(in: registry, current: current, now: now)
            return try switchTo(target, in: &registry, identity: identity, now: now)
        }
    }

    static func defaultAlias(registry: Registry, email: String) -> String {
        let local = String(email.prefix { $0 != "@" })
        let sanitized = local.replacingOccurrences(of: #"[^A-Za-z0-9_.-]+"#, with: "-", options: .regularExpression)
        let stem = String(sanitized.drop(while: { "._-".contains($0) }).prefix(42))
        let base = stem.isEmpty ? "account" : stem
        var alias = base
        var number = 2
        while registry.index(alias: alias) != nil {
            alias = "\(base)-\(number)"
            number += 1
        }
        return alias
    }

    private static let activeChanged = AppError.activeChanged

    private func readActive() throws -> Data? {
        try keychain.read(service: MacKeychain.activeService, account: MacKeychain.activeAccount)
    }

    private func active() throws -> (raw: Data, identity: Identity)? {
        guard let raw = try readActive() else { return nil }
        return (raw, try Identity.parse(raw))
    }

    private func index(for id: String, in registry: Registry) throws -> Int {
        guard let index = registry.accounts.firstIndex(where: { $0.accountID == id }) else {
            throw AppError.accountMissing
        }
        return index
    }

    private func check(alias: String, in registry: Registry, except index: Int?) throws {
        guard Validation.alias.matchesWhole(alias) else {
            throw AppError.invalidAlias
        }
        if let other = registry.index(alias: alias), other != index {
            throw AppError.duplicateAlias
        }
    }

    private func rename(_ registry: inout Registry, at index: Int, to alias: String) {
        if registry.lastActiveAlias == registry.accounts[index].alias { registry.lastActiveAlias = alias }
        registry.accounts[index].alias = alias
    }

    private func recordUse(_ account: inout Account, identity: Identity, now: Double) {
        account.email = identity.email
        account.authMethod = identity.authMethod
        account.lastUsedAt = now
    }

    private func nextTarget(in registry: Registry, current: Int?, now: Double) throws -> Int {
        let accounts = registry.accounts
        guard !accounts.isEmpty else { throw AppError.emptyPool }
        let start = current.map { $0 + 1 } ?? 0
        let others = (Array(start..<accounts.count) + Array(0..<start)).filter { $0 != current }
        if let available = others.first(where: { !accounts[$0].cooling(at: now) }) { return available }
        if others.isEmpty { throw AppError.noOtherAccounts }
        throw AppError.allOthersCooling
    }

    private func switchTo(_ target: Int, in registry: inout Registry, identity: Identity?,
                          now: Double) throws -> SwitchOutcome {
        let account = registry.accounts[target]
        let expected = identity?.email.lowercased()
        let current = identity.flatMap { registry.index(email: $0.email) }
        if current == target { return SwitchOutcome(target: account.alias, changed: false) }
        guard let raw = try vault.read(account) else {
            throw AppError.missingSnapshot
        }
        let targetIdentity = try Identity.parse(raw)
        guard targetIdentity.email.lowercased() == account.email.lowercased() else {
            throw AppError.snapshotMismatch
        }
        let previous = current.map { registry.accounts[$0].alias }

        // CLI and App share the directory lock. agy itself may refresh the active bytes independently.
        for _ in 0..<3 {
            let latest = try active()
            guard latest?.identity.email.lowercased() == expected else { throw Self.activeChanged }
            if let current, let latest {
                try vault.write(registry.accounts[current], raw: latest.raw)
                recordUse(&registry.accounts[current], identity: latest.identity, now: now)
            }
            guard try readActive() == latest?.raw else { continue }
            try keychain.write(service: MacKeychain.activeService, account: MacKeychain.activeAccount, raw: raw)
            guard try readActive() == raw else {
                throw AppError.switchVerification
            }
            recordUse(&registry.accounts[target], identity: targetIdentity, now: now)
            registry.lastActiveAlias = previous
            do { try store.save(registry) }
            catch { throw AppError.switchMetadataWrite }
            return SwitchOutcome(target: account.alias, changed: true)
        }
        throw AppError.credentialRefreshing
    }
}
