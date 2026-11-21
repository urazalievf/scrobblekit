import SwiftData
import XCTest
@testable import ScrobbleCore

@MainActor
final class RecentPlaysSyncTests: XCTestCase {
    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: ScrobbleRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        defaults = UserDefaults(suiteName: "RecentPlaysSyncTests-\(UUID())")
    }

    private final class Feed: @unchecked Sendable {
        var tracks: [String] = []
        func page() -> Data {
            let items = tracks.map {
                #"{"id":"\#($0)","type":"songs","attributes":{"name":"\#($0)","artistName":"Low","durationInMillis":200000}}"#
            }.joined(separator: ",")
            return Data(#"{"data":[\#(items)]}"#.utf8)
        }
    }

    private func makeQueue() -> ScrobbleQueue {
        ScrobbleQueue(context: container.mainContext, lastfm: nil, listenbrainz: ListenBrainzClient(transport: StubTransport()),
                      resolver: nil, credentials: { Credentials(lastfmSessionKey: nil, listenbrainzToken: nil) },
                      defaults: defaults)
    }

    func testStoresNewPlaysButNotOnesThisMacAlreadyCaughtLive() async throws {
        let feed = Feed()
        feed.tracks = ["Old"]
        let queue = makeQueue()
        let poller = RecentPlaysPoller(pages: 1, defaults: defaults, fetchPage: { _ in feed.page() }, fetchDated: { [] })
        let sync = RecentPlaysSync(poller: poller, queue: queue, listenbrainz: ListenBrainzClient(transport: StubTransport()))
        _ = try await sync.run(listenbrainzUser: nil, checkListenBrainz: false, now: now)

        // Played "Words" on this Mac (exact), "Sunflower" on the phone.
        try await queue.enqueue(Scrobble(artist: "Low", track: "Words", listenedAt: now + 30), source: .mac, now: now + 30)
        feed.tracks = ["Sunflower", "Words", "Old"]
        let check = CaptureCheck(defaults: defaults)
        check.start(at: now)
        let outcome = try await sync.run(listenbrainzUser: nil, checkListenBrainz: false, captureCheck: check, now: now + 600)

        XCTAssertEqual(outcome, .init(found: 2, stored: 1))
        let tracks = queue.scrobbles(from: .distantPast, to: .distantFuture).map(\.track)
        XCTAssertEqual(Set(tracks), ["Words", "Sunflower"])
        let report = check.report(exactPlays: queue.scrobbles(from: .distantPast, to: .distantFuture, sources: [.mac]),
                                  now: now + 30 + OtherDeviceFilter.appleListingLag + 1)
        XCTAssertEqual(report, .init(listed: 1, total: 1))
    }

    func testSkipsPlaysAnotherDeviceSentToListenBrainz() async throws {
        let feed = Feed()
        feed.tracks = ["Old"]
        let queue = makeQueue()
        let listens = #"{"payload":{"count":1,"listens":[{"listened_at":1800000400,"track_metadata":{"artist_name":"Low","track_name":"Sunflower"}}]}}"#
        let lb = StubTransport(.json(listens))
        let poller = RecentPlaysPoller(pages: 1, defaults: defaults, fetchPage: { _ in feed.page() }, fetchDated: { [] })
        let sync = RecentPlaysSync(poller: poller, queue: queue, listenbrainz: ListenBrainzClient(transport: lb))
        _ = try await sync.run(listenbrainzUser: "me", checkListenBrainz: true, now: now)

        feed.tracks = ["Sunflower", "Old"]
        let outcome = try await sync.run(listenbrainzUser: "me", checkListenBrainz: true, now: now + 600)
        XCTAssertEqual(outcome, .init(found: 1, stored: 0))
    }

    // A song this device found in an earlier check and sent is in
    // ListenBrainz too; that listen must not hide a later replay.
    func testOwnEarlierFindsInListenBrainzDontHideAReplay() {
        let t = now
        let earlierFind = Scrobble(artist: "Low", track: "Words", listenedAt: t)
        let otherDevice = Scrobble(artist: "Low", track: "Lullaby", listenedAt: t + 60)
        let liveHere = Scrobble(artist: "Low", track: "Sunflower", listenedAt: t + 120)
        let kept = RecentPlaysSync.otherDevicesListens(
            [earlierFind, otherDevice, liveHere], storedHere: [earlierFind, liveHere], exactHere: [liveHere]
        )
        XCTAssertEqual(kept.map(\.track), ["Lullaby", "Sunflower"])
    }
}

final class ListeningStatsTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    func testCountsGroupNamesAndKeepTheLatestSpelling() {
        let plays = [
            Scrobble(artist: "bjork", track: "Joga", listenedAt: t),
            Scrobble(artist: "Low", track: "Words", listenedAt: t + 10),
            Scrobble(artist: "Björk", track: "Jóga", listenedAt: t + 20),
            Scrobble(artist: "Low", track: "Words", listenedAt: t + 30),
            Scrobble(artist: "Low", track: "Lullaby", listenedAt: t + 40),
        ]
        let summary = ListeningSummary.make(plays, limit: 2)
        XCTAssertEqual(summary.plays, 5)
        XCTAssertEqual(summary.topArtists, [ArtistCount(name: "Low", listens: 3), ArtistCount(name: "Björk", listens: 2)])
        XCTAssertEqual(summary.topTracks.first, TrackCount(track: "Words", artist: "Low", listens: 2))
        XCTAssertEqual(summary.latest?.track, "Lullaby")
    }

    func testSentences() {
        let summary = ListeningSummary(plays: 312, topArtists: [
            ArtistCount(name: "Radiohead", listens: 40), ArtistCount(name: "Björk", listens: 31),
            ArtistCount(name: "Low", listens: 20), ArtistCount(name: "Can", listens: 2),
        ], topTracks: [], latest: nil)
        XCTAssertEqual(summary.sentence(period: "this week"),
                       "This week you played 312 tracks. Most played: Radiohead (40), Björk (31) and Low (20).")
        XCTAssertEqual(ListeningSummary(plays: 0, topArtists: [], topTracks: [], latest: nil).sentence(period: "on Monday"),
                       "On Monday you didn't play anything that was scrobbled.")
        XCTAssertEqual([ArtistCount(name: "Low", listens: 1)].sentence(range: .thisMonth),
                       "Your top artists this month: Low (1 play).")
        XCTAssertEqual([TrackCount(track: "Words", artist: "Low", listens: 3), TrackCount(track: "Joga", artist: "Björk", listens: 2)]
            .sentence(range: .allTime), "Your top tracks of all time: Words by Low (3 plays) and Joga by Björk (2).")
    }

    func testRangeStarts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.firstWeekday = 1
        let friday = ISO8601DateFormatter().date(from: "2026-11-20T15:00:00-06:00")!
        XCTAssertEqual(StatsRange.thisWeek.start(containing: friday, calendar: calendar),
                       ISO8601DateFormatter().date(from: "2026-11-15T00:00:00-06:00"))
        XCTAssertEqual(StatsRange.thisMonth.start(containing: friday, calendar: calendar),
                       ISO8601DateFormatter().date(from: "2026-11-01T00:00:00-05:00"))
        XCTAssertNil(StatsRange.allTime.start(containing: friday, calendar: calendar))
    }
}

@MainActor
final class ListeningHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUsesThisDeviceWithoutListenBrainz() async throws {
        let local = [Scrobble(artist: "Low", track: "Words", listenedAt: now - 60)]
        let history = ListeningHistory(client: ListenBrainzClient(transport: StubTransport()), listenbrainzUser: nil,
                                       localPlays: { _, _ in local })
        XCTAssertEqual(history.source, .thisDevice)
        let summary = try await history.summary(ofDay: now)
        XCTAssertEqual(summary.plays, 1)
        let top = try await history.topArtists(.thisYear, now: now)
        XCTAssertEqual(top, [ArtistCount(name: "Low", listens: 1)])
    }

    func testLongRangesUseListenBrainzStatistics() async throws {
        let stats = StubTransport(.json(#"{"payload":{"artists":[{"artist_name":"Can","listen_count":99}]}}"#))
        let history = ListeningHistory(client: ListenBrainzClient(transport: stats), listenbrainzUser: "me",
                                       localPlays: { _, _ in [] })
        let top = try await history.topArtists(.allTime, now: now)
        XCTAssertEqual(top, [ArtistCount(name: "Can", listens: 99)])
        XCTAssertTrue(stats.requests.first?.url?.path.contains("stats/user/me/artists") ?? false)
    }
}

final class PlaybackTrackerPlayedTimeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFinishedCarriesThePlayedTimeOfAScrobbledTrack() {
        var tracker = PlaybackTracker()
        let a = PlayingTrack(id: "A", artist: "Low", title: "Words", durationSec: 200)
        _ = tracker.handle(track: a, state: .playing, at: t0)
        _ = tracker.handle(track: a, state: .paused, at: t0 + 120)
        _ = tracker.handle(track: a, state: .playing, at: t0 + 600)
        _ = tracker.tick(at: t0 + 650)
        let events = tracker.handle(track: nil, state: .stopped, at: t0 + 680)
        let finished = events.compactMap { if case .finished(let s) = $0 { s } else { nil } }
        XCTAssertEqual(finished.map(\.playedSec), [200], "paused time doesn't count")
        XCTAssertEqual(finished.first?.listenedAt, t0, "same start time as the scrobble")
    }

    func testSkippedTracksHaveNoFinishedEvent() {
        var tracker = PlaybackTracker()
        _ = tracker.handle(track: PlayingTrack(id: "A", artist: "Low", title: "Words", durationSec: 200), state: .playing, at: t0)
        let events = tracker.handle(track: PlayingTrack(id: "B", artist: "Low", title: "Lullaby", durationSec: 200),
                                    state: .playing, at: t0 + 20)
        XCTAssertFalse(events.contains { if case .finished = $0 { true } else { false } })
    }
}
