import Foundation
import XCTest
@testable import AgySwitchCore

final class LoginItemTests: XCTestCase {
    func testToggleUsesOnlyTheNamedLaunchAgentAndPreservesConflicts() throws {
        try withSandbox { root in
            let directory = root.appendingPathComponent("LaunchAgents")
            let file = directory.appendingPathComponent("com.agyacct.agyswitch.plist")
            let executable = root.appendingPathComponent("AgySwitch")
            try Data().write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let item = LoginItem(directory: directory, executable: executable.path, registryHome: "/tmp/account pool")
            XCTAssertFalse(try item.enabled())
            XCTAssertTrue(try item.toggle())
            XCTAssertTrue(try item.enabled())
            let data = try Data(contentsOf: file)
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(plist["Label"] as? String, "com.agyacct.agyswitch")
            XCTAssertEqual(plist["ProgramArguments"] as? [String], [executable.path])
            XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
            XCTAssertEqual(plist["EnvironmentVariables"] as? [String: String], ["AGY_ACCT_HOME": "/tmp/account pool"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [file.lastPathComponent])

            XCTAssertFalse(try item.toggle())
            XCTAssertFalse(try item.enabled())
            let conflict = Data("unrelated fixture".utf8)
            try conflict.write(to: file)
            XCTAssertThrowsError(try item.toggle())
            XCTAssertEqual(try Data(contentsOf: file), conflict)
        }
    }
}
