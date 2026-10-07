import SwiftData
import XCTest
@testable import ScrobbleCore

final class RetryPolicyTests: XCTestCase {
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3600
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record() -> ScrobbleRecord {
        ScrobbleRecord(
            Scrobble(artist: "A", track: "B", listenedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            source: .mac, createdAt: now
        )
    }

    func testScheduleAfterEachFailedAttempt() {
        let expected: [TimeInterval] = [
            30, 2 * minute, 10 * minute, hour, 6 * hour, // attempts 1-5
            24 * hour, 24 * hour, 24 * hour, 24 * hour,  // attempts 6-9: capped at 24 h
        ]
        XCTAssertEqual((1...9).map(RetryPolicy.delay(afterAttempt:)), expected)
        XCTAssertEqual(RetryPolicy.maxAttempts, 10)
    }

    func testFailuresBackOffThenMarkPermanentlyFailedAfterTenAttempts() {
        let record = record()
        var clock = now
        var waits: [TimeInterval] = []

        for attempt in 1...9 {
            RetryPolicy.recordFailure(on: record, error: "offline \(attempt)", now: clock)
            XCTAssertEqual(record.attempts, attempt)
            XCTAssertFalse(record.permanentlyFailed)
            let next = try! XCTUnwrap(record.nextAttemptAt)
            waits.append(next.timeIntervalSince(clock))
            clock = next
        }
        XCTAssertEqual(waits, [30, 120, 600, 3600, 21_600, 86_400, 86_400, 86_400, 86_400])

        RetryPolicy.recordFailure(on: record, error: "offline 10", now: clock)
        XCTAssertEqual(record.attempts, 10)
        XCTAssertTrue(record.permanentlyFailed)
        XCTAssertNil(record.nextAttemptAt)
        XCTAssertEqual(record.lastError, "offline 10")
    }

    func testIsDue() {
        let record = record()
        XCTAssertTrue(RetryPolicy.isDue(record, now: now), "never attempted")

        RetryPolicy.recordFailure(on: record, error: "offline", now: now)
        XCTAssertFalse(RetryPolicy.isDue(record, now: now + 29))
        XCTAssertTrue(RetryPolicy.isDue(record, now: now + 30))

        record.lastfmSent = true
        record.listenbrainzSent = true
        XCTAssertFalse(RetryPolicy.isDue(record, now: now + 30), "nothing left to send")

        let failed = self.record()
        failed.permanentlyFailed = true
        XCTAssertFalse(RetryPolicy.isDue(failed, now: now))
    }

    func testOneServiceStillPendingIsDue() {
        let record = record()
        record.lastfmSent = true
        XCTAssertTrue(RetryPolicy.isDue(record, now: now))
    }
}
