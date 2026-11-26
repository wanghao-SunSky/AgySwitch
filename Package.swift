// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgySwitch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgySwitch", targets: ["AgySwitch"]),
        .executable(name: "AgySwitchPreview", targets: ["AgySwitchPreview"])
    ],
    targets: [
        .target(name: "AgySwitchCore"),
        .target(name: "AgySwitchUI", dependencies: ["AgySwitchCore"]),
        .executableTarget(name: "AgySwitch", dependencies: ["AgySwitchCore", "AgySwitchUI"]),
        .executableTarget(name: "AgySwitchPreview", dependencies: ["AgySwitchUI"]),
        .testTarget(name: "AgySwitchCoreTests", dependencies: ["AgySwitchCore"]),
        .testTarget(name: "AgySwitchUITests", dependencies: ["AgySwitch", "AgySwitchCore", "AgySwitchUI"])
    ]
)
