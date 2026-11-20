import Foundation
import XCTest
@testable import AgySwitchCore

final class MemoryKeychain: Keychain {
    private var items: [String: Data] = [:]
    var replaceNextActiveWrite = false
    var activeWrites = 0

    var active: Data? {
        get { items["gemini/antigravity"] }
        set { items["gemini/antigravity"] = newValue }
    }

    func read(service: String, account: String) throws -> Data? { items[service + "/" + account] }

    func write(service: String, account: String, raw: Data) throws {
        if service == "gemini" {
            activeWrites += 1
            if replaceNextActiveWrite {
                replaceNextActiveWrite = false
                return
            }
        }
        items[service + "/" + account] = raw
    }

    func delete(service: String, account: String) throws { items.removeValue(forKey: service + "/" + account) }
}

func credential(_ email: String, marker: String = "synthetic-marker") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "id_token_email": email,
        "auth_method": "oauth",
        "writer_id": "test",
        "token": ["access_token": marker, "refresh_token": marker]
    ], options: [.sortedKeys])
}

func withSandbox(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgySwitchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

func put(_ bytes: String, at url: URL, append: Bool = false) throws {
    if !append {
        try Data(bytes.utf8).write(to: url)
    } else {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes.utf8))
    }
}
