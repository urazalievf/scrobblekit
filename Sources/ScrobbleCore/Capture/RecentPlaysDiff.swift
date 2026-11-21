import Foundation

/// One entry from Apple Music's Recently Played list.
public struct RecentPlay: Sendable, Equatable {
    public var id: String
    public var artist: String
    public var title: String
    public var album: String?
    public var durationSec: Int?
    /// Only library items carry this; catalog items usually don't.
    public var lastPlayedDate: Date?
    /// For a library item, the catalog song it is (when Apple says), so it
    /// can be matched with MusicKit's copy of the same entry.
    public var catalogID: String?

    public init(
        id: String, artist: String, title: String, album: String?, durationSec: Int?, lastPlayedDate: Date?,
        catalogID: String? = nil
    ) {
        self.id = id
        self.artist = artist
        self.title = title
        self.album = album
        self.durationSec = durationSec
        self.lastPlayedDate = lastPlayedDate
        self.catalogID = catalogID
    }
}

public struct DetectedPlay: Sendable, Equatable {
    public var scrobble: Scrobble
    public var source: ScrobbleSource
}

/// Finds plays in Recently Played that appeared since the previous poll.
///
/// Recently Played lists each track once, most recent first, and doesn't
/// always say when it was played. So:
/// - The first poll only records a baseline; nothing in it is scrobbled.
/// - A dated item is a play when it's new or its date moved forward (`poll`).
/// - An undated item is a play only when it's new. Its time is estimated by
///   stepping back from now through the durations of the newer items
///   (`inferred`). A repeat play of an undated track can't be seen.
public enum RecentPlaysDiff {
    public struct Result: Sendable, Equatable {
        public var plays: [DetectedPlay]
        /// Track ID → last played date in Unix seconds, 0 when undated.
        /// Only the current list is kept, so a track that drops out and
        /// comes back counts as a new play.
        public var lastSeen: [String: Double]
    }

    /// Duration assumed for an undated item with no length.
    public static let assumedDurationSec = 180

    public static func newPlays(in items: [RecentPlay], lastSeen: [String: Double]?, now: Date) -> Result {
        var updated: [String: Double] = [:]
        for item in items {
            updated[item.id] = max(updated[item.id] ?? 0, item.lastPlayedDate?.timeIntervalSince1970 ?? 0)
        }
        guard let lastSeen else { return Result(plays: [], lastSeen: updated) }

        var plays: [DetectedPlay] = []
        var cursor = now
        for item in items {
            if let date = item.lastPlayedDate {
                if let previous = lastSeen[item.id], date.timeIntervalSince1970 <= previous {
                    // Unchanged.
                } else {
                    plays.append(DetectedPlay(scrobble: scrobble(item, at: date), source: .poll))
                }
                cursor = min(cursor, date)
            } else if lastSeen[item.id] == nil {
                let start = cursor.addingTimeInterval(-Double(item.durationSec ?? assumedDurationSec))
                plays.append(DetectedPlay(scrobble: scrobble(item, at: start), source: .inferred))
                cursor = start
            }
        }
        return Result(plays: plays, lastSeen: updated)
    }

    private static func scrobble(_ item: RecentPlay, at date: Date) -> Scrobble {
        Scrobble(artist: item.artist, track: item.title, album: item.album,
                 durationSec: item.durationSec, listenedAt: date)
    }
}

/// Recently Played covers every device on the Apple ID and doesn't say which
/// device played what. This drops plays that already appear in the user's
/// scrobble history (ListenBrainz, or this device's own exact plays), which
/// means another capture path already has them. Plays from devices that
/// don't scrobble (HomePod, Apple TV) can't be told apart and are kept.
///
/// How close counts as "the same play" depends on how sure the time is:
/// - A dated play (`.poll`) matches a listen within `window` of its date.
/// - An undated play (`.inferred`) only has an estimated time. All that's
///   certain is that Apple listed it some time after the previous check,
///   and Apple can list plays hours late. So it matches any listen of the
///   same track from `appleListingLag` before the previous check until now.
///   The cost: replaying a song on a device that doesn't scrobble within
///   that span of scrobbling it elsewhere counts once.
public enum OtherDeviceFilter {
    public static let window: TimeInterval = 15 * 60
    /// How late Apple can list a play in Recently Played.
    public static let appleListingLag: TimeInterval = 2 * 60 * 60

    /// The earliest listen time worth fetching to filter `plays`.
    public static func historyStart(for plays: [DetectedPlay], previousCheck: Date?) -> Date? {
        plays.map { earliestMatch(for: $0, previousCheck: previousCheck) }.min()
    }

    public static func removingAlreadyScrobbled(
        _ plays: [DetectedPlay], history: [Scrobble], previousCheck: Date?, now: Date
    ) -> [DetectedPlay] {
        plays.filter { !isAlreadyScrobbled($0, history: history, previousCheck: previousCheck, now: now) }
    }

    public static func isAlreadyScrobbled(
        _ play: DetectedPlay, history: [Scrobble], previousCheck: Date?, now: Date
    ) -> Bool {
        let artist = MusicBrainzClient.normalize(play.scrobble.artist)
        let track = MusicBrainzClient.normalize(play.scrobble.track)
        let earliest = earliestMatch(for: play, previousCheck: previousCheck)
        let latest = play.source == .inferred ? now : play.scrobble.listenedAt.addingTimeInterval(window)
        return history.contains { listen in
            listen.listenedAt >= earliest && listen.listenedAt <= latest
                && MusicBrainzClient.normalize(listen.artist) == artist
                && MusicBrainzClient.normalize(listen.track) == track
        }
    }

    private static func earliestMatch(for play: DetectedPlay, previousCheck: Date?) -> Date {
        guard play.source == .inferred else { return play.scrobble.listenedAt.addingTimeInterval(-window) }
        let anchor = min(previousCheck ?? play.scrobble.listenedAt, play.scrobble.listenedAt)
        return anchor.addingTimeInterval(-appleListingLag)
    }

    /// 0.1.0's check: every play matched within `window` of its time.
    public static func removingAlreadyScrobbled(_ plays: [Scrobble], history: [Scrobble]) -> [Scrobble] {
        plays.filter { play in
            let artist = MusicBrainzClient.normalize(play.artist)
            let track = MusicBrainzClient.normalize(play.track)
            return !history.contains { listen in
                abs(listen.listenedAt.timeIntervalSince(play.listenedAt)) <= window
                    && MusicBrainzClient.normalize(listen.artist) == artist
                    && MusicBrainzClient.normalize(listen.track) == track
            }
        }
    }
}
