import CryptoKit
import Foundation

public struct PoolSnapshot: Equatable {
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
    public let snapshot: PoolSnapshot
    public let reloadLogin: ReloadLogin?
}

public struct ReloadLogin: Equatable {
    fileprivate let id: String
    fileprivate let lastUsedAt: Double
    fileprivate let bytes: Data
    fileprivate let previousEmail: String?
}

public struct PoolCheck {
    public let snapshot: PoolSnapshot
    public var accountCount: Int { snapshot.registry.accounts.count }
    public var hasLogin: Bool { snapshot.currentEmail != nil }
    public let logsReadable: Bool
    public let invalidVaultCount: Int
}

public final class AccountPool {
    private typealias Login = (raw: Data, identity: Identity)
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

    public func currentReloadLogin() throws -> ReloadLogin? {
        try store.locked { registry in
            guard let login = try active(), let index = registry.index(email: login.identity.email) else { return nil }
            let account = registry.accounts[index]
            return ReloadLogin(id: account.id, lastUsedAt: account.lastUsedAt, bytes: login.raw,
                               previousEmail: registry.accounts.first { $0.alias == registry.lastActiveAlias }?.email)
        }
    }

    public func verifyAfterReload(_ login: ReloadLogin) throws {
        try store.locked(write: true) { registry in
            let account = registry.accounts[try index(for: login.id, in: registry)]
            guard account.lastUsedAt == login.lastUsedAt else { throw AppError.activeChanged }
            let observed = try readActive()
            if observed == login.bytes { return }
            if let observed {
                let email = try Identity.parse(observed).email.lowercased()
                guard email == login.previousEmail?.lowercased() || email == account.email.lowercased()
                else { throw AppError.activeChanged }
            }
            try keychain.write(service: MacKeychain.activeService, account: MacKeychain.activeAccount, raw: login.bytes)
            guard try readActive() == login.bytes else { throw AppError.switchVerification }
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
            return PoolCheck(snapshot: PoolSnapshot(registry: registry, currentEmail: active?.identity.email),
                             logsReadable: logsReadable,
                             invalidVaultCount: invalid.count)
        }
    }

    @discardableResult
    public func save(alias: String, expectedEmail: String) throws -> (account: Account, snapshot: PoolSnapshot) {
        try store.locked(write: true) { registry in
            guard let active = try active() else { throw AppError.signInRequired }
            guard active.identity.email.lowercased() == expectedEmail.lowercased() else { throw Self.activeChanged }
            let account = try save(active, alias: alias, in: &registry)
            return (account, PoolSnapshot(registry: registry, currentEmail: active.identity.email))
        }
    }

    @discardableResult
    public func beginAddAccount() throws -> PoolSnapshot {
        try store.locked(write: true) { registry in
            guard var current = try active() else { return PoolSnapshot(registry: registry) }
            for _ in 0..<3 {
                let email = current.identity.email
                if let index = registry.index(email: email) {
                    if try vault.read(registry.accounts[index]) != current.raw {
                        try vault.write(registry.accounts[index], raw: current.raw)
                    }
                } else {
                    let alias = Self.defaultAlias(registry: registry, email: email)
                    try save(current, alias: alias, in: &registry)
                }

                // agy can refresh outside the registry lock. Back up those bytes too before clearing.
                guard let latest = try readActive() else { return PoolSnapshot(registry: registry) }
                if latest == current.raw {
                    try keychain.clearActiveLogin()
                    guard try readActive() == nil else { throw AppError.activeLoginVerification }
                    return PoolSnapshot(registry: registry)
                }
                let identity = try Identity.parse(latest)
                guard identity.email.lowercased() == email.lowercased() else { throw Self.activeChanged }
                current = (latest, identity)
            }
            throw AppError.credentialRefreshing
        }
    }

    @discardableResult
    public func rename(accountID: String, alias: String) throws -> PoolSnapshot {
        try store.locked(write: true) { registry in
            let index = try index(for: accountID, in: registry)
            try check(alias: alias, in: registry, except: index)
            let email = try active()?.identity.email
            rename(&registry, at: index, to: alias)
            try store.save(registry)
            return PoolSnapshot(registry: registry, currentEmail: email)
        }
    }

    @discardableResult
    public func cooldown(accountID: String, seconds: Double?) throws -> PoolSnapshot {
        try store.locked(write: true) { registry in
            let index = try index(for: accountID, in: registry)
            let email = try active()?.identity.email
            registry.accounts[index].cooldownUntil = seconds.map { clock() + $0 }
            registry.accounts[index].exhaustedReason = seconds == nil ? nil : .manual
            try store.save(registry)
            return PoolSnapshot(registry: registry, currentEmail: email)
        }
    }

    @discardableResult
    public func remove(accountID: String) throws -> PoolSnapshot {
        try store.locked(write: true) { registry in
            let index = try index(for: accountID, in: registry)
            let account = registry.accounts[index]
            let email = try active()?.identity.email
            let snapshot = try vault.read(account)
            try vault.delete(account)
            registry.accounts.remove(at: index)
            if registry.lastActiveAlias == account.alias { registry.lastActiveAlias = nil }
            do { try store.save(registry) }
            catch {
                if let snapshot { try vault.write(account, raw: snapshot) }
                throw error
            }
            return PoolSnapshot(registry: registry, currentEmail: email)
        }
    }

    public func switchTo(accountID: String) throws -> SwitchOutcome {
        try store.locked(write: true) { registry in
            let target = try index(for: accountID, in: registry)
            return try switchTo(target, in: &registry, login: active(), now: clock())
        }
    }

    public func next() throws -> SwitchOutcome {
        try store.locked(write: true) { registry in
            let login = try active()
            let now = clock()
            let current = login.flatMap { registry.index(email: $0.identity.email) }
            let target = try nextTarget(in: registry, current: current, now: now)
            return try switchTo(target, in: &registry, login: login, now: now)
        }
    }

    public func onQuota(email: String, until: Double, reason: ExhaustionReason) throws -> SwitchOutcome? {
        try store.locked(write: true) { registry in
            guard let login = try active(), login.identity.email.lowercased() == email.lowercased() else {
                return nil
            }
            guard let current = registry.index(email: login.identity.email) else {
                throw AppError.unsavedAccount
            }
            registry.accounts[current].cooldownUntil = until
            registry.accounts[current].exhaustedReason = reason
            try store.save(registry)
            let now = clock()
            let target = try nextTarget(in: registry, current: current, now: now)
            return try switchTo(target, in: &registry, login: login, now: now)
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

    private func active() throws -> Login? {
        guard let raw = try readActive() else { return nil }
        return (raw, try Identity.parse(raw))
    }

    @discardableResult
    private func save(_ active: Login, alias: String,
                      in registry: inout Registry) throws -> Account {
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
        if try existing == nil || vault.read(account) != active.raw {
            try vault.write(account, raw: active.raw)
        }
        do { try store.save(registry) }
        catch {
            if existing == nil { try? vault.delete(account) }
            throw error
        }
        return account
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

    private func switchTo(_ target: Int, in registry: inout Registry, login: Login?,
                          now: Double) throws -> SwitchOutcome {
        let account = registry.accounts[target]
        let expected = login?.identity.email.lowercased()
        let current = login.flatMap { registry.index(email: $0.identity.email) }
        if current == target {
            return SwitchOutcome(target: account.alias, changed: false,
                                 snapshot: PoolSnapshot(registry: registry, currentEmail: login?.identity.email), reloadLogin: nil)
        }
        guard let raw = try vault.read(account) else {
            throw AppError.missingSnapshot
        }
        let targetIdentity = try Identity.parse(raw)
        guard targetIdentity.email.lowercased() == account.email.lowercased() else {
            throw AppError.snapshotMismatch
        }
        let previous = current.map { registry.accounts[$0].alias }

        // CLI and App share the directory lock. agy itself may refresh the active bytes independently.
        var latest = login
        for _ in 0..<3 {
            if let current, let latest {
                if try vault.read(registry.accounts[current]) != latest.raw {
                    try vault.write(registry.accounts[current], raw: latest.raw)
                }
                recordUse(&registry.accounts[current], identity: latest.identity, now: now)
            }
            let observed = try readActive()
            if observed != latest?.raw {
                latest = try observed.map { ($0, try Identity.parse($0)) }
                guard latest?.identity.email.lowercased() == expected else { throw Self.activeChanged }
                continue
            }
            try keychain.write(service: MacKeychain.activeService, account: MacKeychain.activeAccount, raw: raw)
            guard try readActive() == raw else {
                throw AppError.switchVerification
            }
            recordUse(&registry.accounts[target], identity: targetIdentity, now: now)
            registry.lastActiveAlias = previous
            do { try store.save(registry) }
            catch { throw AppError.switchMetadataWrite }
            return SwitchOutcome(target: account.alias, changed: true,
                                 snapshot: PoolSnapshot(registry: registry, currentEmail: targetIdentity.email),
                                 reloadLogin: ReloadLogin(id: account.id, lastUsedAt: now, bytes: raw, previousEmail: expected))
        }
        throw AppError.credentialRefreshing
    }
}
