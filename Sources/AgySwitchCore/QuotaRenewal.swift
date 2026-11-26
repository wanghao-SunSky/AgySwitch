import Darwin
import Foundation

struct QuotaCredential {
    let raw: Data
    let email: String
    let object: [String: Any]
    let token: [String: Any]
    let bearer: String
    let expiry: Date?

    init(_ raw: Data, email: String) throws {
        let object = try Identity.credentialObject(raw)
        guard try Identity.parse(raw).email.caseInsensitiveCompare(email) == .orderedSame,
              let token = object["token"] as? [String: Any],
              let bearer = token["access_token"] as? String, !bearer.isEmpty else {
            throw AppError.invalidCredential
        }
        self.raw = raw
        self.email = email
        self.object = object
        self.token = token
        self.bearer = bearer
        expiry = (token["expiry"] as? String).flatMap {
            let dates = ISO8601DateFormatter()
            if let date = dates.date(from: $0) { return date }
            dates.formatOptions.insert(.withFractionalSeconds)
            return dates.date(from: $0)
        }
    }

    func renewalInput() throws -> Data {
        guard let refresh = token["refresh_token"] as? String, !refresh.isEmpty else { throw QuotaError.expired }
        // The CLI otherwise reuses a still-valid bearer, including one rejected by the server.
        var fields = token
        fields["expiry"] = "2000-01-01T00:00:00Z"
        var input = object
        input["token"] = fields
        return try JSONSerialization.data(withJSONObject: input)
    }

    func merging(_ output: Data, now: Double) throws -> Data {
        let fresh = try QuotaCredential(output, email: email)
        guard bearer != fresh.bearer, let expiry = fresh.expiry, expiry.timeIntervalSince1970 > now else {
            throw QuotaError.unavailable
        }
        return try preservingFields(in: fresh)
    }

    func preservingFields(in fresh: QuotaCredential) throws -> Data {
        guard email.caseInsensitiveCompare(fresh.email) == .orderedSame else { throw AppError.invalidCredential }
        var fields = token.merging(fresh.token) { _, new in new }
        if (fresh.token["refresh_token"] as? String)?.isEmpty != false {
            fields["refresh_token"] = token["refresh_token"]
        }
        guard let refresh = fields["refresh_token"] as? String, !refresh.isEmpty else { throw QuotaError.expired }
        var merged = object.merging(fresh.object) { _, new in new }
        merged["token"] = fields
        if let writer = object["writer_id"] { merged["writer_id"] = writer }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys, .withoutEscapingSlashes])
        return Data("go-keyring-base64:".utf8) + data.base64EncodedData()
    }
}

struct QuotaRenewer {
    let executable: URL
    var temporaryDirectory = FileManager.default.temporaryDirectory
    var timeout: TimeInterval = 15

    func renew(input: Data?, checkCancellation: () throws -> Void) throws -> Data? {
        try checkCancellation()
        var pattern = temporaryDirectory.appendingPathComponent("AgySwitch-quota-XXXXXX").path.utf8CString
        let path = pattern.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        guard let path else { throw AppError.fileIO }
        let home = URL(fileURLWithPath: path, isDirectory: true)
        let files = FileManager.default
        do {
            let config = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
            let credential = config.appendingPathComponent("antigravity-oauth-token")
            var env = ProcessInfo.processInfo.environment
            if let input {
                try files.createDirectory(at: config, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
                try PrivateFiles.write(input, to: credential)
                env = env.filter { ["http_proxy", "https_proxy", "all_proxy", "no_proxy"].contains($0.key.lowercased()) }
                env["PATH"] = "/usr/bin:/bin"
                env["HOME"] = home.path
                env["TMPDIR"] = home.path
                env["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
                env["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache").path
                env["AGY_CLI_FORCE_FILE_TOKEN_STORAGE"] = "1"
                env["SSH_CONNECTION"] = "1 2 3 4"
            } else {
                for key in ["ELECTRON_RUN_AS_NODE", "AGY_CLI_FORCE_FILE_TOKEN_STORAGE", "SSH_CONNECTION", "SSH_TTY", "SSH_CLIENT"] {
                    env.removeValue(forKey: key)
                }
            }
            env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
            let diagnostics = home.appendingPathComponent("stderr")
            try PrivateFiles.write(Data(), to: diagnostics)
            let output = try FileHandle(forWritingTo: diagnostics)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["models"]
            process.currentDirectoryURL = home
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = output
            try run(process, checkCancellation: checkCancellation)
            if process.terminationStatus != 0 {
                let message = String(decoding: try PrivateFiles.read(diagnostics) ?? Data(), as: UTF8.self).lowercased()
                if message.contains("invalid_grant") { throw QuotaError.expired }
                if message.contains("please sign in") {
                    if input == nil { throw QuotaError.expired }
                    // An offline CLI can give the same generic sign-in prompt. Its private
                    // log distinguishes OAuth rejection from a transport failure.
                    let log = config.appendingPathComponent("cli.log")
                    if let data = try? Data(contentsOf: log), data.range(of: Data("invalid_grant".utf8)) != nil {
                        throw QuotaError.expired
                    }
                }
                throw QuotaError.unavailable
            }
            try checkCancellation()
            let result = input == nil ? nil : try PrivateFiles.read(credential)
            try files.removeItem(at: home)
            return result
        } catch {
            if files.fileExists(atPath: home.path) { try files.removeItem(at: home) }
            throw error
        }
    }

    private func run(_ process: Process, checkCancellation: () throws -> Void) throws {
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try checkCancellation()
        try process.run()
        let pid = process.processIdentifier
        // Darwin Foundation launches Process in its own process group.
        let grouped = getpgid(pid) == pid
        var children = [pid_t: Child]()
        defer {
            if process.isRunning { Child.collect(of: pid, into: &children) }
            // agy may put its backend in a separate process group.
            for child in children.values { child.stopIfRunning() }
            if grouped { kill(-pid, SIGKILL) }
            if process.isRunning { kill(pid, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = DispatchTime.now() + timeout
        while finished.wait(timeout: .now() + .milliseconds(40)) == .timedOut {
            Child.collect(of: pid, into: &children)
            try checkCancellation()
            if DispatchTime.now() >= deadline { throw QuotaError.unavailable }
        }
        try checkCancellation()
    }

    private struct Child {
        let pid: pid_t
        let seconds: UInt64
        let micros: UInt64

        static func info(_ pid: pid_t) -> proc_bsdinfo? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == getuid() else { return nil }
            return info
        }

        static func collect(of parent: pid_t, into children: inout [pid_t: Child]) {
            var pids = [pid_t](repeating: 0, count: 8)
            let stride = MemoryLayout<pid_t>.stride
            var used = Int(proc_listchildpids(parent, &pids, Int32(pids.count * stride)))
            while used == pids.count {
                pids += Array(repeating: 0, count: pids.count)
                used = Int(proc_listchildpids(parent, &pids, Int32(pids.count * stride)))
            }
            for pid in pids.prefix(max(0, used)) where pid > 1 {
                guard let info = info(pid), info.pbi_ppid == UInt32(parent) else { continue }
                children[pid] = Child(pid: pid, seconds: info.pbi_start_tvsec, micros: info.pbi_start_tvusec)
                collect(of: pid, into: &children)
            }
        }

        func stopIfRunning() {
            guard let info = Self.info(pid), info.pbi_start_tvsec == seconds, info.pbi_start_tvusec == micros else { return }
            kill(pid, SIGKILL)
        }
    }
}
