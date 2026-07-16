// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "nfc_hub",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_13)
    ],
    products: [
        .library(name: "nfc_hub", targets: ["nfc_hub"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "nfc_hub",
            dependencies: [],
            resources: [
            ]
        )
    ]
)
