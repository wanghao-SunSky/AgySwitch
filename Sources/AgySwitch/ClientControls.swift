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

    func hasRemainingClients(at url: URL) -> Bool {
        if runningApplication(bundleID: ClientReloader.desktopBundleID) != nil { return true }
        let server = url.appendingPathComponent("Contents/Resources/bin/language_server").path
        let size = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard size > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 128)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let used = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, capacity)
        guard used > 0, used < capacity else { return true }
        return pids.prefix(Int(used) / MemoryLayout<pid_t>.stride).contains { pid in
            guard pid > 1 else { return false }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            return proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path) == server
        }
    }

    func reopen(at url: URL) async throws {
        guard Bundle(url: url)?.bundleIdentifier == ClientReloader.desktopBundleID else {
            throw CocoaError(.executableLoad)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // An Electron-based launcher can export this to every child, including LaunchServices.
        // An empty value leaves Electron in desktop mode.
        configuration.environment = ["ELECTRON_RUN_AS_NODE": ""]
        for attempt in 0..<2 {
            let launched: NSRunningApplication?
            if attempt == 0 {
                launched = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            } else {
                let opener = Process()
                opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                opener.arguments = ["-a", url.path]
                var environment = ProcessInfo.processInfo.environment
                environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
                opener.environment = environment
                try opener.run()
                launched = nil
            }
            try await Task.sleep(for: .milliseconds(1500))
            if NSRunningApplication.runningApplications(withBundleIdentifier: ClientReloader.desktopBundleID)
                .contains(where: { !$0.isTerminated && (attempt == 1 || $0.processIdentifier == launched?.processIdentifier) }) { return }
        }
        throw CocoaError(.executableLoad)
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
        guard let path = executable(process.pid), path == process.executable,
              isRunning(process) else { return false }
        if var token = auditToken(process.pid) {
            guard executable(process.pid) == path, isRunning(process) else { return false }
            if proc_signal_with_audittoken(&token, SIGTERM) == 0 { return true }
        }
        guard executable(process.pid) == path, isRunning(process) else { return false }
        return kill(process.pid, SIGTERM) == 0
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
