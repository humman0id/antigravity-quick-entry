// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AntigravityQuickEntry",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "QuickEntryCore",
            targets: ["QuickEntryCore"]
        ),
        .executable(
            name: "AntigravityQuickEntry",
            targets: ["AntigravityQuickEntry"]
        )
    ],
    targets: [
        // Pure Swift logic (hotkey state machine, ACP JSON-RPC protocol, path manifest)
        .target(
            name: "QuickEntryCore",
            path: "Sources/QuickEntryCore"
        ),
        // Native macOS menu-bar app (AppKit, SwiftUI, CoreGraphics, ScreenCaptureKit)
        .executableTarget(
            name: "AntigravityQuickEntry",
            dependencies: ["QuickEntryCore"],
            path: "Sources/AntigravityQuickEntry"
        ),
        // Automated unit tests for QuickEntryCore
        .testTarget(
            name: "QuickEntryCoreTests",
            dependencies: ["QuickEntryCore"],
            path: "Tests/QuickEntryCoreTests"
        )
    ]
)
