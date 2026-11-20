import AgySwitchCore
import AppKit
import Darwin

@MainActor private struct RunningDesktop: DesktopApplication {
    let app: NSRunningApplication
    var bundleURL: URL? { app.bundleURL }
    var isTerminated: Bool { app.isTerminated }
    func terminate() -> Bool { app.terminate() }
}

struct WorkspaceDesktopControl: DesktopAppControl {
    func runningApplication(bundleID: String) -> (any DesktopApplication)? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.bundleIdentifier == bundleID && !$0.isTerminated }.map(RunningDesktop.init)
    }

    func reopen(at url: URL) async throws {
        guard Bundle(url: url)?.bundleIdentifier == ClientReloader.desktopBundleID else {
            throw CocoaError(.executableLoad)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

struct LocalProcessControl: ProcessControl {
    func processes() async throws -> [AgyProcess] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard ps.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { row in
            guard row.contains("agy"), let id = row.split(maxSplits: 1, whereSeparator: \.isWhitespace).first,
                  let pid = Int32(id), let info = processInfo(pid),
                  let path = executable(pid), (path as NSString).lastPathComponent == "agy",
                  let arguments = arguments(pid) else { return nil }
            return AgyProcess(psRow: row, executable: path, arguments: arguments, ownPID: getpid(),
                              startedSeconds: info.pbi_start_tvsec, startedMicros: info.pbi_start_tvusec)
        }
    }

    func terminate(_ process: AgyProcess) -> Bool {
        // A PID can be recycled after validation. The kernel checks the audit
        // token's PID version when delivering this signal, including across exec.
        guard var token = auditToken(process.pid), let path = executable(process.pid), (path as NSString).lastPathComponent == "agy",
              isRunning(process) else { return false }
        return proc_signal_with_audittoken(&token, SIGTERM) == 0
    }

    func isRunning(_ process: AgyProcess) -> Bool {
        guard let info = processInfo(process.pid) else { return false }
        return info.pbi_start_tvsec == process.startedSeconds && info.pbi_start_tvusec == process.startedMicros
    }

    private func auditToken(_ pid: Int32) -> audit_token_t? {
        var port = mach_port_name_t()
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t()
        let words = MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(words)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: words) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        return status == KERN_SUCCESS && count == words ? token : nil
    }

    private func processInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard pid > 1, pid != getpid(), proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { return nil }
        return info
    }

    private func executable(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private func arguments(_ pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        // argc, executable path, NUL padding, then exactly argc NUL-terminated arguments.
        let data = bytes.prefix(size)
        guard argc > 0, let end = data.dropFirst(4).firstIndex(of: 0),
              var start = data[end...].firstIndex(where: { $0 != 0 }) else { return nil }
        var result: [String] = []
        for _ in 0..<argc {
            guard let stop = data[start...].firstIndex(of: 0) else { return nil }
            result.append(String(decoding: data[start..<stop], as: UTF8.self))
            start = stop + 1
        }
        return result
    }
}
