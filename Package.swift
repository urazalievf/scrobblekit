// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ScrobbleKit",
    platforms: [
        // SwiftData needs macOS 14 / iOS 17.
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ScrobbleCore", targets: ["ScrobbleCore"]),
    ],
    targets: [
        .target(name: "ScrobbleCore"),
        .testTarget(name: "ScrobbleCoreTests", dependencies: ["ScrobbleCore"]),
    ]
)
