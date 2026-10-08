import XCTest
@testable import ScrobbleCore

final class PlaybackTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func track(_ id: String = "A", duration: Int? = 200, podcast: Bool = false) -> PlayingTrack {
        PlayingTrack(id: id, artist: "Artist \(id)", title: "Title \(id)", album: "Album",
                     durationSec: duration, isPodcast: podcast)
    }

    private func scrobbles(_ events: [PlaybackTracker.Event]) -> [Scrobble] {
        events.compactMap { if case .scrobble(let s) = $0 { s } else { nil } }
    }

    private func nowPlaying(_ events: [PlaybackTracker.Event]) -> [Scrobble] {
        events.compactMap { if case .nowPlaying(let s) = $0 { s } else { nil } }
    }

    func testStartingPlaybackAnnouncesNowPlaying() {
        var tracker = PlaybackTracker()
        let events = tracker.handle(track: track(), state: .playing, at: t0)
        XCTAssertEqual(nowPlaying(events).map(\.track), ["Title A"])
        XCTAssertTrue(scrobbles(events).isEmpty)
    }

    func testScrobblesOnceAtHalfwayWithStartTimeAsListenedAt() {
        var tracker = PlaybackTracker()
        _ = tracker.handle(track: track(duration: 200), state: .playing, at: t0)
        XCTAssertTrue(scrobbles(tracker.tick(at: t0 + 99)).isEmpty)

        let events = tracker.tick(at: t0 + 100)
        XCTAssertEqual(scrobbles(events).map(\.listenedAt), [t0])
        XCTAssertEqual(scrobbles(events).first?.durationSec, 200)
        XCTAssertTrue(scrobbles(tracker.tick(at: t0 + 150)).isEmpty, "only once")
    }

    func testFourMinutesIsEnoughForLongTracks() {
        var tracker = PlaybackTracker()
        _ = tracker.handle(track: track(duration: 600), state: .playing, at: t0)
        XCTAssertTrue(scrobbles(tracker.tick(at: t0 + 239)).isEmpty)
        XCTAssertEqual(scrobbles(tracker.tick(at: t0 + 240)).count, 1)
    }

    func testTracksOfThirtySecondsOrLessAreNeverScrobbled() {
        for duration in [12, 30] {
            var tracker = PlaybackTracker()
            _ = tracker.handle(track: track(duration: duration), state: .playing, at: t0)
            XCTAssertTrue(scrobbles(tracker.tick(at: t0 + 600)).isEmpty, "\(duration)s track")
        }
    }

    func testUnknownDurationNeedsFourMinutes() {
        var tracker = PlaybackTracker()
        _ = tracker.handle(track: track(duration: nil), state: .playing, at: t0)
        XCTAssertTrue(scrobbles(tracker.tick(at: t0 + 239)).isEmpty)
        XCTAssertEqual(scrobbles(tracker.tick(at: t0 + 240)).count, 1)
    }

    func testTracksLongerThanThirtyMinutesAreAllowed() {
        var tracker = PlaybackTracker()
        _ = tracker.handle(track: track(duration: 45 * 60), state: .playing, at: t0)
        XCTAssertEqual(scrobbles(tracker.tick(at: t0 + 240)).count, 1)
    }

    func testPausedTimeDoesNotCount() {
        var tracker = PlaybackTracker()
        _ = tracker.handle(track: track(duration: 200), state: .playing, at: t0)
        _ = tracker.handle(track: track(duration: 200), state: .paused, at: t0 + 50)
        _ = tracker.handle(track: track(duration: 200), state: .playing, at: t0 + 500)
        XCTAssertTrue(scrobbles(tracker.tick(at: t0 + 549)).isEmpty)
        XCTAssertEqual(scrobbles(tracker.tick(at: t0 + 550)).map(\.listenedAt), [t0])
    }

    func testTrackChangeScrobblesPreviousTrackIfEligible() {
        var tracker = PlaybackTracker()
        _ = tracker.handle(track: track("A", duration: 200), state: .playing, at: t0)
        let events = tracker.handle(track: track("B"), state: .playing, at: t0 + 150)
        XCTAssertEqual(scrobbles(events).map(\.track), ["Title A"])
        XCTAssertEqual(nowPlaying(events).map(\.track), ["Title B"])
    }

    func testSkippedTrackIsNotScrobbled() {
        var tracker = PlaybackTracker()
        _ = tracker.handle(track: track("A", duration: 200), state: .playing, at: t0)
        let events = tracker.handle(track: track("B"), state: .playing, at: t0 + 20)
        XCTAssertTrue(scrobbles(events).isEmpty)
    }

    func testPodcastsAreSkipped() {
        var tracker = PlaybackTracker()
        let start = tracker.handle(track: track(podcast: true), state: .playing, at: t0)
        XCTAssertTrue(start.isEmpty)
        XCTAssertTrue(tracker.tick(at: t0 + 3600).isEmpty)
    }

    // Edge case: scrubbing to the end still sends; Last.fm filters server side.
    func testScrubbingToTheEndCountsReportedPosition() {
        var tracker = PlaybackTracker()
        _ = tracker.handle(track: track(duration: 200), state: .playing, at: t0)
        XCTAssertEqual(scrobbles(tracker.tick(position: 190, at: t0 + 10)).count, 1)
    }

    // Edge case: Apple Music Radio tracks have no store ID; artist + title identify them.
    func testRadioTracksWithoutStoreIDUseArtistAndTitle() {
        XCTAssertEqual(PlayingTrack.fallbackID(artist: "Artist", title: "Song"), "artist|song")
        var tracker = PlaybackTracker()
        let radio = PlayingTrack(id: PlayingTrack.fallbackID(artist: "Artist", title: "Song"),
                                 artist: "Artist", title: "Song", durationSec: 200)
        _ = tracker.handle(track: radio, state: .playing, at: t0)
        XCTAssertEqual(scrobbles(tracker.tick(at: t0 + 100)).count, 1)
    }

    func testStopEndsTheListenAndReplayStartsANewOne() {
        var tracker = PlaybackTracker()
        _ = tracker.handle(track: track(duration: 200), state: .playing, at: t0)
        let stopped = tracker.handle(track: track(duration: 200), state: .stopped, at: t0 + 120)
        XCTAssertEqual(scrobbles(stopped).count, 1)
        XCTAssertNil(tracker.currentTrack)

        _ = tracker.handle(track: track(duration: 200), state: .playing, at: t0 + 300)
        XCTAssertEqual(scrobbles(tracker.tick(at: t0 + 400)).map(\.listenedAt), [t0 + 300])
    }

    func testTrackStartedPausedAnnouncesWhenPlaybackBegins() {
        var tracker = PlaybackTracker()
        XCTAssertTrue(tracker.handle(track: track(), state: .paused, at: t0).isEmpty)
        let events = tracker.handle(track: track(), state: .playing, at: t0 + 5)
        XCTAssertEqual(nowPlaying(events).count, 1)
    }
}
