import Foundation

/// The track a player reports, reduced to what scrobbling needs.
public struct PlayingTrack: Sendable, Equatable {
    /// Stable per track: a persistent or store ID, or `fallbackID` when the
    /// player gives neither (Apple Music Radio).
    public var id: String
    public var artist: String
    public var title: String
    public var album: String?
    public var albumArtist: String?
    public var durationSec: Int?
    public var isPodcast: Bool

    public init(
        id: String, artist: String, title: String, album: String? = nil, albumArtist: String? = nil,
        durationSec: Int? = nil, isPodcast: Bool = false
    ) {
        self.id = id
        self.artist = artist
        self.title = title
        self.album = album
        self.albumArtist = albumArtist
        self.durationSec = durationSec
        self.isPodcast = isPodcast
    }

    /// Identifies a track by artist and title when there's no store ID.
    public static func fallbackID(artist: String, title: String) -> String {
        "\(artist)|\(title)".lowercased()
    }
}

public enum PlayerState: Sendable {
    case playing, paused, stopped
}

/// Turns player state changes into now-playing updates and scrobbles. The Mac
/// and iOS apps both use it.
///
/// Play time is wall-clock time spent in `.playing`, or the furthest player
/// position reported, whichever is larger; scrubbing to the end therefore
/// counts as played. A track scrobbles once, as soon as it qualifies:
/// longer than 30 seconds and played for half its length or 4 minutes,
/// whichever comes first. With no known length, 4 minutes. Podcasts never
/// scrobble. The scrobble's time is when the track started.
public struct PlaybackTracker: Sendable {
    public enum Event: Sendable, Equatable {
        /// The track that just started playing.
        case nowPlaying(Scrobble)
        /// A play that has qualified.
        case scrobble(Scrobble)
    }

    public static let minimumDuration = 30
    public static let maximumRequiredPlay: TimeInterval = 4 * 60
    public static let longTrackWarning = 30 * 60

    private var current: PlayingTrack?
    private var startedAt = Date.distantPast
    private var accumulated: TimeInterval = 0
    private var playingSince: Date?
    private var furthestPosition: TimeInterval = 0
    private var announced = false
    private var scrobbled = false

    public init() {}

    public var currentTrack: PlayingTrack? { current }
    public var isPlaying: Bool { playingSince != nil }

    /// Feed every player notification. `track` nil means nothing is loaded.
    public mutating func handle(
        track: PlayingTrack?, state: PlayerState, position: TimeInterval? = nil, at now: Date
    ) -> [Event] {
        var events: [Event] = []

        if track?.id != current?.id {
            events += finish(at: now)
            if let track, state != .stopped {
                begin(track, playing: state == .playing, at: now)
                events += announceIfNeeded()
            }
            return events
        }
        guard current != nil else { return [] }

        switch state {
        case .playing:
            if playingSince == nil { playingSince = now }
            events += announceIfNeeded()
        case .paused:
            pause(at: now)
        case .stopped:
            return finish(at: now)
        }
        if let position { furthestPosition = max(furthestPosition, position) }
        return events + evaluate(at: now)
    }

    /// Call periodically while playing so a scrobble fires as soon as the
    /// track qualifies rather than when it ends.
    public mutating func tick(position: TimeInterval? = nil, at now: Date) -> [Event] {
        guard current != nil else { return [] }
        if let position { furthestPosition = max(furthestPosition, position) }
        return evaluate(at: now)
    }

    private mutating func begin(_ track: PlayingTrack, playing: Bool, at now: Date) {
        current = track
        startedAt = now
        accumulated = 0
        furthestPosition = 0
        playingSince = playing ? now : nil
        announced = false
        scrobbled = false
    }

    private mutating func pause(at now: Date) {
        if let since = playingSince {
            accumulated += max(0, now.timeIntervalSince(since))
        }
        playingSince = nil
    }

    private mutating func finish(at now: Date) -> [Event] {
        guard current != nil else { return [] }
        pause(at: now)
        let events = evaluate(at: now)
        current = nil
        return events
    }

    private mutating func announceIfNeeded() -> [Event] {
        guard let track = current, !announced, playingSince != nil, !track.isPodcast else { return [] }
        announced = true
        return [.nowPlaying(scrobble(for: track))]
    }

    private mutating func evaluate(at now: Date) -> [Event] {
        guard let track = current, !scrobbled, !track.isPodcast else { return [] }

        let wallClock = accumulated + (playingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        let played = max(wallClock, furthestPosition)

        let required: TimeInterval
        if let duration = track.durationSec, duration > 0 {
            guard duration > Self.minimumDuration else { return [] }
            required = min(Double(duration) / 2, Self.maximumRequiredPlay)
        } else {
            required = Self.maximumRequiredPlay
        }
        guard played >= required else { return [] }

        if let duration = track.durationSec, duration > Self.longTrackWarning {
            Log.capture.warning("Scrobbling a \(duration)s track (over 30 minutes): \(track.title, privacy: .public)")
        }
        scrobbled = true
        return [.scrobble(scrobble(for: track))]
    }

    private func scrobble(for track: PlayingTrack) -> Scrobble {
        Scrobble(
            artist: track.artist, track: track.title, album: track.album, albumArtist: track.albumArtist,
            durationSec: track.durationSec, listenedAt: startedAt
        )
    }
}
