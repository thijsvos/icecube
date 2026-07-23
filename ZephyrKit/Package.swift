// swift-tools-version: 6.0
// Package.swift — ZephyrKit: all testable logic (models, codecs, mock provider); no UI, no root.
import PackageDescription

let package = Package(
    name: "ZephyrKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZephyrKit", targets: ["ZephyrKit"]),
        // Dev/community CLI: prints the diagnostics report ("new Mac model"
        // issue attachments) without needing the app. Not shipped in Zephyr.app.
        .executable(name: "zephyr-diag", targets: ["ZephyrDiag"]),
    ],
    targets: [
        .target(name: "ZephyrKit"),
        .executableTarget(name: "ZephyrDiag", dependencies: ["ZephyrKit"]),
        .testTarget(name: "ZephyrKitTests", dependencies: ["ZephyrKit"]),
    ],
    swiftLanguageModes: [.v6]
)
