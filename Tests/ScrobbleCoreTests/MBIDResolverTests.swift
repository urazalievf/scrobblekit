import SwiftData
import XCTest
@testable import ScrobbleCore

final class MBIDResolverTests: XCTestCase {
    private var container: ModelContainer!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 24 * 60 * 60
    private let reckonerMatch = MusicBrainzMatch(
        recordingMBID: "d9b46ecb-5472-4dcd-8fa4-dd6723189e27",
        releaseMBID: "f6efda86-0000-4000-8000-000000000000"
    )

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: MBIDCache.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func resolver(_ transport: StubTransport) -> MBIDResolver {
        let client = MusicBrainzClient(transport: transport, now: { Date(timeIntervalSince1970: 0) }, sleep: { _ in })
        return MBIDResolver(modelContainer: container, client: client)
    }

    private func resolveReckoner(_ resolver: MBIDResolver, artist: String = "Radiohead", at date: Date) async throws -> MBIDLookup {
        try await resolver.resolve(artist: artist, track: "Reckoner", album: "In Rainbows", durationSec: 290, now: date)
    }

    private func rowCount() throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<MBIDCache>())
    }

    // Expected values from `shasum -a 256`.
    func testKeyIsSHA256OfLowercasedArtistTrackAlbum() {
        XCTAssertEqual(
            MBIDCache.key(artist: "Radiohead", track: "Reckoner", album: "In Rainbows"),
            "2a5901200109c1d5a59ba1f93a9dce0eabea96420d1317d1e39b7114828780a6"
        )
        XCTAssertEqual(
            MBIDCache.key(artist: "Radiohead", track: "Reckoner", album: nil),
            "f53754f6810961fedd4ad1818cc1a520b07510e5fff45ac9194ddeae52564f41"
        )
    }

    func testHitIsQueriedOnceThenCachedForever() async throws {
        let transport = StubTransport(MusicBrainzFixtures.reckoner)
        let resolver = resolver(transport)

        let first = try await resolveReckoner(resolver, at: start)
        XCTAssertEqual(first, .queried(reckonerMatch))

        let tenYearsLater = try await resolveReckoner(resolver, at: start + 3650 * day)
        XCTAssertEqual(tenYearsLater, .cachedHit(reckonerMatch))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testMissIsCachedForSevenDaysThenRetried() async throws {
        let transport = StubTransport(MusicBrainzFixtures.empty, MusicBrainzFixtures.reckoner)
        let resolver = resolver(transport)

        let first = try await resolveReckoner(resolver, at: start)
        XCTAssertEqual(first, .queried(nil))

        let sixDaysLater = try await resolveReckoner(resolver, at: start + 6 * day)
        XCTAssertEqual(sixDaysLater, .cachedMiss)
        XCTAssertEqual(transport.requests.count, 1)

        let afterExpiry = try await resolveReckoner(resolver, at: start + 7 * day + 1)
        XCTAssertEqual(afterExpiry, .queried(reckonerMatch))
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(try rowCount(), 1, "the expired miss is updated, not duplicated")
    }

    func testLookupIgnoresCase() async throws {
        let transport = StubTransport(MusicBrainzFixtures.reckoner)
        let resolver = resolver(transport)

        _ = try await resolveReckoner(resolver, artist: "Radiohead", at: start)
        let shouting = try await resolveReckoner(resolver, artist: "RADIOHEAD", at: start)
        XCTAssertEqual(shouting, .cachedHit(reckonerMatch))
    }

    func testFailedQueryIsNotCached() async throws {
        let transport = StubTransport(.init(status: 503, body: Data()), MusicBrainzFixtures.reckoner)
        let resolver = resolver(transport)

        do {
            _ = try await resolveReckoner(resolver, at: start)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MusicBrainzError, .httpStatus(503))
        }
        XCTAssertEqual(try rowCount(), 0)

        let retry = try await resolveReckoner(resolver, at: start)
        XCTAssertEqual(retry, .queried(reckonerMatch))
    }
}
