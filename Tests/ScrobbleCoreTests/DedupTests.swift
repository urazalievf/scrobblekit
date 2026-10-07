import SwiftData
import XCTest
@testable import ScrobbleCore

final class DedupTests: XCTestCase {
    private var context: ModelContext!
    /// 1_700_000_040 = 28_333_334 × 60, the first second of a minute bucket.
    private let bucketStart = Date(timeIntervalSince1970: 1_700_000_040)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        let container = try ModelContainer(
            for: ScrobbleRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func play(
        _ artist: String = "Radiohead", _ track: String = "Reckoner", at date: Date? = nil,
        album: String? = nil, mbid: String? = nil, duration: Int? = 290
    ) -> Scrobble {
        Scrobble(artist: artist, track: track, album: album, durationSec: duration,
                 listenedAt: date ?? bucketStart, recordingMBID: mbid)
    }

    private func recordCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<ScrobbleRecord>())
    }

    // MARK: Key

    // Expected value from `shasum -a 256` of "radiohead|reckoner|28333333".
    func testKeyIsSHA256OfLowercasedArtistTrackAndMinute() {
        XCTAssertEqual(
            Dedup.key(artist: "Radiohead", track: "Reckoner", listenedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            "09a63c4a936b81b5c67400e6ffc86b23e5f597f9efe3b60fe80c0da1341cea91"
        )
    }

    func testKeyIgnoresCase() {
        XCTAssertEqual(
            Dedup.key(artist: "RADIOHEAD", track: "reckoner", listenedAt: bucketStart),
            Dedup.key(artist: "Radiohead", track: "Reckoner", listenedAt: bucketStart)
        )
    }

    func testBucketBoundary() {
        let key = { (offset: TimeInterval) in
            Dedup.key(artist: "Radiohead", track: "Reckoner", listenedAt: self.bucketStart + offset)
        }
        XCTAssertEqual(key(0), key(59), "same minute")
        XCTAssertEqual(key(0), key(59.999), "fractions of a second are truncated")
        XCTAssertNotEqual(key(0), key(60), "next minute")
        // The tradeoff: two captures of one play straddling a minute boundary
        // get different keys and are not merged.
        XCTAssertNotEqual(key(-1), key(0))
    }

    func testDistinctPlaysGetDistinctKeys() {
        var keys = Set<String>()
        let artists = ["Radiohead", "Radiohead ", "Portishead", "Björk", "Bjork"]
        let tracks = ["Reckoner", "Reckoner (Live)", "Nude", "Jóga", "Joga"]
        for artist in artists {
            for track in tracks {
                for minute in 0..<40 {
                    keys.insert(Dedup.key(artist: artist, track: track, listenedAt: bucketStart + Double(minute * 60)))
                }
            }
        }
        XCTAssertEqual(keys.count, artists.count * tracks.count * 40)
    }

    // MARK: Insert or merge

    func testNewPlayIsInsertedWithUnsentState() throws {
        let result = try Dedup.insertOrMerge(play(album: "In Rainbows"), source: .mac, into: context, now: now)

        guard case .inserted(let record) = result else { return XCTFail("expected insert, got \(result)") }
        XCTAssertEqual(record.artist, "Radiohead")
        XCTAssertEqual(record.album, "In Rainbows")
        XCTAssertEqual(record.listenedAt, bucketStart)
        XCTAssertEqual(record.durationSec, 290)
        XCTAssertEqual(record.source, .mac)
        XCTAssertFalse(record.lastfmSent)
        XCTAssertFalse(record.listenbrainzSent)
        XCTAssertEqual(record.attempts, 0)
        XCTAssertNil(record.lastError)
        XCTAssertNil(record.nextAttemptAt)
        XCTAssertFalse(record.permanentlyFailed)
        XCTAssertEqual(record.createdAt, now)
        XCTAssertEqual(record.dedupKey, Dedup.key(artist: "Radiohead", track: "Reckoner", listenedAt: bucketStart))
        XCTAssertEqual(try recordCount(), 1)
    }

    func testSamePlayInSameMinuteIsMergedNotDuplicated() throws {
        guard case .inserted(let original) = try Dedup.insertOrMerge(
            play(duration: nil), source: .foreground, into: context, now: now
        ) else { return XCTFail("expected insert") }
        original.lastfmSent = true

        let second = play("RADIOHEAD", "reckoner", at: bucketStart + 40, album: "In Rainbows", mbid: "mbid-1", duration: 290)
        let result = try Dedup.insertOrMerge(second, source: .poll, into: context, now: now + 300)

        guard case .merged(let merged) = result else { return XCTFail("expected merge, got \(result)") }
        XCTAssertTrue(merged === original)
        XCTAssertEqual(try recordCount(), 1)
        // Missing fields are filled in...
        XCTAssertEqual(merged.album, "In Rainbows")
        XCTAssertEqual(merged.recordingMBID, "mbid-1")
        XCTAssertEqual(merged.durationSec, 290)
        // ...but what was already recorded is kept.
        XCTAssertEqual(merged.artist, "Radiohead")
        XCTAssertEqual(merged.listenedAt, bucketStart)
        XCTAssertEqual(merged.source, .foreground)
        XCTAssertTrue(merged.lastfmSent, "send state survives a merge")
        XCTAssertEqual(merged.createdAt, now)
    }

    func testMergeDoesNotOverwriteKnownFields() throws {
        _ = try Dedup.insertOrMerge(play(album: "In Rainbows", mbid: "right"), source: .mac, into: context, now: now)
        let result = try Dedup.insertOrMerge(
            play(album: "In Rainbows (Deluxe)", mbid: "other"), source: .poll, into: context, now: now
        )
        guard case .merged(let record) = result else { return XCTFail("expected merge") }
        XCTAssertEqual(record.album, "In Rainbows")
        XCTAssertEqual(record.recordingMBID, "right")
    }

    func testSamePlayInNextMinuteIsSeparate() throws {
        _ = try Dedup.insertOrMerge(play(at: bucketStart), source: .mac, into: context, now: now)
        let result = try Dedup.insertOrMerge(play(at: bucketStart + 60), source: .mac, into: context, now: now)
        guard case .inserted = result else { return XCTFail("expected insert, got \(result)") }
        XCTAssertEqual(try recordCount(), 2)
    }

    // Edge case from the spec: iCloud sync delivering historical plays that
    // were already captured.
    func testReplayedHistoricalPlaysAreCaught() throws {
        let history = (0..<5).map { play(track: "Track \($0)", at: bucketStart + Double($0 * 240)) }
        for scrobble in history {
            _ = try Dedup.insertOrMerge(scrobble, source: .poll, into: context, now: now)
        }
        for scrobble in history {
            _ = try Dedup.insertOrMerge(scrobble, source: .poll, into: context, now: now + 86_400)
        }
        XCTAssertEqual(try recordCount(), 5)
    }

    func testRecordConvertsBackToScrobble() throws {
        guard case .inserted(let withDuration) = try Dedup.insertOrMerge(
            play(album: "In Rainbows", mbid: "mbid-1"), source: .mac, into: context, now: now
        ) else { return XCTFail("expected insert") }
        XCTAssertEqual(withDuration.scrobble, play(album: "In Rainbows", mbid: "mbid-1"))

        guard case .inserted(let unknownDuration) = try Dedup.insertOrMerge(
            play("Other", duration: nil), source: .mac, into: context, now: now
        ) else { return XCTFail("expected insert") }
        XCTAssertEqual(unknownDuration.durationSec, 0, "stored as 0 when unknown")
        XCTAssertNil(unknownDuration.scrobble.durationSec, "and sent as unknown")
    }
}

private extension DedupTests {
    func play(track: String, at date: Date) -> Scrobble {
        play("Radiohead", track, at: date)
    }
}
