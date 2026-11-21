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
                        "submission_client_version": "0.2.0",
                        "music_service": "music.apple.com",
                        "recording_mbid": "98255a8c-017a-4bc7-8dd6-1fa36124572b",
                        "duration_ms": 213_000,
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
                        "submission_client_version": "0.2.0",
                        "music_service": "music.apple.com",
                    ],
                ],
            ]],
        ] as NSDictionary)
    }

    func testPlayedTimeGoesInAdditionalInfoButNeverWithPlayingNow() async throws {
        var listen = scrobble("Song")
        listen.durationSec = 240
        listen.playedSec = 231
        let single = StubTransport(ok)
        try await ListenBrainzClient(transport: single).submit([listen], as: .single, token: "T")
        let info = (single.requests.first?.jsonBody?["payload"] as? [NSDictionary])?.first?
            .value(forKeyPath: "track_metadata.additional_info") as? NSDictionary
        XCTAssertEqual(info?["duration_ms"] as? Int, 240_000)
        XCTAssertEqual(info?["duration_played"] as? Int, 231)
        XCTAssertNil(info?["duration_played_ms"], "only one of the two keys")

        let nowPlaying = StubTransport(ok)
        try await ListenBrainzClient(transport: nowPlaying).submit([listen], as: .playingNow, token: "T")
        let nowInfo = (nowPlaying.requests.first?.jsonBody?["payload"] as? [NSDictionary])?.first?
            .value(forKeyPath: "track_metadata.additional_info") as? NSDictionary
        XCTAssertEqual(nowInfo?["duration_ms"] as? Int, 240_000)
        XCTAssertNil(nowInfo?["duration_played"])
    }

    func testOutOfRangeDurationsAreLeftOut() async throws {
        var listen = scrobble("Song")
        listen.durationSec = 0
        listen.playedSec = 30 * 24 * 60 * 60
        let transport = StubTransport(ok)
        try await ListenBrainzClient(transport: transport).submit([listen], as: .single, token: "T")
        let info = (transport.requests.first?.jsonBody?["payload"] as? [NSDictionary])?.first?
            .value(forKeyPath: "track_metadata.additional_info") as? NSDictionary
        XCTAssertNil(info?["duration_ms"])
        XCTAssertNil(info?["duration_played"])
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

    // MARK: Reading history

    private func listensBody(_ timestamps: [Int]) -> StubTransport.Response {
        let items = timestamps.map {
            ##"{"listened_at":\##($0),"track_metadata":{"artist_name":"A","track_name":"T\##($0)"}}"##
        }.joined(separator: ",")
        return .json(##"{"payload":{"count":\##(timestamps.count),"listens":[\##(items)]}}"##)
    }

    func testListensInARangePageBackwardsAndStopAtTheStart() async throws {
        let transport = StubTransport(listensBody([500, 400, 300]), listensBody([200, 100, 50]))
        let listens = try await ListenBrainzClient(transport: transport).listens(
            user: "me", from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 500), limit: 3
        )
        XCTAssertEqual(listens.map(\.track), ["T500", "T400", "T300"], "the limit stops it")

        let paged = StubTransport(listensBody([500, 400]), listensBody([300, 100]), listensBody([50]))
        let all = try await ListenBrainzClient(transport: paged).listens(
            user: "me", from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 500), limit: 2
        )
        XCTAssertEqual(all.count, 2)

        let ranged = StubTransport(listensBody([500, 400, 300]))
        let bounded = try await ListenBrainzClient(transport: ranged).listens(
            user: "me", from: Date(timeIntervalSince1970: 350), to: Date(timeIntervalSince1970: 500), limit: 10
        )
        XCTAssertEqual(bounded.map(\.track), ["T500", "T400"], "listens before the start are left out")
        XCTAssertEqual(ranged.requests.count, 1, "a short page is the last one")
    }

    func testListensRangeRequestsUseMaxTimestamp() async throws {
        let transport = StubTransport(listensBody([400, 300]), listensBody([]))
        _ = try await ListenBrainzClient(transport: transport).listens(
            user: "a b", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 500), limit: 2
        )
        XCTAssertEqual(transport.requests.first?.url?.absoluteString,
                       "https://api.listenbrainz.org/1/user/a%20b/listens?max_ts=501&count=2")
        XCTAssertEqual(transport.requests.count, 1, "a full page at the limit stops")
    }

    func testTopArtistsAndTracksParseStatistics() async throws {
        let artists = StubTransport(.json(#"{"payload":{"artists":[{"artist_name":"Low","listen_count":40},{"artist_name":"Björk","listen_count":31}],"range":"this_month"}}"#))
        let top = try await ListenBrainzClient(transport: artists).topArtists(user: "me", range: .thisMonth, count: 2)
        XCTAssertEqual(top, [ArtistCount(name: "Low", listens: 40), ArtistCount(name: "Björk", listens: 31)])
        XCTAssertEqual(artists.requests.first?.url?.absoluteString,
                       "https://api.listenbrainz.org/1/stats/user/me/artists?range=this_month&count=2")

        let tracks = StubTransport(.json(#"{"payload":{"recordings":[{"track_name":"Words","artist_name":"Low","listen_count":12}]}}"#))
        let topTracks = try await ListenBrainzClient(transport: tracks).topTracks(user: "me", range: .allTime)
        XCTAssertEqual(topTracks, [TrackCount(track: "Words", artist: "Low", listens: 12)])
    }

    func testStatisticsNotComputedYetAreEmpty() async throws {
        let transport = StubTransport(.init(status: 204, body: Data()))
        let top = try await ListenBrainzClient(transport: transport).topArtists(user: "me", range: .thisYear)
        XCTAssertEqual(top, [])
    }

    func testListenCount() async throws {
        let transport = StubTransport(.json(#"{"payload":{"count":12345}}"#))
        let count = try await ListenBrainzClient(transport: transport).listenCount(user: "me")
        XCTAssertEqual(count, 12345)
    }

    func testLoveSendsRecordingFeedbackWithScoreOne() async throws {
        let transport = StubTransport(ok)
        try await ListenBrainzClient(transport: transport).love(recordingMBID: "abc", token: "T")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.listenbrainz.org/1/feedback/recording-feedback")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token T")
        XCTAssertEqual(request.jsonBody, ["recording_mbid": "abc", "score": 1] as NSDictionary)
    }

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
