import Foundation
import ScrobbleMCP

/// MCP over stdio: one JSON-RPC message per line on stdin, replies on
/// stdout. Anything diagnostic goes to stderr, never stdout.
@main
struct ScrobbleKitMCP {
    @MainActor
    static func main() async {
        let server = MCPServer(configuration: .fromEnvironment())
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = await server.handle(line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }
}
