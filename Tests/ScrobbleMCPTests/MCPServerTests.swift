import Foundation
import XCTest
@testable import ScrobbleCore
@testable import ScrobbleMCP

/// Answers each request with the next queued response.
private final class Stub: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [(Int, String)]
    private(set) var urls: [String] = []

    init(_ responses: (Int, String)...) { queued = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: (Int, String)? = lock.withLock {
            urls.append(request.url!.absoluteString)
            return queued.isEmpty ? nil : queued.removeFirst()
        }
        guard let next else { throw URLError(.resourceUnavailable) }
        return (Data(next.1.utf8), HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class MCPServerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func server(user: String? = "me", _ stub: Stub = Stub()) -> MCPServer {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let fixed = now
        return MCPServer(configuration: .init(listenbrainzUser: user, transport: stub, calendar: calendar, now: { fixed }))
    }

    private func call(_ server: MCPServer, _ message: String) async throws -> [String: Any] {
        let line = await server.handle(message)
        let reply = try XCTUnwrap(line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func text(_ reply: [String: Any]) -> String? {
        ((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    func testInitializeNegotiatesTheVersionAndOffersTools() async throws {
        let reply = try await call(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String, ScrobbleCore.version)

        let unknown = try await call(server(), #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual((unknown["result"] as? [String: Any])?["protocolVersion"] as? String,
                       MCPServer.supportedProtocolVersions[0])
    }

    func testNotificationsGetNoReply() async {
        let reply = await server().handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(reply)
    }

    func testToolsAreAllReadOnly() async throws {
        let reply = try await call(server(), #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["recent_listens", "listening_summary", "top_artists", "top_tracks", "listen_count"])
        for tool in tools {
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
            XCTAssertNotNil(tool["title"])
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }
    }

    func testTopArtistsReadsStatistics() async throws {
        let stub = Stub((200, #"{"payload":{"artists":[{"artist_name":"Low","listen_count":40},{"artist_name":"Can","listen_count":3}]}}"#))
        let reply = try await call(server(stub), #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"top_artists","arguments":{"range":"this_month","count":2}}}"#)
        XCTAssertEqual(text(reply), "Your top artists this month: Low (40 plays) and Can (3).")
        XCTAssertEqual(stub.urls, ["https://api.listenbrainz.org/1/stats/user/me/artists?range=this_month&count=2"])
    }

    func testRecentListensListsThemInLocalTime() async throws {
        let stub = Stub((200, #"{"payload":{"count":1,"listens":[{"listened_at":1799996400,"track_metadata":{"artist_name":"Low","track_name":"Words","release_name":"I Could Live in Hope"}}]}}"#))
        let reply = try await call(server(stub), #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"recent_listens","arguments":{}}}"#)
        XCTAssertEqual(text(reply), "1 listens, newest first:\n2027-01-15 01:00 — Words — Low (I Could Live in Hope)")
    }

    func testDaySummaryCountsThatDay() async throws {
        let stub = Stub((200, #"{"payload":{"count":2,"listens":[{"listened_at":1799996400,"track_metadata":{"artist_name":"Low","track_name":"Words"}},{"listened_at":1799993000,"track_metadata":{"artist_name":"Low","track_name":"Words"}}]}}"#))
        let reply = try await call(server(stub), #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"listening_summary","arguments":{"day":"2027-01-15"}}}"#)
        let summary = try XCTUnwrap(text(reply))
        XCTAssertTrue(summary.hasPrefix("On Friday, January 15, 2027 you played 2 tracks. Most played: Low (2)."), summary)
        XCTAssertTrue(stub.urls.first?.contains("max_ts=") ?? false)
    }

    func testBadArgumentsAndMissingAccountAreToolErrors() async throws {
        let noUser = try await call(server(user: nil), #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"listen_count"}}"#)
        XCTAssertEqual((noUser["result"] as? [String: Any])?["isError"] as? Bool, true)

        let badRange = try await call(server(), #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"top_tracks","arguments":{"range":"forever"}}}"#)
        XCTAssertEqual((badRange["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testProtocolErrors() async throws {
        let unknownTool = try await call(server(), #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"delete_everything"}}"#)
        XCTAssertEqual((unknownTool["error"] as? [String: Any])?["code"] as? Int, -32602)
        let unknownMethod = try await call(server(), #"{"jsonrpc":"2.0","id":10,"method":"resources/list"}"#)
        XCTAssertEqual((unknownMethod["error"] as? [String: Any])?["code"] as? Int, -32601)
        let garbage = try await call(server(), "not json")
        XCTAssertEqual((garbage["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testConfigurationFromEnvironmentOrArguments() {
        XCTAssertEqual(MCPServer.Configuration.fromEnvironment(["LISTENBRAINZ_USER": "rob"], arguments: []).listenbrainzUser, "rob")
        XCTAssertEqual(MCPServer.Configuration.fromEnvironment([:], arguments: ["x", "--user", "ann"]).listenbrainzUser, "ann")
        XCTAssertNil(MCPServer.Configuration.fromEnvironment(["LISTENBRAINZ_USER": ""], arguments: []).listenbrainzUser)
    }
}
