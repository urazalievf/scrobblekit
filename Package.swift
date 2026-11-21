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
        // A local MCP server over stdio: your ListenBrainz listening history
        // for Claude Desktop, Claude Code and other MCP clients.
        .executable(name: "scrobblekit-mcp", targets: ["scrobblekit-mcp"]),
    ],
    targets: [
        .target(name: "ScrobbleCore"),
        .target(name: "ScrobbleMCP", dependencies: ["ScrobbleCore"]),
        .executableTarget(name: "scrobblekit-mcp", dependencies: ["ScrobbleMCP"]),
        .testTarget(name: "ScrobbleCoreTests", dependencies: ["ScrobbleCore"]),
        .testTarget(name: "ScrobbleMCPTests", dependencies: ["ScrobbleMCP", "ScrobbleCore"]),
    ]
)
