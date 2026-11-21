import Foundation

/// Answers "what did I listen to" questions for the recap, Siri and
/// Shortcuts: from ListenBrainz when it's connected (every device that
/// scrobbles there), otherwise from the plays this device stored.
@MainActor
public struct ListeningHistory {
    public enum Source: Sendable, Equatable {
        case listenbrainz(user: String)
        case thisDevice
    }

    public typealias LocalPlays = @MainActor (_ from: Date, _ to: Date) -> [Scrobble]

    private let client: ListenBrainzClient
    private let listenbrainzUser: String?
    private let localPlays: LocalPlays

    public init(client: ListenBrainzClient = ListenBrainzClient(), listenbrainzUser: String?,
                localPlays: @escaping LocalPlays) {
        self.client = client
        self.listenbrainzUser = listenbrainzUser
        self.localPlays = localPlays
    }

    public var source: Source {
        listenbrainzUser.map { .listenbrainz(user: $0) } ?? .thisDevice
    }

    /// Up to `limit` plays in `from...to`, newest first.
    public func plays(from: Date, to: Date, limit: Int = 2000) async throws -> [Scrobble] {
        if let listenbrainzUser {
            return try await client.listens(user: listenbrainzUser, from: from, to: to, limit: limit)
        }
        return Array(localPlays(from, to).sorted { $0.listenedAt > $1.listenedAt }.prefix(limit))
    }

    /// The calendar day containing `day`.
    public func summary(ofDay day: Date, calendar: Calendar = .current) async throws -> ListeningSummary {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        return ListeningSummary.make(try await plays(from: start, to: end))
    }

    /// The period so far, counted from the plays themselves (current to the
    /// minute, unlike ListenBrainz's daily statistics).
    public func summary(of range: StatsRange, now: Date = Date(), calendar: Calendar = .current) async throws -> ListeningSummary {
        let start = range.start(containing: now, calendar: calendar) ?? .distantPast
        return ListeningSummary.make(try await plays(from: start, to: now))
    }

    /// ListenBrainz's statistics for long periods; counted from plays for a
    /// week, when the statistics aren't ready, or without ListenBrainz.
    public func topArtists(_ range: StatsRange, count: Int = 5, now: Date = Date()) async throws -> [ArtistCount] {
        if let listenbrainzUser, range != .thisWeek {
            let stats = try await client.topArtists(user: listenbrainzUser, range: range, count: count)
            if !stats.isEmpty { return stats }
        }
        return Array(try await countedSummary(range, now: now).topArtists.prefix(count))
    }

    public func topTracks(_ range: StatsRange, count: Int = 5, now: Date = Date()) async throws -> [TrackCount] {
        if let listenbrainzUser, range != .thisWeek {
            let stats = try await client.topTracks(user: listenbrainzUser, range: range, count: count)
            if !stats.isEmpty { return stats }
        }
        return Array(try await countedSummary(range, now: now).topTracks.prefix(count))
    }

    /// Counting a whole year or all time from individual plays is too much
    /// to fetch; those fall back to the last 30 days' plays.
    private func countedSummary(_ range: StatsRange, now: Date) async throws -> ListeningSummary {
        switch range {
        case .thisWeek, .thisMonth:
            return try await summary(of: range, now: now)
        case .thisYear, .allTime:
            let start = listenbrainzUser == nil ? (range.start(containing: now) ?? .distantPast)
                : now.addingTimeInterval(-30 * 24 * 60 * 60)
            return ListeningSummary.make(try await plays(from: start, to: now, limit: 5000))
        }
    }
}

/// How many of this Mac's exactly-captured plays Apple Music's Recently
/// Played also listed. Recently Played is all the iPhone app (and the Mac
/// for other devices) can read, so this is a measured stand-in for how much
/// of a device's listening that kind of capture catches.
///
/// Only plays made while the other-devices check was on, older than Apple's
/// listing lag and from the last 7 days count.
@MainActor
public struct CaptureCheck {
    public struct Report: Sendable, Equatable {
        public var listed: Int
        public var total: Int

        public var percent: Int? { total > 0 ? Int((Double(listed) / Double(total) * 100).rounded()) : nil }
    }

    public static let period: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private static let listedKey = "captureCheck.listed"
    private static let sinceKey = "captureCheck.since"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// When the other-devices check was turned on; nil while it's off.
    public var since: Date? {
        (defaults.object(forKey: Self.sinceKey) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    public func start(at now: Date) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.sinceKey)
        defaults.removeObject(forKey: Self.listedKey)
    }

    public func stop() {
        defaults.removeObject(forKey: Self.sinceKey)
        defaults.removeObject(forKey: Self.listedKey)
    }

    /// Notes which of `exactPlays` (this Mac's own) appear among `detected`,
    /// the plays one Recently Played check found.
    public func note(detected: [DetectedPlay], exactPlays: [Scrobble], previousCheck: Date?, now: Date) {
        guard since != nil, !detected.isEmpty else { return }
        var listed = listedKeys(now: now)
        for play in exactPlays {
            let key = Dedup.key(artist: play.artist, track: play.track, listenedAt: play.listenedAt)
            guard listed[key] == nil else { continue }
            let found = detected.contains {
                OtherDeviceFilter.isAlreadyScrobbled($0, history: [play], previousCheck: previousCheck, now: now)
            }
            if found { listed[key] = play.listenedAt.timeIntervalSince1970 }
        }
        defaults.set(listed, forKey: Self.listedKey)
    }

    public func report(exactPlays: [Scrobble], now: Date) -> Report? {
        guard let since else { return nil }
        let start = max(since, now.addingTimeInterval(-Self.period))
        let end = now.addingTimeInterval(-OtherDeviceFilter.appleListingLag)
        let counted = exactPlays.filter { $0.listenedAt >= start && $0.listenedAt <= end }
        let listed = listedKeys(now: now)
        let found = counted.filter {
            listed[Dedup.key(artist: $0.artist, track: $0.track, listenedAt: $0.listenedAt)] != nil
        }
        return Report(listed: found.count, total: counted.count)
    }

    private func listedKeys(now: Date) -> [String: Double] {
        let cutoff = now.addingTimeInterval(-Self.period).timeIntervalSince1970
        return (defaults.dictionary(forKey: Self.listedKey) as? [String: Double] ?? [:]).filter { $0.value >= cutoff }
    }
}
