import Foundation
import Observation
import SwiftData

public struct Credentials: Sendable {
    public var lastfmSessionKey: String?
    public var listenbrainzToken: String?

    public init(lastfmSessionKey: String?, listenbrainzToken: String?) {
        self.lastfmSessionKey = lastfmSessionKey
        self.listenbrainzToken = listenbrainzToken
    }
}

public enum ServiceState: Sendable, Equatable {
    /// Nothing sent yet since launch.
    case unknown
    /// The last send succeeded.
    case ok
    /// No session key or token stored.
    case notConnected
    /// The service rejected the stored credentials; log in again.
    case needsLogin
    /// Last.fm suspended the API key (error 26). Sending has stopped.
    case suspended
    /// The last send failed and will be retried.
    case failing(String)
}

public struct QueueStatus: Sendable, Equatable {
    public var lastfm: ServiceState
    public var listenbrainz: ServiceState
    public var lastFlush: Date?
}

public struct FlushReport: Sendable, Equatable {
    public var lastfmSent = 0
    public var listenbrainzSent = 0
    public var failed = 0

    public init() {}
}

/// Stores plays and sends them to Last.fm and ListenBrainz.
///
/// Runs on the main actor with the container's main context, so SwiftUI
/// `@Query` views see changes immediately. Network calls are awaited and
/// don't block the main thread.
@MainActor
@Observable
public final class ScrobbleQueue {
    public private(set) var status: QueueStatus

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let lastfm: LastFMClient?
    @ObservationIgnored private let listenbrainz: ListenBrainzClient
    @ObservationIgnored private let resolver: MBIDResolver?
    @ObservationIgnored private let credentials: @Sendable () -> Credentials
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isFlushing = false

    static let lastfmBatchSize = LastFMClient.maxBatchSize
    static let listenbrainzBatchSize = 100
    private static let suspendedKey = "lastfm.apiKeySuspended"
    /// Last.fm ignored-message code for the daily scrobble limit, the one
    /// ignore reason worth retrying.
    private static let dailyLimitCode = 5

    /// `lastfm` is nil when no API key is configured; Last.fm is then skipped.
    public init(
        context: ModelContext,
        lastfm: LastFMClient?,
        listenbrainz: ListenBrainzClient,
        resolver: MBIDResolver?,
        credentials: @escaping @Sendable () -> Credentials,
        defaults: UserDefaults = .standard
    ) {
        self.context = context
        self.lastfm = lastfm
        self.listenbrainz = listenbrainz
        self.resolver = resolver
        self.credentials = credentials
        self.defaults = defaults
        let suspended = defaults.bool(forKey: Self.suspendedKey)
        status = QueueStatus(lastfm: suspended ? .suspended : .unknown, listenbrainz: .unknown, lastFlush: nil)
    }

    // MARK: Adding plays

    /// Resolves the MusicBrainz recording (when a resolver is set and the play
    /// has no MBID), then inserts the play or merges it into an existing
    /// record for the same play. A failed lookup is logged and the play is
    /// stored without an MBID.
    @discardableResult
    public func enqueue(_ scrobble: Scrobble, source: ScrobbleSource, now: Date = Date()) async throws -> ScrobbleRecord {
        var scrobble = scrobble
        var releaseMBID: String?
        if let resolver, scrobble.recordingMBID == nil {
            do {
                let match = try await resolver.resolve(
                    artist: scrobble.artist, track: scrobble.track, album: scrobble.album,
                    durationSec: scrobble.durationSec, now: now
                ).match
                scrobble.recordingMBID = match?.recordingMBID
                releaseMBID = match?.releaseMBID
            } catch {
                Log.queue.error("MusicBrainz lookup failed, storing without MBID: \(error.localizedDescription, privacy: .public)")
            }
        }

        let record = try Dedup.insertOrMerge(scrobble, source: source, into: context, now: now).record
        if record.releaseMBID == nil { record.releaseMBID = releaseMBID }
        try context.save()
        return record
    }

    // MARK: Sending

    /// Sends now-playing to both services. Failures are logged, not retried:
    /// a now-playing update is only useful while the track plays.
    public func sendNowPlaying(_ scrobble: Scrobble) async {
        let credentials = credentials()
        if let lastfm, let sessionKey = credentials.lastfmSessionKey, status.lastfm != .suspended {
            do {
                try await lastfm.updateNowPlaying(scrobble, sessionKey: sessionKey)
            } catch {
                handleLastFM(error)
            }
        }
        if let token = credentials.listenbrainzToken {
            do {
                try await listenbrainz.submit([scrobble], as: .playingNow, token: token)
            } catch {
                handleListenBrainz(error)
            }
        }
    }

    /// Sends every due record to each service it hasn't reached yet. A record
    /// gets at most one counted failure per flush, even if both services fail.
    /// Missing credentials and rejected logins don't count as failures.
    @discardableResult
    public func flush(now: Date = Date()) async -> FlushReport {
        guard !isFlushing else { return FlushReport() }
        isFlushing = true
        defer { isFlushing = false }

        var report = FlushReport()
        let due: [ScrobbleRecord]
        do {
            due = try unsentRecords().filter { RetryPolicy.isDue($0, now: now) }
        } catch {
            Log.queue.error("Couldn't read the queue: \(error.localizedDescription, privacy: .public)")
            return report
        }

        var failures: [ObjectIdentifier: (error: String, minimumDelay: TimeInterval?)] = [:]
        func fail(_ batch: [ScrobbleRecord], _ error: String, minimumDelay: TimeInterval? = nil) {
            for record in batch {
                let previous = failures[ObjectIdentifier(record)]?.minimumDelay
                failures[ObjectIdentifier(record)] = (error, max(previous ?? 0, minimumDelay ?? 0))
            }
        }

        let credentials = credentials()
        await flushLastFM(due.filter { !$0.lastfmSent }, sessionKey: credentials.lastfmSessionKey,
                          report: &report, fail: fail)
        await flushListenBrainz(due.filter { !$0.listenbrainzSent }, token: credentials.listenbrainzToken,
                                report: &report, fail: fail)

        for record in due {
            guard let failure = failures[ObjectIdentifier(record)] else { continue }
            RetryPolicy.recordFailure(on: record, error: failure.error, now: now, minimumDelay: failure.minimumDelay)
            report.failed += 1
        }
        status.lastFlush = now
        save()
        return report
    }

    private func flushLastFM(
        _ pending: [ScrobbleRecord], sessionKey: String?,
        report: inout FlushReport, fail: ([ScrobbleRecord], String, TimeInterval?) -> Void
    ) async {
        guard status.lastfm != .suspended else { return }
        guard let lastfm, let sessionKey else {
            status.lastfm = .notConnected
            return
        }
        for batch in pending.chunked(into: Self.lastfmBatchSize) {
            do {
                let result = try await lastfm.scrobble(batch.map(\.scrobble), sessionKey: sessionKey)
                for (index, record) in batch.enumerated() {
                    let code = index < result.ignoredCodes.count ? result.ignoredCodes[index] : 0
                    if code == Self.dailyLimitCode {
                        fail([record], "Last.fm daily scrobble limit reached", nil)
                    } else {
                        // Accepted, or ignored for a reason a retry won't change.
                        record.lastfmSent = true
                        report.lastfmSent += 1
                    }
                }
                status.lastfm = .ok
            } catch {
                if case .failing(let message) = handleLastFM(error) {
                    fail(batch, message, nil)
                }
                return
            }
        }
    }

    private func flushListenBrainz(
        _ pending: [ScrobbleRecord], token: String?,
        report: inout FlushReport, fail: ([ScrobbleRecord], String, TimeInterval?) -> Void
    ) async {
        guard let token else {
            status.listenbrainz = .notConnected
            return
        }
        for batch in pending.chunked(into: Self.listenbrainzBatchSize) {
            do {
                let type: ListenType = batch.count == 1 ? .single : .import
                try await listenbrainz.submit(batch.map(\.scrobble), as: type, token: token)
                batch.forEach { $0.listenbrainzSent = true }
                report.listenbrainzSent += batch.count
                status.listenbrainz = .ok
            } catch {
                if case .failing(let message) = handleListenBrainz(error) {
                    let delay: TimeInterval? = if case ListenBrainzError.rateLimited(let after) = error { after } else { nil }
                    fail(batch, message, delay)
                }
                return
            }
        }
    }

    /// Updates the Last.fm status for an error and returns it.
    @discardableResult
    private func handleLastFM(_ error: Error) -> ServiceState {
        let state: ServiceState
        switch error as? LastFMError {
        case .invalidSession:
            state = .needsLogin
        case .apiKeySuspended:
            defaults.set(true, forKey: Self.suspendedKey)
            state = .suspended
            Log.queue.fault("Last.fm suspended the API key (error 26); Last.fm scrobbling is off")
        default:
            state = .failing(Self.describe(error))
        }
        status.lastfm = state
        return state
    }

    @discardableResult
    private func handleListenBrainz(_ error: Error) -> ServiceState {
        let state: ServiceState = (error as? ListenBrainzError) == .invalidToken
            ? .needsLogin
            : .failing(Self.describe(error))
        status.listenbrainz = state
        return state
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as LastFMError:
            switch error {
            case .serviceOffline: "Last.fm is offline"
            case .temporaryError: "Last.fm had a temporary error"
            case .rateLimitExceeded: "Last.fm rate limit reached"
            case .api(let code, let message): "Last.fm error \(code): \(message)"
            case .httpStatus(let code): "Last.fm HTTP \(code)"
            default: "Last.fm: \(error)"
            }
        case let error as ListenBrainzError:
            switch error {
            case .rateLimited: "ListenBrainz rate limit reached"
            case .badRequest(let message): "ListenBrainz rejected the listen: \(message)"
            case .httpStatus(let code): "ListenBrainz HTTP \(code)"
            default: "ListenBrainz: \(error)"
            }
        default:
            error.localizedDescription
        }
    }

    // MARK: Managing records

    /// Records still owed to a service that has credentials and hasn't given up.
    public func pendingCount() -> Int {
        let credentials = credentials()
        let wantsLastFM = lastfm != nil && credentials.lastfmSessionKey != nil && status.lastfm != .suspended
        let wantsListenBrainz = credentials.listenbrainzToken != nil
        return ((try? unsentRecords()) ?? []).filter {
            (wantsLastFM && !$0.lastfmSent) || (wantsListenBrainz && !$0.listenbrainzSent)
        }.count
    }

    public func failedCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<ScrobbleRecord>(predicate: #Predicate { $0.permanentlyFailed == true }))) ?? 0
    }

    /// Clears the failure state so the next flush sends the record again.
    public func retryNow(_ record: ScrobbleRecord) {
        record.attempts = 0
        record.permanentlyFailed = false
        record.nextAttemptAt = nil
        record.lastError = nil
        save()
    }

    public func delete(_ record: ScrobbleRecord) {
        context.delete(record)
        save()
    }

    /// Re-enables Last.fm after a suspension, for example with a new API key.
    public func clearLastFMSuspension() {
        defaults.removeObject(forKey: Self.suspendedKey)
        status.lastfm = .unknown
    }

    /// Marks a service as needing attention after credentials change.
    public func credentialsChanged() {
        if status.lastfm != .suspended { status.lastfm = .unknown }
        status.listenbrainz = .unknown
    }

    private func unsentRecords() throws -> [ScrobbleRecord] {
        let descriptor = FetchDescriptor<ScrobbleRecord>(
            predicate: #Predicate {
                $0.permanentlyFailed == false && ($0.lastfmSent == false || $0.listenbrainzSent == false)
            },
            sortBy: [SortDescriptor(\.listenedAt)]
        )
        return try context.fetch(descriptor)
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.queue.error("Couldn't save the queue: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
