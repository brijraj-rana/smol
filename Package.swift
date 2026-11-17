// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Smol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SmolCore", targets: ["SmolCore"]),
        .executable(name: "Smol", targets: ["Smol"]),
        .executable(name: "smol-cli", targets: ["smol-cli"]),
    ],
    targets: [
        // UI-free engine: formats, settings, decode, resize, encode, folder scanning.
        .target(name: "SmolCore", path: "Sources/SmolCore"),
        // The SwiftUI app.
        .executableTarget(name: "Smol", dependencies: ["SmolCore"], path: "Sources/Smol"),
        // Command-line front end to the same engine.
        .executableTarget(name: "smol-cli", dependencies: ["SmolCore"], path: "Sources/smol-cli"),
        .testTarget(name: "SmolCoreTests", dependencies: ["SmolCore"], path: "Tests/SmolCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
