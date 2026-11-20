import Darwin
import Foundation

public enum TerminalCommand {
    public static func create(for executable: URL, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        var template = directory.appendingPathComponent("AgySwitch-XXXXXX.command").path.utf8CString
        let fd = template.withUnsafeMutableBufferPointer { mkstemps($0.baseAddress!, Int32(".command".utf8.count)) }
        guard fd >= 0 else { throw AppError.terminalLaunch }
        let url = template.withUnsafeBufferPointer { URL(fileURLWithPath: String(cString: $0.baseAddress!)) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        /bin/rm -f "$0"
        printf '\\033[8;38;108t'
        clear
        exec \(quoted)

        """
        do {
            try file.write(contentsOf: Data(script.utf8))
            guard fchmod(fd, 0o700) == 0 else { throw AppError.terminalLaunch }
            try file.close()
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw AppError.terminalLaunch
        }
    }
}
