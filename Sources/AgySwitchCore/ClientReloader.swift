import Foundation

public struct AgyProcess: Equatable {
    public enum Kind { case acp, cli }
    public let pid: Int32
    public let startedSeconds: UInt64
    public let startedMicros: UInt64
    public let kind: Kind

    /// ps flattens argv and cannot distinguish an argument containing spaces.
    /// Verify the command prefix against the kernel's argv[0] and executable.
    public init?(psRow: Substring, executable: String, arguments: [String], ownPID: Int32,
                 startedSeconds: UInt64, startedMicros: UInt64) {
        let fields = psRow.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard fields.count == 2, let pid = Int32(fields[0]), pid > 1, pid != ownPID,
              (executable as NSString).lastPathComponent == "agy",
              let name = arguments.first, (name as NSString).lastPathComponent == "agy",
              fields[1] == name || fields[1].hasPrefix(name + " ") else { return nil }
        self.pid = pid
        self.startedSeconds = startedSeconds
        self.startedMicros = startedMicros
        kind = arguments.dropFirst().contains("acp") ? .acp : .cli
    }
}

public protocol ProcessControl {
    func processes() async throws -> [AgyProcess]
    func terminate(_ process: AgyProcess) -> Bool
    func isRunning(_ process: AgyProcess) -> Bool
}

@MainActor public protocol DesktopAppControl {
    func runningApplication(bundleID: String) -> (any DesktopApplication)?
    func reopen(at url: URL) async throws
}

@MainActor public protocol DesktopApplication {
    var bundleURL: URL? { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
}

public struct ClientReloadOutcome {
    public enum Desktop { case absent, restarted, stillRunning, failed }
    public internal(set) var desktop = Desktop.absent
    public internal(set) var reloadedAcpCount = 0
    public internal(set) var stoppedCliCount = 0
    public internal(set) var unfinishedProcesses = 0
    public internal(set) var processScanFailed = false
    public var hasWarning: Bool {
        processScanFailed || unfinishedProcesses > 0 || desktop == .stillRunning || desktop == .failed
    }
}

@MainActor public struct ClientReloader {
    public static let desktopBundleID = "com.google.antigravity"
    private let processes: any ProcessControl
    private let desktop: any DesktopAppControl
    private let pause: () async -> Void
    private let uptime: () -> Double

    public init(processes: any ProcessControl, desktop: any DesktopAppControl,
                uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                pause: @escaping () async -> Void = { try? await Task.sleep(nanoseconds: 50_000_000) }) {
        self.processes = processes
        self.desktop = desktop
        self.uptime = uptime
        self.pause = pause
    }

    public func reloadClients() async -> ClientReloadOutcome {
        var outcome = ClientReloadOutcome()
        let app = desktop.runningApplication(bundleID: Self.desktopBundleID)
        do {
            var pending = try await processes.processes().filter { process in
                if processes.terminate(process) { return true }
                if processes.isRunning(process) { outcome.unfinishedProcesses += 1 }
                return false
            }
            let deadline = uptime() + 1.5
            while !pending.isEmpty {
                pending.removeAll { process in
                    guard !processes.isRunning(process) else { return false }
                    switch process.kind {
                    case .acp: outcome.reloadedAcpCount += 1
                    case .cli: outcome.stoppedCliCount += 1
                    }
                    return true
                }
                if pending.isEmpty || uptime() >= deadline { break }
                await pause()
            }
            outcome.unfinishedProcesses += pending.count
        } catch {
            outcome.processScanFailed = true
        }
        guard let app, !app.isTerminated else { return outcome }
        guard let url = app.bundleURL else { outcome.desktop = .failed; return outcome }
        guard app.terminate() else { outcome.desktop = .stillRunning; return outcome }
        let deadline = uptime() + 5
        while !app.isTerminated && uptime() < deadline { await pause() }
        guard app.isTerminated else { outcome.desktop = .stillRunning; return outcome }
        do {
            try await desktop.reopen(at: url)
            outcome.desktop = .restarted
        } catch {
            outcome.desktop = .failed
        }
        return outcome
    }
}
