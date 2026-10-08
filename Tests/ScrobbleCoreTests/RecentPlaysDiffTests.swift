import XCTest
@testable import ScrobbleCore

final class RecentPlaysDiffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_010_000)

    private func item(_ id: String, played: TimeInterval? = nil, duration: Int? = 200) -> RecentPlay {
        RecentPlay(id: id, artist: "Artist", title: "Song \(id)", album: nil, durationSec: duration,
                   lastPlayedDate: played.map(Date.init(timeIntervalSince1970:)))
    }

    func testFirstPollOnlySetsABaseline() {
        let result = RecentPlaysDiff.newPlays(in: [item("1", played: 1_700_000_000), item("2")], lastSeen: nil, now: now)
        XCTAssertTrue(result.plays.isEmpty)
        XCTAssertEqual(result.lastSeen, ["1": 1_700_000_000, "2": 0])
    }

    func testNewDatedItemIsAPollPlayAtItsDate() {
        let result = RecentPlaysDiff.newPlays(
            in: [item("new", played: 1_700_005_000), item("old", played: 1_700_000_000)],
            lastSeen: ["old": 1_700_000_000], now: now
        )
        XCTAssertEqual(result.plays.map(\.scrobble.track), ["Song new"])
        XCTAssertEqual(result.plays.first?.source, .poll)
        XCTAssertEqual(result.plays.first?.scrobble.listenedAt, Date(timeIntervalSince1970: 1_700_005_000))
    }

    func testAdvancedDateIsARepeatPlay() {
        let result = RecentPlaysDiff.newPlays(
            in: [item("a", played: 1_700_009_000)], lastSeen: ["a": 1_700_000_000], now: now
        )
        XCTAssertEqual(result.plays.map(\.source), [.poll])
        XCTAssertEqual(result.lastSeen["a"], 1_700_009_000)
    }

    func testUnchangedItemsProduceNothing() {
        let result = RecentPlaysDiff.newPlays(
            in: [item("a", played: 1_700_000_000), item("b")], lastSeen: ["a": 1_700_000_000, "b": 0], now: now
        )
        XCTAssertTrue(result.plays.isEmpty)
    }

    func testNewUndatedItemsAreInferredBackwardsFromNow() {
        let result = RecentPlaysDiff.newPlays(
            in: [item("x", duration: 200), item("y", duration: 300), item("seen")],
            lastSeen: ["seen": 0], now: now
        )
        XCTAssertEqual(result.plays.map(\.source), [.inferred, .inferred])
        XCTAssertEqual(result.plays.map(\.scrobble.listenedAt), [now - 200, now - 500])
    }

    func testItemsThatDropOutAreForgotten() {
        let result = RecentPlaysDiff.newPlays(in: [item("a")], lastSeen: ["a": 0, "gone": 5], now: now)
        XCTAssertEqual(result.lastSeen, ["a": 0])
    }
}

final class OtherDeviceFilterTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    func testDropsPlaysAlreadyInHistoryNearTheSameTime() {
        let plays = [
            Scrobble(artist: "Radiohead", track: "Reckoner", listenedAt: t),
            Scrobble(artist: "Radiohead", track: "Nude", listenedAt: t + 600),
            Scrobble(artist: "Radiohead", track: "Reckoner", listenedAt: t + 7200),
        ]
        let history = [Scrobble(artist: "RADIOHEAD", track: "reckoner", listenedAt: t - 240)]
        let kept = OtherDeviceFilter.removingAlreadyScrobbled(plays, history: history)
        XCTAssertEqual(kept.map(\.track), ["Nude", "Reckoner"])
        XCTAssertEqual(kept.last?.listenedAt, t + 7200, "two hours later is a separate play")
    }
}
