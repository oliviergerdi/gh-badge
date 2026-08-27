// swift-tools-version:5.9
import PackageDescription

// Deliberately dependency-free. SwiftPM is only the build driver here — the
// runnable .app bundle is assembled by ./build.sh, which needs nothing beyond
// the Xcode Command Line Tools.
let package = Package(
    name: "gh-badge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gh-badge", targets: ["GHBadgeApp"])
    ],
    targets: [
        // Everything testable lives here: no SwiftUI, no AppKit-only entry point.
        .target(
            name: "GHBadgeCore",
            path: "Sources/GHBadgeCore"
        ),
        // Views + @main. Not unit-tested (see docs/plans: no UI tests).
        .executableTarget(
            name: "GHBadgeApp",
            dependencies: ["GHBadgeCore"],
            path: "Sources/GHBadgeApp"
        ),
        .testTarget(
            name: "GHBadgeCoreTests",
            dependencies: ["GHBadgeCore"],
            path: "Tests/GHBadgeCoreTests"
        ),
    ]
)
