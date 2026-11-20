import CoreFoundation
import Darwin
import Foundation

enum PrivateFiles {
    static let directoryError = AppError.insecureDirectory
    static let fileError = AppError.insecureFile
    static let ioError = AppError.fileIO

    static func directory(_ url: URL, create: Bool = false) throws -> Int32? {
        if create {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                // open/fstat below distinguish a concurrent creation from a bad path.
            }
        }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if !create && errno == ENOENT { return nil }
            throw directoryError
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & 0o7777 == 0o700, info.st_uid == getuid() else {
            close(fd)
            throw directoryError
        }
        return fd
    }

    static func read(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw fileError
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o600, info.st_uid == getuid() else { throw fileError }
        do { return try file.readToEnd() ?? Data() }
        catch { throw ioError }
    }

    static func write(_ data: Data, to url: URL) throws {
        var template = (url.deletingLastPathComponent().appendingPathComponent(".agy-acct-XXXXXX").path)
            .utf8CString
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw ioError }
        let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? file.close()
            unlink(path)
        }
        guard fchmod(fd, 0o600) == 0 else { throw ioError }
        do { try file.write(contentsOf: data) }
        catch { throw ioError }
        guard fsync(fd) == 0, rename(path, url.path) == 0 else { throw ioError }
    }
}

public struct RegistryStore {
    public let home: URL
    var path: URL { home.appendingPathComponent("registry.json") }

    public init(home: URL = Self.defaultHome()) { self.home = home }

    public static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let override = environment["AGY_ACCT_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        return URL(fileURLWithPath: ((override ?? "~/.config/agy-acct") as NSString).expandingTildeInPath)
    }

    public func locked<T>(write: Bool = false, _ body: (inout Registry) throws -> T) throws -> T {
        guard let fd = try PrivateFiles.directory(home, create: write) else {
            var empty = Registry()
            return try body(&empty)
        }
        defer { close(fd) }
        while flock(fd, write ? LOCK_EX : LOCK_SH) != 0 {
            guard errno == EINTR else { throw PrivateFiles.ioError }
        }
        var registry = try load()
        return try body(&registry)
    }

    public func save(_ registry: Registry) throws {
        guard registry.isValid else { throw Registry.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(registry)
        data.append(10)
        try PrivateFiles.write(data, to: path)
    }

    private func load() throws -> Registry {
        guard let data = try PrivateFiles.read(path) else { return Registry() }
        do {
            // JSONDecoder accepts an integral JSON float as Int. The CLI requires an integer v1 marker.
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = object["version"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(),
                  !["d", "f"].contains(String(cString: version.objCType)) else { throw Registry.invalid }
            return try JSONDecoder().decode(Registry.self, from: data)
        } catch {
            throw Registry.invalid
        }
    }
}
