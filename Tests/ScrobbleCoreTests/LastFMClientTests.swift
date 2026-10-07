import XCTest
@testable import ScrobbleCore

final class LastFMClientTests: XCTestCase {
    private func client(_ transport: StubTransport) -> LastFMClient {
        LastFMClient(apiKey: "testapikey", sharedSecret: "testsecret", transport: transport)
    }

    private func scrobble(_ track: String, at seconds: TimeInterval) -> Scrobble {
        Scrobble(artist: "Artist", track: track, listenedAt: Date(timeIntervalSince1970: seconds))
    }

    private func assertThrows(
        _ expected: LastFMError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected), nothing thrown", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LastFMError, expected, file: file, line: line)
        }
    }

    // MARK: Request shape

    func testRequestIsSignedFormPostWithJSONFormat() async throws {
        let transport = StubTransport(.json(#"{"session":{"name":"feruz","key":"SK","subscriber":0}}"#))
        _ = try await client(transport).getSession(token: "testtoken")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://ws.audioscrobbler.com/2.0/")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(request.formParameters, [
            "method": "auth.getSession",
            "api_key": "testapikey",
            "token": "testtoken",
            "format": "json",
            // Same parameters and secret as SignatureTests.testAuthGetSessionSignature.
            "api_sig": "dff91a0c1be9825346653bee9ea590cb",
        ])
    }

    func testReservedCharactersAndUnicodeSurviveFormEncoding() async throws {
        let transport = StubTransport(.json(#"{"nowplaying":{}}"#))
        let track = Scrobble(artist: "AC/DC & Friends", track: "1+1=2 ?", album: "Sigur Rós", listenedAt: .now)
        try await client(transport).updateNowPlaying(track, sessionKey: "SK")

        let parameters = try XCTUnwrap(transport.requests.first).formParameters
        XCTAssertEqual(parameters["artist"], "AC/DC & Friends")
        XCTAssertEqual(parameters["track"], "1+1=2 ?")
        XCTAssertEqual(parameters["album"], "Sigur Rós")
    }

    // MARK: auth.getSession

    func testGetSessionParsesNameAndKey() async throws {
        let transport = StubTransport(.json(#"{"session":{"name":"feruz","key":"SK123","subscriber":0}}"#))
        let session = try await client(transport).getSession(token: "testtoken")
        XCTAssertEqual(session, LastFMSession(username: "feruz", key: "SK123"))
    }

    // MARK: track.updateNowPlaying

    func testUpdateNowPlayingSendsMetadataAndOmitsMissingFields() async throws {
        let transport = StubTransport(.json(#"{"nowplaying":{}}"#))
        let track = Scrobble(
            artist: "Björk", track: "Jóga", album: "Homogenic", albumArtist: nil,
            durationSec: 305, listenedAt: .now, recordingMBID: nil
        )
        try await client(transport).updateNowPlaying(track, sessionKey: "SK")

        var parameters = try XCTUnwrap(transport.requests.first).formParameters
        XCTAssertNotNil(parameters.removeValue(forKey: "api_sig"))
        XCTAssertEqual(parameters, [
            "method": "track.updateNowPlaying",
            "api_key": "testapikey",
            "sk": "SK",
            "format": "json",
            "artist": "Björk",
            "track": "Jóga",
            "album": "Homogenic",
            "duration": "305",
        ])
    }

    // MARK: track.scrobble

    func testScrobbleBatchUsesIndexedParametersAndUnixSeconds() async throws {
        let transport = StubTransport(.json("""
        {"scrobbles":{"@attr":{"accepted":2,"ignored":0},"scrobble":[
          {"ignoredMessage":{"code":"0","#text":""}},
          {"ignoredMessage":{"code":"0","#text":""}}]}}
        """))
        let batch = [
            Scrobble(
                artist: "Radiohead", track: "Reckoner", album: "In Rainbows", albumArtist: "Radiohead",
                durationSec: 290, listenedAt: Date(timeIntervalSince1970: 1_700_000_000.9),
                recordingMBID: "8f5e1d4c-0000-4000-8000-000000000000"
            ),
            scrobble("Second", at: 1_700_000_300),
        ]
        _ = try await client(transport).scrobble(batch, sessionKey: "SK")

        let parameters = try XCTUnwrap(transport.requests.first).formParameters
        XCTAssertEqual(parameters["method"], "track.scrobble")
        XCTAssertEqual(parameters["sk"], "SK")
        XCTAssertEqual(parameters["artist[0]"], "Radiohead")
        XCTAssertEqual(parameters["track[0]"], "Reckoner")
        XCTAssertEqual(parameters["album[0]"], "In Rainbows")
        XCTAssertEqual(parameters["albumArtist[0]"], "Radiohead")
        XCTAssertEqual(parameters["duration[0]"], "290")
        XCTAssertEqual(parameters["mbid[0]"], "8f5e1d4c-0000-4000-8000-000000000000")
        XCTAssertEqual(parameters["timestamp[0]"], "1700000000", "whole Unix seconds, truncated")
        XCTAssertEqual(parameters["track[1]"], "Second")
        XCTAssertEqual(parameters["timestamp[1]"], "1700000300")
        XCTAssertNil(parameters["album[1]"])
        XCTAssertNil(parameters["mbid[1]"])
    }

    func testScrobbleParsesAcceptedIgnoredAndPerItemCodes() async throws {
        let transport = StubTransport(.json("""
        {"scrobbles":{"@attr":{"accepted":1,"ignored":1},"scrobble":[
          {"ignoredMessage":{"code":"0","#text":""}},
          {"ignoredMessage":{"code":"3","#text":"Timestamp too old"}}]}}
        """))
        let result = try await client(transport).scrobble(
            [scrobble("A", at: 1_700_000_000), scrobble("B", at: 1_000)], sessionKey: "SK"
        )
        XCTAssertEqual(result, LastFMScrobbleResult(accepted: 1, ignored: 1, ignoredCodes: [0, 3]))
    }

    // Last.fm returns a bare object instead of a one-element array, and
    // sometimes sends the counts as strings.
    func testScrobbleParsesSingleItemObjectAndStringCounts() async throws {
        let transport = StubTransport(.json("""
        {"scrobbles":{"@attr":{"accepted":"1","ignored":"0"},
          "scrobble":{"ignoredMessage":{"code":"0","#text":""}}}}
        """))
        let result = try await client(transport).scrobble([scrobble("A", at: 1_700_000_000)], sessionKey: "SK")
        XCTAssertEqual(result, LastFMScrobbleResult(accepted: 1, ignored: 0, ignoredCodes: [0]))
    }

    func testScrobbleRejectsEmptyAndOversizedBatchesWithoutSending() async {
        let transport = StubTransport()
        let fiftyOne = (0..<51).map { scrobble("T\($0)", at: 1_700_000_000 + Double($0)) }

        await assertThrows(.invalidBatchSize(0)) {
            _ = try await self.client(transport).scrobble([], sessionKey: "SK")
        }
        await assertThrows(.invalidBatchSize(51)) {
            _ = try await self.client(transport).scrobble(fiftyOne, sessionKey: "SK")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testScrobbleAcceptsFiftyItemBatch() async throws {
        let codes = Array(repeating: ##"{"ignoredMessage":{"code":"0","#text":""}}"##, count: 50)
        let transport = StubTransport(.json("""
        {"scrobbles":{"@attr":{"accepted":50,"ignored":0},"scrobble":[\(codes.joined(separator: ","))]}}
        """))
        let fifty = (0..<50).map { scrobble("T\($0)", at: 1_700_000_000 + Double($0)) }
        let result = try await client(transport).scrobble(fifty, sessionKey: "SK")
        XCTAssertEqual(result.accepted, 50)
        XCTAssertEqual(try XCTUnwrap(transport.requests.first).formParameters["track[49]"], "T49")
    }

    // MARK: Errors

    func testErrorCodesMapToTypedErrors() async {
        let cases: [(code: Int, status: Int, expected: LastFMError)] = [
            (9, 403, .invalidSession),
            (11, 503, .serviceOffline),
            (16, 500, .temporaryError),
            (29, 429, .rateLimitExceeded),
            (26, 403, .apiKeySuspended),
            (13, 403, .api(code: 13, message: "Invalid method signature supplied")),
            (9, 200, .invalidSession), // error body on HTTP 200 still counts
        ]
        for (code, status, expected) in cases {
            let message = code == 13 ? "Invalid method signature supplied" : "message"
            let transport = StubTransport(.json(#"{"error":\#(code),"message":"\#(message)"}"#, status: status))
            await assertThrows(expected) {
                try await self.client(transport).updateNowPlaying(self.scrobble("A", at: 0), sessionKey: "SK")
            }
        }
    }

    func testNonJSONErrorResponseMapsToHTTPStatus() async {
        let transport = StubTransport(.init(status: 502, body: Data("<html>Bad Gateway</html>".utf8)))
        await assertThrows(.httpStatus(502)) {
            _ = try await self.client(transport).getSession(token: "t")
        }
    }

    func testUnparseableSuccessBodyIsUnexpectedResponse() async {
        let transport = StubTransport(.json(#"{"something":"else"}"#))
        await assertThrows(.unexpectedResponse) {
            _ = try await self.client(transport).getSession(token: "t")
        }
    }
}
