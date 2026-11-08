// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LanChat",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "LanChatCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "LanChat",
            dependencies: ["LanChatCore"]
        ),
        .testTarget(
            name: "LanChatCoreTests",
            dependencies: ["LanChatCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
