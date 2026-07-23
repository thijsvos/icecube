// swift-tools-version: 6.0
// Package.swift — ZephyrKit: all testable logic (models, codecs, mock provider); no UI, no root.
import PackageDescription

let package = Package(
    name: "ZephyrKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZephyrKit", targets: ["ZephyrKit"]),
    ],
    targets: [
        .target(name: "ZephyrKit"),
        .testTarget(name: "ZephyrKitTests", dependencies: ["ZephyrKit"]),
    ],
    swiftLanguageModes: [.v6]
)
