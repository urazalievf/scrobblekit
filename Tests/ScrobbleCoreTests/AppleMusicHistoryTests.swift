import XCTest
@testable import ScrobbleCore

final class AppleMusicHistoryTests: XCTestCase {
    func testURLAsksForLibrarySongsToo() {
        XCTAssertEqual(
            AppleMusicHistory.url(offset: 60).absoluteString,
            "https://api.music.apple.com/v1/me/recent/played/tracks?types=songs,library-songs&limit=30&offset=60"
        )
    }

    func testParsesCatalogAndLibrarySongs() throws {
        let json = #"""
        {"next":"/v1/me/recent/played/tracks?offset=30","data":[
          {"id":"1440818839","type":"songs","attributes":{"name":"Reckoner","artistName":"Radiohead","albumName":"In Rainbows","durationInMillis":290227}},
          {"id":"i.abc","type":"library-songs","attributes":{"name":"Words","artistName":"Low","albumName":"","durationInMillis":271500,"playParams":{"id":"i.abc","kind":"song","catalogId":"99"}}},
          {"id":"gone","type":"songs","attributes":{"name":"","artistName":"Nobody"}},
          {"id":"bare","type":"songs"}
        ]}
        """#
        let page = try AppleMusicHistory.parsePage(Data(json.utf8))
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items, [
            RecentPlay(id: "1440818839", artist: "Radiohead", title: "Reckoner", album: "In Rainbows",
                       durationSec: 290, lastPlayedDate: nil),
            RecentPlay(id: "i.abc", artist: "Low", title: "Words", album: nil, durationSec: 272,
                       lastPlayedDate: nil, catalogID: "99"),
        ])
    }

    func testLastPageHasNoMore() throws {
        let page = try AppleMusicHistory.parsePage(Data(#"{"data":[]}"#.utf8))
        XCTAssertFalse(page.hasMore)
        XCTAssertThrowsError(try AppleMusicHistory.parsePage(Data("<html>".utf8)))
    }

    func testPlayDatesComeFromMusicKitByIDCatalogIDOrName() {
        let d1 = Date(timeIntervalSince1970: 1_700_000_000)
        let d2 = Date(timeIntervalSince1970: 1_700_000_500)
        let d3 = Date(timeIntervalSince1970: 1_700_001_000)
        let raw = [
            RecentPlay(id: "1", artist: "A", title: "One", album: nil, durationSec: 100, lastPlayedDate: nil),
            RecentPlay(id: "i.2", artist: "B", title: "Two", album: nil, durationSec: 100, lastPlayedDate: nil, catalogID: "2"),
            RecentPlay(id: "i.3", artist: "C", title: "Three", album: nil, durationSec: 100, lastPlayedDate: nil),
            RecentPlay(id: "i.4", artist: "D", title: "Four", album: nil, durationSec: 100, lastPlayedDate: nil),
        ]
        let dated = [
            RecentPlay(id: "1", artist: "A", title: "One", album: nil, durationSec: 100, lastPlayedDate: d1),
            RecentPlay(id: "2", artist: "B", title: "Two", album: nil, durationSec: 100, lastPlayedDate: d2),
            RecentPlay(id: "x", artist: "c", title: "THREE", album: nil, durationSec: 100, lastPlayedDate: d3),
        ]
        let merged = AppleMusicHistory.addingPlayDates(to: raw, from: dated)
        XCTAssertEqual(merged.map(\.lastPlayedDate), [d1, d2, d3, nil])
        XCTAssertEqual(merged.map(\.id), raw.map(\.id), "order and IDs are the raw list's")
    }
}

@MainActor
final class RecentPlaysPollerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        defaults = UserDefaults(suiteName: "RecentPlaysPollerTests-\(UUID())")
    }

    private func page(_ ids: [String], more: Bool) -> Data {
        let items = ids.map {
            #"{"id":"\#($0)","type":"songs","attributes":{"name":"Song \#($0)","artistName":"Artist","durationInMillis":200000}}"#
        }.joined(separator: ",")
        return Data(#"{\#(more ? #""next":"/next","# : "")"data":[\#(items)]}"#.utf8)
    }

    /// Serves `pages[offset / 30]` for each request and records the offsets.
    private final class Pages: @unchecked Sendable {
        var pages: [Data]
        var offsets: [Int] = []
        var failAt: Int?
        init(_ pages: [Data]) { self.pages = pages }
        func fetch(_ url: URL) throws -> Data {
            let offset = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.first { $0.name == "offset" }!.value!)!
            offsets.append(offset)
            if offset == failAt { throw URLError(.timedOut) }
            return pages[offset / 30]
        }
    }

    private func poller(_ pages: Pages, count: Int = 2) -> RecentPlaysPoller {
        RecentPlaysPoller(pages: count, defaults: defaults,
                          fetchPage: { try pages.fetch($0) }, fetchDated: { [] })
    }

    func testFirstCheckIsABaselineThenNewPlaysAppear() async throws {
        let pages = Pages([page(["b", "c"], more: true), page(["d"], more: false)])
        let poller = poller(pages)
        let first = try await poller.poll(now: now)
        XCTAssertTrue(first.plays.isEmpty)
        XCTAssertNil(first.previousCheck)
        XCTAssertEqual(pages.offsets, [0, 30])

        pages.pages = [page(["a", "b"], more: true), page(["c", "d"], more: false)]
        let second = try await poller.poll(now: now + 180)
        XCTAssertEqual(second.plays.map(\.scrobble.track), ["Song a"])
        XCTAssertEqual(second.previousCheck, now)
        XCTAssertEqual(poller.lastCheck, now + 180)
    }

    func testStopsPagingWhenAppleHasNoMore() async throws {
        let pages = Pages([page(["a"], more: false)])
        _ = try await poller(pages, count: 4).poll(now: now)
        XCTAssertEqual(pages.offsets, [0])
    }

    func testAFailedPageChangesNothing() async throws {
        let pages = Pages([page(["b"], more: true), page(["c"], more: false)])
        let poller = poller(pages)
        _ = try await poller.poll(now: now)

        pages.pages = [page(["a", "b"], more: true), page(["c"], more: false)]
        pages.failAt = 30
        do {
            _ = try await poller.poll(now: now + 180)
            XCTFail("expected the page failure to throw")
        } catch {}

        pages.failAt = nil
        let retried = try await poller.poll(now: now + 360)
        XCTAssertEqual(retried.plays.map(\.scrobble.track), ["Song a"], "the failed check didn't swallow the play")
        XCTAssertEqual(retried.previousCheck, now)
    }

    // Comparing a 60-track window with a stored 30-track one would report 30
    // old tracks as new plays.
    func testAChangedWindowSizeStartsOverWithABaseline() async throws {
        let pages = Pages([page(["a", "b"], more: true), page(["c"], more: false)])
        _ = try await poller(pages, count: 1).poll(now: now)
        let wider = try await poller(pages, count: 2).poll(now: now + 180)
        XCTAssertTrue(wider.plays.isEmpty)
        XCTAssertNil(wider.previousCheck)
    }

    func testVersionZeroOneStateIsDropped() async throws {
        defaults.set(["old": 0.0], forKey: RecentPlaysPoller.legacyStateKey)
        _ = try await poller(Pages([page(["a"], more: false)])).poll(now: now)
        XCTAssertNil(defaults.object(forKey: RecentPlaysPoller.legacyStateKey))
    }
}
