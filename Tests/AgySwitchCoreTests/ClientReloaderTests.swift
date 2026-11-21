import XCTest
@testable import AgySwitchCore

final class ClientReloaderTests: XCTestCase {
    func testOnlyVerifiedExecutablesAndWholeArgumentsMatch() {
        func parse(_ command: String, _ path: String, _ args: [String], pid: Int = 71) -> AgyProcess.Kind? {
            AgyProcess(psRow: "   \(pid) \(command)", executable: path, arguments: args, ownPID: 42,
                       startedSeconds: 123, startedMicros: 45)?.kind
        }
        let path = "/Users/Test User/.local/bin/agy"
        XCTAssertEqual(parse("\(path) --flag acp", path, [path, "--flag", "acp"]), .acp)
        XCTAssertEqual(parse("agy acp", path, ["agy", "acp"]), .acp)
        XCTAssertEqual(parse("agy", path, ["agy"]), .cli)
        XCTAssertEqual(parse("agy --prompt use acp here", path, ["agy", "--prompt", "use acp here"]), .cli)
        XCTAssertEqual(parse("agy acp-server", path, ["agy", "acp-server"]), .cli)
        for executable in ["/bin/zsh", "/usr/bin/grep", "/Apps/T3 Code", "/Apps/AgySwitch", "/tmp/agy-wrapper"] {
            XCTAssertNil(parse("\(executable) -c agy acp", executable, [executable, "-c", "agy acp"]))
            XCTAssertNil(parse("agy acp", executable, ["agy", "acp"]))
        }
        XCTAssertNil(parse("agy-wrapper acp", path, ["agy", "acp"]))
        for pid in [-1, 0, 1, 42] { XCTAssertNil(parse("agy", path, ["agy"], pid: pid)) }
    }

    private final class Processes: ProcessControl {
        var entries: [AgyProcess] = []
        var sent: [Int32] = []
        var alive = Set<Int32>()
        var fail = false
        func processes() async throws -> [AgyProcess] {
            if fail { throw CocoaError(.fileReadUnknown) }
            return entries
        }
        func terminate(_ process: AgyProcess) -> Bool {
            sent.append(process.pid)
            return true
        }
        func isRunning(_ process: AgyProcess) -> Bool { alive.contains(process.pid) }
    }

    @MainActor private final class Desktop: DesktopAppControl, DesktopApplication {
        var running = true
        var bundleURL: URL? = URL(fileURLWithPath: "/Applications/Antigravity.app")
        var isTerminated = false
        var requests = 0
        var opened: [URL] = []
        var failOpen = false
        func runningApplication(bundleID: String) -> (any DesktopApplication)? {
            XCTAssertEqual(bundleID, "com.google.antigravity")
            return running ? self : nil
        }
        func terminate() -> Bool { requests += 1; return true }
        func hasRemainingClients(at url: URL) -> Bool { !isTerminated }
        func reopen(at url: URL) async throws {
            XCTAssertTrue(isTerminated)
            opened.append(url)
            if failOpen { throw CocoaError(.fileReadUnknown) }
        }
    }

    @MainActor func testSharedProcessDeadlineAndGracefulDesktopRestart() async {
        let processes = Processes(), desktop = Desktop()
        for (pid, args) in [(11, ["agy", "acp"]), (12, ["agy"]), (13, ["agy"]), (14, ["agy"])] {
            let row = "\(pid) " + args.joined(separator: " ")
            processes.entries.append(AgyProcess(psRow: row[...], executable: "/bin/agy", arguments: args, ownPID: 42,
                                                startedSeconds: 1, startedMicros: 0)!)
        }
        processes.alive = [11]
        var now = 0.0
        let sut = ClientReloader(processes: processes, desktop: desktop, uptime: { now }, pause: {
            now += 0.25
            processes.alive.remove(11)
            if desktop.requests == 1 { desktop.isTerminated = true }
        })
        let result = await sut.reloadClients()
        XCTAssertEqual(result.desktop, .restarted)
        XCTAssertEqual(desktop.requests, 1)
        XCTAssertEqual(desktop.opened, [desktop.bundleURL!])
        XCTAssertEqual(result.reloadedAcpCount, 1)
        XCTAssertEqual(result.stoppedCliCount, 3)
        XCTAssertEqual(result.unfinishedProcesses, 0)
        XCTAssertEqual(processes.sent, [11, 12, 13, 14])
        XCTAssertEqual(now, 1.0)
    }

    @MainActor func testDesktopAlreadyExitedWhileStoppingCLIStillReopensAfterVerification() async {
        let processes = Processes(), desktop = Desktop()
        processes.entries = [AgyProcess(psRow: "11 agy", executable: "/bin/agy", arguments: ["agy"],
                                        ownPID: 42, startedSeconds: 1, startedMicros: 0)!]
        processes.alive = [11]
        var time = 0.0
        let reloader = ClientReloader(processes: processes, desktop: desktop, uptime: { time }, pause: {
            time += 0.25
            desktop.isTerminated = true
            processes.alive.removeAll()
        })
        var verified = false
        let outcome = await reloader.reloadClients {
            XCTAssertTrue(desktop.opened.isEmpty)
            XCTAssertTrue(desktop.isTerminated)
            verified = true
        }
        XCTAssertTrue(verified)
        XCTAssertEqual(outcome.desktop, .restarted)
        XCTAssertEqual(desktop.requests, 0)
    }

    @MainActor func testAbsentTimedOutAndFailedDesktop() async {
        let processes = Processes(), desktop = Desktop()
        var now = 0.0
        let sut = ClientReloader(processes: processes, desktop: desktop, uptime: { now }, pause: {
            now += 0.25
            if desktop.failOpen { desktop.isTerminated = true }
        })
        desktop.running = false
        let absent = await sut.reloadClients()
        XCTAssertEqual(absent.desktop, .absent)
        XCTAssertFalse(absent.hasWarning)
        XCTAssertEqual(desktop.requests, 0)
        desktop.running = true
        let timeout = await sut.reloadClients()
        XCTAssertEqual(timeout.desktop, .stillRunning)
        XCTAssertEqual(desktop.requests, 1)
        XCTAssertEqual(now, 20)
        XCTAssertTrue(desktop.opened.isEmpty)
        desktop.failOpen = true
        let failed = await sut.reloadClients()
        XCTAssertEqual(failed.desktop, .failed)
        processes.fail = true
        let scanFailed = await sut.reloadClients()
        XCTAssertTrue(scanFailed.processScanFailed)
    }
}
