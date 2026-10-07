import Foundation

/// A controllable clock for rate-limit tests. `sleep` records the requested
/// duration and returns immediately; with `advancesOnSleep` it also moves the
/// clock forward by that duration.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recordedSleeps: [TimeInterval] = []
    private let advancesOnSleep: Bool

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000), advancesOnSleep: Bool = true) {
        current = start
        self.advancesOnSleep = advancesOnSleep
    }

    var sleeps: [TimeInterval] { lock.withLock { recordedSleeps } }

    func now() -> Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        lock.withLock {
            recordedSleeps.append(seconds)
            if advancesOnSleep { current += seconds }
        }
    }
}
