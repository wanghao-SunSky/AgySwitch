import Foundation

public struct LoginItem {
    private static let identifier = "com.agyacct.agyswitch"
    private let directory: URL
    private let executable: String
    private let registryHome: String?
    private var path: URL { directory.appendingPathComponent(Self.identifier + ".plist") }

    private enum Failure: Error { case conflictingFile, installRequired }

    public init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let homeOverride = ProcessInfo.processInfo.environment["AGY_ACCT_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        self.init(directory: directory, executable: "/Applications/AgySwitch.app/Contents/MacOS/AgySwitch",
                  registryHome: homeOverride.map { _ in RegistryStore.defaultHome().path })
    }

    init(directory: URL, executable: String, registryHome: String? = nil) {
        self.directory = directory
        self.executable = executable
        self.registryHome = registryHome
    }

    public func enabled() throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: path.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return false
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: Any],
              plist["Label"] as? String == Self.identifier,
              plist["ProgramArguments"] as? [String] == [executable],
              plist["RunAtLoad"] as? Bool == true else { throw Failure.conflictingFile }
        return true
    }

    public func toggle() throws -> Bool {
        if try enabled() {
            try FileManager.default.removeItem(at: path)
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw Failure.installRequired }
        var plist: [String: Any] = [
            "Label": Self.identifier,
            "ProgramArguments": [executable],
            "RunAtLoad": true
        ]
        if let registryHome { plist["EnvironmentVariables"] = ["AGY_ACCT_HOME": registryHome] }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stage = directory.appendingPathComponent(".AgySwitch-\(UUID())")
        try PrivateFiles.write(data, to: stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        // Publish the complete file without replacing a concurrently created configuration.
        try FileManager.default.linkItem(at: stage, to: path)
        return true
    }
}
