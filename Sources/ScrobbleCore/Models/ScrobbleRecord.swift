import Foundation
import SwiftData

/// Which capture path recorded a play.
public enum ScrobbleSource: String, Codable, Sendable, CaseIterable {
    /// iOS app in the foreground, from the system music player's notifications.
    case foreground
    /// iOS Recently Played poll, with a play date from the library.
    case poll
    /// iOS Recently Played poll without a play date; the time is estimated.
    case inferred
    /// Added by hand.
    case manual
    /// Mac app, from Music.app's playerInfo notifications.
    case mac
    /// iOS app, when no more specific source applies.
    case ios
}

/// One play waiting to be, or already, sent to Last.fm and ListenBrainz.
/// Each service has its own sent flag, so a partial success only retries the
/// service that failed.
@Model
public final class ScrobbleRecord {
    @Attribute(.unique) public var id: UUID
    /// `Dedup.key` of artist, track and listen minute. Not unique on purpose:
    /// a unique attribute would make SwiftData overwrite the existing row
    /// instead of letting `Dedup` merge into it.
    public private(set) var dedupKey: String
    public var artist: String
    public var track: String
    public var album: String?
    public var albumArtist: String?
    public var recordingMBID: String?
    public var releaseMBID: String?
    public var listenedAt: Date
    /// 0 when unknown.
    public var durationSec: Int
    public var source: ScrobbleSource
    public var lastfmSent: Bool
    public var listenbrainzSent: Bool
    /// Failed send attempts, counted across both services.
    public var attempts: Int
    public var lastError: String?
    /// When `RetryPolicy` allows the next attempt; nil if never failed.
    public var nextAttemptAt: Date?
    public var createdAt: Date
    public var permanentlyFailed: Bool

    public init(_ scrobble: Scrobble, source: ScrobbleSource, createdAt: Date = Date()) {
        id = UUID()
        dedupKey = Dedup.key(artist: scrobble.artist, track: scrobble.track, listenedAt: scrobble.listenedAt)
        artist = scrobble.artist
        track = scrobble.track
        album = scrobble.album
        albumArtist = scrobble.albumArtist
        recordingMBID = scrobble.recordingMBID
        releaseMBID = nil
        listenedAt = scrobble.listenedAt
        durationSec = scrobble.durationSec ?? 0
        self.source = source
        lastfmSent = false
        listenbrainzSent = false
        attempts = 0
        lastError = nil
        nextAttemptAt = nil
        self.createdAt = createdAt
        permanentlyFailed = false
    }

    /// The play as the API clients send it. A stored duration of 0 becomes nil.
    public var scrobble: Scrobble {
        Scrobble(
            artist: artist, track: track, album: album, albumArtist: albumArtist,
            durationSec: durationSec > 0 ? durationSec : nil,
            listenedAt: listenedAt, recordingMBID: recordingMBID
        )
    }

    /// True once both services have accepted the play.
    public var isFullySent: Bool { lastfmSent && listenbrainzSent }
}
