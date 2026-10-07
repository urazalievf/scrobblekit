import XCTest
@testable import ScrobbleCore

private typealias Recording = MusicBrainzFixtures.Recording

final class MusicBrainzClientTests: XCTestCase {
    private func client(_ transport: StubTransport, clock: FakeClock = FakeClock()) -> MusicBrainzClient {
        MusicBrainzClient(transport: transport, now: { clock.now() }, sleep: { try await clock.sleep($0) })
    }

    private func query(of request: URLRequest?) -> String? {
        guard let url = request?.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "query" }?.value
    }

    // MARK: Request

    func testRequestURLAndUserAgent() async throws {
        let transport = StubTransport(MusicBrainzFixtures.empty)
        _ = try await client(transport).searchRecording(
            artist: "Radiohead", track: "Reckoner", album: "In Rainbows (Deluxe Edition)", durationSec: 290
        )

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "ScrobbleKit/0.1.0 ( https://feruzurazaliev.com )")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://musicbrainz.org/ws/2/recording/?query="
                + "artist%3A%22Radiohead%22%20AND%20recording%3A%22Reckoner%22%20release%3A%22In%20Rainbows%22"
                + "&fmt=json&limit=25"
        )
    }

    func testQueryEscapesPhrasesAndOmitsReleaseWithoutAlbum() async throws {
        let transport = StubTransport(MusicBrainzFixtures.empty)
        _ = try await client(transport).searchRecording(
            artist: #"Say "Hi" \ Co"#, track: "A&B=C+D", album: nil, durationSec: nil
        )
        XCTAssertEqual(query(of: transport.requests.first), #"artist:"Say \"Hi\" \\ Co" AND recording:"A&B=C+D""#)
    }

    func testAlbumCleanupStripsAppleSuffixes() {
        XCTAssertEqual(MusicBrainzClient.cleanAlbum("In Rainbows (Deluxe Edition)"), "In Rainbows")
        XCTAssertEqual(MusicBrainzClient.cleanAlbum("Get Lucky - Single"), "Get Lucky")
        XCTAssertEqual(MusicBrainzClient.cleanAlbum("Kid A Mnesia - EP"), "Kid A Mnesia")
        XCTAssertEqual(MusicBrainzClient.cleanAlbum("Abbey Road (Remastered) [2019 Mix]"), "Abbey Road")
        XCTAssertEqual(MusicBrainzClient.cleanAlbum("(What's the Story) Morning Glory?"), "(What's the Story) Morning Glory?")
        XCTAssertEqual(MusicBrainzClient.cleanAlbum("(Untitled)"), "(Untitled)", "keeps a title that is only a parenthetical")
    }

    // MARK: Choosing a match

    // Modeled on the live results: the top hit is the instrumental, and the
    // album version is further down.
    func testPicksExactTitleWithinDurationTolerance() async throws {
        let candidates = MusicBrainzFixtures.search([
            Recording(id: "instrumental", title: "Never Gonna Give You Up (instrumental)", lengthMs: 379_000),
            Recording(id: "short-edit", title: "Never Gonna Give You Up", lengthMs: 91_000),
            Recording(id: "album", title: "Never Gonna Give You Up", lengthMs: 212_960),
        ])

        let withDuration = try await client(StubTransport(candidates)).searchRecording(
            artist: "Rick Astley", track: "Never Gonna Give You Up", album: nil, durationSec: 213
        )
        XCTAssertEqual(withDuration, MusicBrainzMatch(recordingMBID: "album", releaseMBID: nil))

        let withoutDuration = try await client(StubTransport(candidates)).searchRecording(
            artist: "Rick Astley", track: "Never Gonna Give You Up", album: nil, durationSec: nil
        )
        XCTAssertEqual(withoutDuration?.recordingMBID, "short-edit", "first exact title when duration is unknown")
    }

    func testPrefersRecordingOnMatchingAlbum() async throws {
        let candidates = MusicBrainzFixtures.search([
            Recording(id: "live", title: "Reckoner", credits: [("Radiohead", "")], lengthMs: 290_000,
                      releases: [("praha", "Live in Praha")]),
            Recording(id: "studio", title: "Reckoner", credits: [("Radiohead", "")], lengthMs: 290_213,
                      releases: [("boot", "Some Bootleg"), ("in-rainbows", "In Rainbows")]),
        ])

        let onAlbum = try await client(StubTransport(candidates)).searchRecording(
            artist: "Radiohead", track: "Reckoner", album: "In Rainbows (Deluxe Edition)", durationSec: 290
        )
        XCTAssertEqual(onAlbum, MusicBrainzMatch(recordingMBID: "studio", releaseMBID: "in-rainbows"))

        let noAlbum = try await client(StubTransport(candidates)).searchRecording(
            artist: "Radiohead", track: "Reckoner", album: nil, durationSec: 290
        )
        XCTAssertEqual(noAlbum, MusicBrainzMatch(recordingMBID: "live", releaseMBID: nil))
    }

    func testReturnsNilWhenNoCandidateMatchesExactly() async throws {
        let candidates = MusicBrainzFixtures.search([
            Recording(id: "instrumental", title: "Never Gonna Give You Up (instrumental)", lengthMs: 213_000),
            Recording(id: "cover", title: "Never Gonna Give You Up", credits: [("Some Cover Band", "")], lengthMs: 213_000),
            Recording(id: "too-long", title: "Never Gonna Give You Up", lengthMs: 441_000),
        ])
        let match = try await client(StubTransport(candidates)).searchRecording(
            artist: "Rick Astley", track: "Never Gonna Give You Up", album: nil, durationSec: 213
        )
        XCTAssertNil(match)
    }

    func testEmptyResultsReturnNil() async throws {
        let match = try await client(StubTransport(MusicBrainzFixtures.empty)).searchRecording(
            artist: "Nobody", track: "Nothing", album: nil, durationSec: nil
        )
        XCTAssertNil(match)
    }

    func testFeaturedArtistsInAppleTitleStillMatch() async throws {
        let transport = StubTransport(MusicBrainzFixtures.search([
            Recording(id: "get-lucky", title: "Get Lucky",
                      credits: [("Daft Punk", " feat. "), ("Pharrell Williams", " & "), ("Nile Rodgers", "")],
                      lengthMs: 369_000),
        ]))
        let match = try await client(transport).searchRecording(
            artist: "Daft Punk", track: "Get Lucky (feat. Pharrell Williams & Nile Rodgers)",
            album: "Random Access Memories", durationSec: 369
        )
        XCTAssertEqual(match?.recordingMBID, "get-lucky")
        XCTAssertEqual(
            query(of: transport.requests.first),
            #"artist:"Daft Punk" AND recording:"Get Lucky" release:"Random Access Memories""#
        )
    }

    // MusicBrainz uses typographic apostrophes; Apple often doesn't.
    func testComparisonIgnoresCaseDiacriticsAndTypographicPunctuation() async throws {
        let transport = StubTransport(MusicBrainzFixtures.search([
            Recording(id: "queen", title: "Don’t Stop Me Now", credits: [("Queen", "")], lengthMs: 209_000),
        ]))
        let match = try await client(transport).searchRecording(
            artist: "QUEEN", track: "Don't stop me now", album: nil, durationSec: 210
        )
        XCTAssertEqual(match?.recordingMBID, "queen")

        let accents = StubTransport(MusicBrainzFixtures.search([
            Recording(id: "sigur", title: "Hoppípolla", credits: [("Sigur Rós", "")], lengthMs: 268_000),
        ]))
        let accentMatch = try await client(accents).searchRecording(
            artist: "Sigur Ros", track: "Hoppipolla", album: nil, durationSec: nil
        )
        XCTAssertEqual(accentMatch?.recordingMBID, "sigur")
    }

    // MARK: Errors

    func testHTTPErrorAndMalformedBody() async {
        for (response, expected) in [
            (StubTransport.Response(status: 503, body: Data()), MusicBrainzError.httpStatus(503)),
            (.json(#"{"unexpected":true}"#), .unexpectedResponse),
        ] {
            do {
                _ = try await client(StubTransport(response)).searchRecording(
                    artist: "A", track: "B", album: nil, durationSec: nil
                )
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? MusicBrainzError, expected)
            }
        }
    }

    // MARK: Rate limit

    func testSequentialRequestsStartAtLeastOneSecondApart() async throws {
        let clock = FakeClock()
        let transport = StubTransport(MusicBrainzFixtures.empty, MusicBrainzFixtures.empty, MusicBrainzFixtures.empty)
        let client = client(transport, clock: clock)

        _ = try await client.searchRecording(artist: "A", track: "1", album: nil, durationSec: nil)
        clock.advance(by: 0.3)
        _ = try await client.searchRecording(artist: "A", track: "2", album: nil, durationSec: nil)
        clock.advance(by: 5)
        _ = try await client.searchRecording(artist: "A", track: "3", album: nil, durationSec: nil)

        XCTAssertEqual(clock.sleeps.count, 1, "only the second request had to wait")
        XCTAssertEqual(clock.sleeps.first ?? 0, 0.7, accuracy: 0.0001)
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testConcurrentRequestsAreQueuedOneSecondApart() async throws {
        let clock = FakeClock(advancesOnSleep: false)
        let transport = StubTransport(MusicBrainzFixtures.empty, MusicBrainzFixtures.empty, MusicBrainzFixtures.empty)
        let client = client(transport, clock: clock)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for track in ["1", "2", "3"] {
                group.addTask { _ = try await client.searchRecording(artist: "A", track: track, album: nil, durationSec: nil) }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(clock.sleeps.sorted(), [1, 2], "slots at +0s, +1s and +2s")
        XCTAssertEqual(transport.requests.count, 3)
    }
}
