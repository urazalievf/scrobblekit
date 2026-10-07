import XCTest
@testable import ScrobbleCore

final class ListenBrainzClientTests: XCTestCase {
    private let ok = StubTransport.Response.json(#"{"status":"ok"}"#)

    private func scrobble(_ track: String, at seconds: TimeInterval = 1_700_000_000) -> Scrobble {
        Scrobble(artist: "Artist", track: track, listenedAt: Date(timeIntervalSince1970: seconds))
    }

    private func assertThrows(
        _ expected: ListenBrainzError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected), nothing thrown", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ListenBrainzError, expected, file: file, line: line)
        }
    }

    // MARK: submit-listens

    func testSingleListenRequest() async throws {
        let transport = StubTransport(ok)
        let listen = Scrobble(
            artist: "Rick Astley", track: "Never Gonna Give You Up", album: "Whenever You Need Somebody",
            durationSec: 213, listenedAt: Date(timeIntervalSince1970: 1_443_521_965.7),
            recordingMBID: "98255a8c-017a-4bc7-8dd6-1fa36124572b"
        )
        try await ListenBrainzClient(transport: transport).submit([listen], as: .single, token: "TOKEN")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.listenbrainz.org/1/submit-listens")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token TOKEN")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.jsonBody, [
            "listen_type": "single",
            "payload": [[
                "listened_at": 1_443_521_965, // whole Unix seconds, truncated
                "track_metadata": [
                    "artist_name": "Rick Astley",
                    "track_name": "Never Gonna Give You Up",
                    "release_name": "Whenever You Need Somebody",
                    "additional_info": [
                        "submission_client": "ScrobbleKit",
                        "submission_client_version": "0.1.0",
                        "music_service": "music.apple.com",
                        "recording_mbid": "98255a8c-017a-4bc7-8dd6-1fa36124572b",
                    ],
                ],
            ]],
        ] as NSDictionary)
    }

    func testPlayingNowOmitsListenedAtAndMissingFields() async throws {
        let transport = StubTransport(ok)
        var listen = scrobble("Song")
        listen.album = ""
        try await ListenBrainzClient(transport: transport).submit([listen], as: .playingNow, token: "TOKEN")

        XCTAssertEqual(try XCTUnwrap(transport.requests.first).jsonBody, [
            "listen_type": "playing_now",
            "payload": [[
                "track_metadata": [
                    "artist_name": "Artist",
                    "track_name": "Song",
                    "additional_info": [
                        "submission_client": "ScrobbleKit",
                        "submission_client_version": "0.1.0",
                        "music_service": "music.apple.com",
                    ],
                ],
            ]],
        ] as NSDictionary)
    }

    func testImportSendsEveryListenInOrder() async throws {
        let transport = StubTransport(ok)
        let listens = [scrobble("A", at: 100), scrobble("B", at: 200), scrobble("C", at: 300)]
        try await ListenBrainzClient(transport: transport).submit(listens, as: .import, token: "TOKEN")

        let body = try XCTUnwrap(transport.requests.first?.jsonBody)
        XCTAssertEqual(body["listen_type"] as? String, "import")
        let payload = try XCTUnwrap(body["payload"] as? [NSDictionary])
        XCTAssertEqual(payload.map { $0["listened_at"] as? Int }, [100, 200, 300])
        XCTAssertEqual(payload.map { ($0["track_metadata"] as? NSDictionary)?["track_name"] as? String }, ["A", "B", "C"])
    }

    func testListenCountLimitsAreEnforcedBeforeSending() async {
        let transport = StubTransport()
        let client = ListenBrainzClient(transport: transport)
        let two = [scrobble("A"), scrobble("B")]
        let tooMany = (0..<1001).map { scrobble("T\($0)", at: Double($0)) }

        await assertThrows(.invalidListenCount(.single, 0)) { try await client.submit([], as: .single, token: "T") }
        await assertThrows(.invalidListenCount(.single, 2)) { try await client.submit(two, as: .single, token: "T") }
        await assertThrows(.invalidListenCount(.playingNow, 2)) { try await client.submit(two, as: .playingNow, token: "T") }
        await assertThrows(.invalidListenCount(.import, 0)) { try await client.submit([], as: .import, token: "T") }
        await assertThrows(.invalidListenCount(.import, 1001)) { try await client.submit(tooMany, as: .import, token: "T") }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testImportAcceptsOneThousandListens() async throws {
        let transport = StubTransport(ok)
        let thousand = (0..<1000).map { scrobble("T\($0)", at: Double($0)) }
        try await ListenBrainzClient(transport: transport).submit(thousand, as: .import, token: "T")
        XCTAssertEqual((transport.requests.first?.jsonBody?["payload"] as? [Any])?.count, 1000)
    }

    func testSuccessStatusWithoutOKBodyIsUnexpectedResponse() async {
        let transport = StubTransport(.json(#"{"status":"something else"}"#))
        await assertThrows(.unexpectedResponse) {
            try await ListenBrainzClient(transport: transport).submit([self.scrobble("A")], as: .single, token: "T")
        }
    }

    // MARK: Errors

    func testErrorStatusesMapToTypedErrors() async {
        let cases: [(StubTransport.Response, ListenBrainzError)] = [
            (.json(#"{"code":400,"error":"JSON document is invalid."}"#, status: 400),
             .badRequest(message: "JSON document is invalid.")),
            (.json(#"{"code":401,"error":"Invalid authorization token."}"#, status: 401), .invalidToken),
            (.init(status: 503, body: Data("<html>down</html>".utf8)), .httpStatus(503)),
        ]
        for (response, expected) in cases {
            let transport = StubTransport(response)
            await assertThrows(expected) {
                try await ListenBrainzClient(transport: transport).submit([self.scrobble("A")], as: .single, token: "T")
            }
        }
    }

    func testRateLimitedHonorsRetryAfterSeconds() async {
        let transport = StubTransport(.json(#"{"code":429}"#, status: 429, headers: ["Retry-After": "17"]))
        await assertThrows(.rateLimited(retryAfter: 17)) {
            try await ListenBrainzClient(transport: transport).submit([self.scrobble("A")], as: .single, token: "T")
        }
    }

    // ListenBrainz documents X-RateLimit-Reset-In rather than Retry-After.
    func testRateLimitedFallsBackToResetIn() async {
        let transport = StubTransport(.json(#"{"code":429}"#, status: 429, headers: ["X-RateLimit-Reset-In": "9"]))
        await assertThrows(.rateLimited(retryAfter: 9)) {
            try await ListenBrainzClient(transport: transport).submit([self.scrobble("A")], as: .single, token: "T")
        }
    }

    func testRateLimitedWithoutHeadersHasNoDelay() async {
        let transport = StubTransport(.json(#"{"code":429}"#, status: 429))
        await assertThrows(.rateLimited(retryAfter: nil)) {
            try await ListenBrainzClient(transport: transport).submit([self.scrobble("A")], as: .single, token: "T")
        }
    }

    func testRetryDelayPrefersRetryAfterAndParsesHTTPDates() throws {
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.org")!, statusCode: 429, httpVersion: nil, headerFields: headers)!
        }
        let now = Date(timeIntervalSince1970: 1_445_412_480 - 120) // two minutes before the date below

        XCTAssertEqual(ListenBrainzClient.retryDelay(
            from: response(["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]), now: now
        ), 120)
        XCTAssertEqual(ListenBrainzClient.retryDelay(
            from: response(["Retry-After": "5", "X-RateLimit-Reset-In": "60"]), now: now
        ), 5)
        XCTAssertEqual(ListenBrainzClient.retryDelay(
            from: response(["Retry-After": "Wed, 21 Oct 2015 07:00:00 GMT"]), now: now
        ), 0, "a date in the past means retry now")
        XCTAssertNil(ListenBrainzClient.retryDelay(from: response(["Retry-After": "soon"]), now: now))
    }

    // MARK: validate-token

    func testValidTokenReturnsUserName() async throws {
        let transport = StubTransport(.json(
            #"{"code":200,"message":"Token valid.","valid":true,"user_name":"urazaliev"}"#
        ))
        let userName = try await ListenBrainzClient(transport: transport).validateToken("TOKEN")

        XCTAssertEqual(userName, "urazaliev")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.listenbrainz.org/1/validate-token")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token TOKEN")
    }

    func testInvalidTokenReturnsNil() async throws {
        // Documented: HTTP 200 with "valid": false.
        let documented = StubTransport(.json(#"{"code":200,"message":"Token invalid.","valid":false}"#))
        let documentedResult = try await ListenBrainzClient(transport: documented).validateToken("BAD")
        XCTAssertNil(documentedResult)

        // Also treated as invalid: a plain 401.
        let unauthorized = StubTransport(.json(#"{"code":401,"error":"Invalid authorization token."}"#, status: 401))
        let unauthorizedResult = try await ListenBrainzClient(transport: unauthorized).validateToken("BAD")
        XCTAssertNil(unauthorizedResult)
    }
}
