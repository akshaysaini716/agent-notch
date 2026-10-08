// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentNotch", targets: ["AgentNotch"]),
    ],
    targets: [
        // Pure logic: hook payloads, session state, HTTP parsing. No AppKit, fully tested.
        .target(name: "AgentNotchCore"),
        // The notch app itself (AppKit panel + SwiftUI views + local hook server).
        .executableTarget(
            name: "AgentNotch",
            dependencies: ["AgentNotchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Reads Warp's tab names from its state database.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "AgentNotchCoreTests", dependencies: ["AgentNotchCore"]),
    ]
)
