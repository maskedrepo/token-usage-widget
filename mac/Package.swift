// swift-tools-version:5.9
// The notch app. Build the .app with ./build-app.sh; `swift run TokenNotch --print` prints the numbers.
import PackageDescription

let package = Package(
    name: "TokenNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TokenNotch", path: "Sources/TokenNotch"),
        // `swift test`: the readers against made-up Claude Code and Codex folders, and the dashboard's script.
        .testTarget(name: "TokenNotchTests", dependencies: ["TokenNotch"], path: "Tests/TokenNotchTests"),
    ]
)
