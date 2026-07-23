// swift-tools-version: 6.0
// Package.swift — IceCubeKit: all testable logic (models, codecs, mock provider); no UI, no root.
import PackageDescription

let package = Package(
    name: "IceCubeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IceCubeKit", targets: ["IceCubeKit"]),
        // Dev/community CLI: prints the diagnostics report ("new Mac model"
        // issue attachments) without needing the app. Not shipped in Ice Cube.app.
        .executable(name: "icecube-diag", targets: ["IceCubeDiag"]),
    ],
    targets: [
        .target(name: "IceCubeKit"),
        .executableTarget(name: "IceCubeDiag", dependencies: ["IceCubeKit"]),
        .testTarget(name: "IceCubeKitTests", dependencies: ["IceCubeKit"]),
    ],
    swiftLanguageModes: [.v6]
)
