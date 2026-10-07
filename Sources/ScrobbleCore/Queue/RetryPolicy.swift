import Foundation

/// When to retry a record after a failed send: 30 s, 2 min, 10 min, 1 h,
/// 6 h, then every 24 h. The 10th failed attempt marks it permanently failed.
public enum RetryPolicy {
    public static let schedule: [TimeInterval] = [30, 2 * 60, 10 * 60, 60 * 60, 6 * 60 * 60, 24 * 60 * 60]
    public static let maxAttempts = 10

    /// Wait after the given failed attempt (1-based). Attempts past the end
    /// of the schedule use its last value, 24 h.
    public static func delay(afterAttempt attempt: Int) -> TimeInterval {
        schedule[min(max(attempt, 1), schedule.count) - 1]
    }

    /// Counts a failed attempt, stores the error and sets the next attempt
    /// time. `minimumDelay` (a server's Retry-After) lengthens the wait but
    /// never shortens it.
    public static func recordFailure(
        on record: ScrobbleRecord, error: String, now: Date = Date(), minimumDelay: TimeInterval? = nil
    ) {
        record.attempts += 1
        record.lastError = error
        if record.attempts >= maxAttempts {
            record.permanentlyFailed = true
            record.nextAttemptAt = nil
        } else {
            let wait = max(delay(afterAttempt: record.attempts), minimumDelay ?? 0)
            record.nextAttemptAt = now.addingTimeInterval(wait)
        }
    }

    /// True when the record still has a service to send to, hasn't given up,
    /// and its wait (if any) is over.
    public static func isDue(_ record: ScrobbleRecord, now: Date = Date()) -> Bool {
        guard !record.permanentlyFailed, !record.isFullySent else { return false }
        guard let next = record.nextAttemptAt else { return true }
        return next <= now
    }
}
