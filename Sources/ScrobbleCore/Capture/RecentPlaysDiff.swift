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

    public init(id: String, artist: String, title: String, album: String?, durationSec: Int?, lastPlayedDate: Date?) {
        self.id = id
        self.artist = artist
        self.title = title
        self.album = album
        self.durationSec = durationSec
        self.lastPlayedDate = lastPlayedDate
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
/// scrobble history near the same time, which means another device (for
/// example ScrobbleKit on the Mac) already sent them. Plays from devices that
/// don't scrobble (HomePod, Apple TV) can't be told apart and are kept.
public enum OtherDeviceFilter {
    public static let window: TimeInterval = 15 * 60

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
