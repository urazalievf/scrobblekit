import Foundation
#if canImport(MusicKit)
import MusicKit
#endif

/// Reads Apple Music's account-wide Recently Played and returns the plays
/// that appeared since the previous check. The iPhone app runs it from
/// background tasks and Shortcuts; the Mac app runs it every few minutes
/// while it's awake, which catches the iPhone's, CarPlay's and HomePod's
/// plays without anything running on those devices.
///
/// Every check reads the same number of pages (`pages` × 30 tracks), so a
/// track only leaves the compared window by being pushed out by newer plays.
/// A check whose page fails changes nothing.
@MainActor
public final class RecentPlaysPoller {
    public struct Result: Sendable, Equatable {
        public var plays: [DetectedPlay]
        /// When the previous successful check ran; nil on the first one.
        public var previousCheck: Date?
    }

    public typealias PageFetcher = @Sendable (URL) async throws -> Data
    public typealias DatedFetcher = @Sendable () async throws -> [RecentPlay]

    public let pages: Int
    private let defaults: UserDefaults
    private let fetchPage: PageFetcher
    private let fetchDated: DatedFetcher

    static let stateKey = "recentPlays.v2"
    /// 0.1.0's iPhone state: MusicKit IDs from a 30-track window.
    static let legacyStateKey = "recentPlays.lastSeen"

    /// `fetchPage` and `fetchDated` default to MusicKit; tests pass stubs.
    public init(
        pages: Int, defaults: UserDefaults = .standard,
        fetchPage: PageFetcher? = nil, fetchDated: DatedFetcher? = nil
    ) {
        self.pages = max(1, pages)
        self.defaults = defaults
        self.fetchPage = fetchPage ?? Self.musicKitPage
        self.fetchDated = fetchDated ?? Self.musicKitDated
    }

    /// When the last successful check ran.
    public var lastCheck: Date? { loadState()?.checkedAt }

    public func poll(now: Date) async throws -> Result {
        var items: [RecentPlay] = []
        for page in 0..<pages {
            let data = try await fetchPage(AppleMusicHistory.url(offset: page * AppleMusicHistory.pageSize))
            let parsed = try AppleMusicHistory.parsePage(data)
            items += parsed.items
            if !parsed.hasMore { break }
        }
        // Play dates are a bonus; a failure here just means estimated times.
        let dated = (try? await fetchDated()) ?? []
        items = AppleMusicHistory.addingPlayDates(to: items, from: dated)

        let state = loadState()
        let diff = RecentPlaysDiff.newPlays(in: items, lastSeen: state?.lastSeen, now: now)
        saveState(State(window: pages, checkedAt: now, lastSeen: diff.lastSeen))
        defaults.removeObject(forKey: Self.legacyStateKey)
        if !diff.plays.isEmpty {
            Log.capture.info("Recently Played: \(diff.plays.count) new plays")
        }
        return Result(plays: diff.plays, previousCheck: state?.checkedAt)
    }

    /// Forgets what was seen, so the next check only records a baseline.
    public func reset() {
        defaults.removeObject(forKey: Self.stateKey)
    }

    // MARK: State

    private struct State {
        var window: Int
        var checkedAt: Date
        var lastSeen: [String: Double]
    }

    /// nil on the first check, after `reset`, or when the window size changed
    /// (an older state compared a different number of tracks).
    private func loadState() -> State? {
        guard let stored = defaults.dictionary(forKey: Self.stateKey),
              let window = stored["window"] as? Int, window == pages,
              let checkedAt = stored["checkedAt"] as? Double,
              let lastSeen = stored["lastSeen"] as? [String: Double]
        else { return nil }
        return State(window: window, checkedAt: Date(timeIntervalSince1970: checkedAt), lastSeen: lastSeen)
    }

    private func saveState(_ state: State) {
        defaults.set([
            "window": state.window,
            "checkedAt": state.checkedAt.timeIntervalSince1970,
            "lastSeen": state.lastSeen,
        ] as [String: Any], forKey: Self.stateKey)
    }

    // MARK: MusicKit

    private static let musicKitPage: PageFetcher = { url in
        #if canImport(MusicKit)
        return try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
        #else
        throw AppleMusicHistory.ParseError.unexpectedResponse
        #endif
    }

    private static let musicKitDated: DatedFetcher = {
        #if canImport(MusicKit)
        var request = MusicRecentlyPlayedRequest<Track>()
        request.limit = AppleMusicHistory.pageSize
        return try await request.response().items.map { track in
            RecentPlay(
                id: track.id.rawValue,
                artist: track.artistName,
                title: track.title,
                album: track.albumTitle,
                durationSec: track.duration.map { Int($0.rounded()) },
                lastPlayedDate: track.lastPlayedDate
            )
        }
        #else
        return []
        #endif
    }
}
