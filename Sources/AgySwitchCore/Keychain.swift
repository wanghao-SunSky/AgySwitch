import Foundation
import Security

public protocol Keychain {
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, raw: Data) throws
    func delete(service: String, account: String) throws
    func clearActiveLogin() throws
}

// Legacy login Keychain entries may grant password access only to /usr/bin/security.
// Attribute-only reads do not need password access. Keychain timestamps have second precision.
private final class LoginKeychain {
    struct Version: Equatable {
        let reference: Data
        let modified: Date
    }
    struct Entry {
        let version: Version
        let bytes: Data
    }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let chain: SecKeychain?

    init(path: String) {
        var item: SecKeychain?
        chain = SecKeychainOpen(path, &item) == errSecSuccess ? item : nil
    }

    func requireUnlocked() throws {
        guard let chain else { throw AppError.keychainUnavailable }
        var status = SecKeychainStatus()
        guard SecKeychainGetStatus(chain, &status) == errSecSuccess,
              status & UInt32(kSecUnlockStateStatus) != 0 else { throw AppError.keychainUnavailable }
    }

    func read(service: String, account: String, load: () throws -> Data?) rethrows -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let key = service + "\u{0}" + account
        guard let version = version(service, account) else {
            entries.removeValue(forKey: key)
            return try load()
        }
        if let entry = entries[key], entry.version == version { return entry.bytes }
        entries.removeValue(forKey: key)
        let settled = version.modified.timeIntervalSinceNow < -2
        let bytes = try load()
        if let bytes, settled, self.version(service, account) == version {
            entries[key] = Entry(version: version, bytes: bytes)
        }
        return bytes
    }

    private func version(_ service: String, _ account: String) -> Version? {
        guard let chain else { return nil }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecMatchSearchList: [chain],
            kSecAttrService: service, kSecAttrAccount: account, kSecReturnAttributes: true,
            kSecReturnPersistentRef: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let fields = item as? [CFString: Any], let reference = fields[kSecValuePersistentRef] as? Data,
              let modified = fields[kSecAttrModificationDate] as? Date else { return nil }
        return Version(reference: reference, modified: modified)
    }
}

public struct MacKeychain: Keychain {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    typealias Runner = ([String], Data?) throws -> Result
    static let activeService = "gemini"
    static let activeAccount = "antigravity"
    static let vaultService = "agy-acct-vault"
    static let executable = "/usr/bin/security"
    private static let notFound: Int32 = 44
    private static let executionError = AppError.keychainUnavailable
    private static let hexDetail = try! NSRegularExpression(pattern: #"^password: 0x([0-9A-Fa-f]+)(?: |$)"#,
                                                            options: .anchorsMatchLines)
    private static let textDetail = try! NSRegularExpression(pattern: #"^password: "([^\n]*)"$"#,
                                                             options: .anchorsMatchLines)

    private var cache: LoginKeychain?
    private let path: String
    private let runner: Runner

    public init() {
        self.init(path: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path, runner: Self.run)
        cache = LoginKeychain(path: path)
    }

    init(path: String, runner: @escaping Runner) {
        self.path = path
        self.runner = runner
    }

    public func read(service: String, account: String) throws -> Data? {
        if let cache {
            try cache.requireUnlocked()
            return try cache.read(service: service, account: account) { try readPassword(service, account) }
        }
        return try readPassword(service, account)
    }

    private func readPassword(_ service: String, _ account: String) throws -> Data? {
        let query = ["-s", service, "-a", account, path]
        let result = try execute(["find-generic-password", "-w"] + query)
        if result.status == Self.notFound { return nil }
        guard result.status == 0 else { throw AppError.keychainRead }
        let raw = result.stdout.last == 10 ? Data(result.stdout.dropLast()) : result.stdout
        guard Data(hexBytes: raw) != nil else { return raw }

        // security -w prints binary passwords and literal ASCII hex in the same form.
        let detail = try execute(["find-generic-password", "-g"] + query)
        guard detail.status == 0 else { throw AppError.keychainHexCheck }
        let content = String(decoding: detail.stderr, as: UTF8.self)
        let range = NSRange(content.startIndex..., in: content)
        if let match = Self.hexDetail.firstMatch(in: content, range: range),
           let digits = Range(match.range(at: 1), in: content),
           let bytes = Data(hexBytes: content[digits].utf8) { return bytes }
        if let match = Self.textDetail.firstMatch(in: content, range: range),
           let value = Range(match.range(at: 1), in: content) { return Data(content[value].utf8) }
        throw AppError.keychainHexFormat
    }

    public func write(service: String, account: String, raw: Data) throws {
        try cache?.requireUnlocked()
        let command = try Self.writeCommand(service: service, account: account, raw: raw, path: path)
        guard try execute(["-i"], input: command).status == 0 else {
            throw AppError.keychainWrite
        }
    }

    public func delete(service: String, account: String) throws {
        guard service == Self.vaultService else { throw AppError.protectedKeychainEntry }
        try deleteEntry(service: service, account: account, failure: .keychainDelete)
    }

    public func clearActiveLogin() throws {
        try deleteEntry(service: Self.activeService, account: Self.activeAccount, failure: .activeLoginDelete)
    }

    private func deleteEntry(service: String, account: String, failure: AppError) throws {
        try cache?.requireUnlocked()
        let result = try execute(["delete-generic-password", "-s", service, "-a", account, path])
        guard result.status == 0 || result.status == Self.notFound else {
            throw failure
        }
    }

    static func writeCommand(service: String, account: String, raw: Data, path: String) throws -> Data {
        guard [service, account, path].allSatisfy({ !$0.utf8.contains(10) && !$0.utf8.contains(0) }) else {
            throw AppError.keychainPath
        }
        let prefix = "add-generic-password -U -s \(quote(service)) -a \(quote(account))"
        let suffix = " \(quote(path))\n"
        var line = prefix + " -X " + raw.hex + suffix
        if line.utf8.count >= 4096 && raw.allSatisfy({ (32...126).contains($0) }) {
            line = prefix + " -w " + quote(String(decoding: raw, as: UTF8.self)) + suffix
        }
        guard line.utf8.count < 4096 else {
            throw AppError.credentialTooLong
        }
        return Data(line.utf8)
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func execute(_ args: [String], input: Data? = nil) throws -> Result {
        do { return try runner(args, input) }
        catch { throw Self.executionError }
    }

    private final class PipeBuffer: @unchecked Sendable {
        // Each buffer has one writer. The dispatch group synchronizes reads with that writer.
        var data = Data()
    }

    private static func run(_ args: [String], _ input: Data?) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        if input != nil { process.standardInput = stdin }
        else { process.standardInput = FileHandle.nullDevice }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        let captured = DispatchGroup()
        let stdout = PipeBuffer(), stderr = PipeBuffer()
        for (pipe, buffer) in [(out, stdout), (err, stderr)] {
            DispatchQueue.global(qos: .utility).async(group: captured) {
                buffer.data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            }
        }
        if let input {
            let writer = stdin.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        if terminated.wait(timeout: .now() + 15) == .timedOut {
            if process.isRunning { process.terminate() }
            if terminated.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw executionError
        }
        guard captured.wait(timeout: .now() + 1) == .success else { throw executionError }
        return Result(status: process.terminationStatus, stdout: stdout.data, stderr: stderr.data)
    }
}

struct Vault {
    let directory: URL
    let keychain: any Keychain

    init(home: URL, keychain: any Keychain) {
        directory = home.appendingPathComponent("vault", isDirectory: true)
        self.keychain = keychain
    }

    func read(_ account: Account) throws -> Data? {
        if account.store == .keychain {
            return try keychain.read(service: MacKeychain.vaultService, account: account.accountID)
        }
        guard let fd = try PrivateFiles.directory(directory) else { return nil }
        defer { close(fd) }
        return try PrivateFiles.read(path(account))
    }

    func write(_ account: Account, raw: Data) throws {
        if account.store == .keychain {
            try keychain.write(service: MacKeychain.vaultService, account: account.accountID, raw: raw)
        } else if let fd = try PrivateFiles.directory(directory, create: true) {
            defer { close(fd) }
            try PrivateFiles.write(raw, to: path(account))
        }
        guard try read(account) == raw else { throw AppError.snapshotVerification }
    }

    func delete(_ account: Account) throws {
        if account.store == .keychain {
            try keychain.delete(service: MacKeychain.vaultService, account: account.accountID)
        } else if let fd = try PrivateFiles.directory(directory) {
            defer { close(fd) }
            if unlink(path(account).path) != 0 && errno != ENOENT { throw PrivateFiles.ioError }
        }
        guard try read(account) == nil else { throw AppError.snapshotDeletionVerification }
    }

    private func path(_ account: Account) -> URL { directory.appendingPathComponent(account.accountID) }
}
