import Foundation

/// One play of a track: what the API clients send. Now-playing updates use the
/// same type and ignore `listenedAt`.
public struct Scrobble: Sendable, Equatable {
    public var artist: String
    public var track: String
    public var album: String?
    public var albumArtist: String?
    public var durationSec: Int?
    public var listenedAt: Date
    public var recordingMBID: String?

    public init(
        artist: String,
        track: String,
        album: String? = nil,
        albumArtist: String? = nil,
        durationSec: Int? = nil,
        listenedAt: Date,
        recordingMBID: String? = nil
    ) {
        self.artist = artist
        self.track = track
        self.album = album
        self.albumArtist = albumArtist
        self.durationSec = durationSec
        self.listenedAt = listenedAt
        self.recordingMBID = recordingMBID
    }
}
