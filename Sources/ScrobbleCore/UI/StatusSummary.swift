import Foundation

public enum StatusLevel: Sendable, Equatable {
    /// Green: everything connected has been sent.
    case good
    /// Yellow: plays are waiting or being retried, or a service isn't connected.
    case attention
    /// Red: needs the user (log in again, API key suspended, failed plays, or
    /// nothing connected).
    case problem
}

/// One line describing the app's state, for the menu bar and home screen.
public struct StatusSummary: Sendable, Equatable {
    public let level: StatusLevel
    public let headline: String

    public init(level: StatusLevel, headline: String) {
        self.level = level
        self.headline = headline
    }

    /// Checked in order of urgency; the first match wins.
    public static func make(
        status: QueueStatus, lastfmConnected: Bool, listenbrainzConnected: Bool, pending: Int, failed: Int
    ) -> StatusSummary {
        if status.lastfm == .suspended {
            return StatusSummary(level: .problem, headline: "Last.fm suspended this app's API key")
        }
        if status.lastfm == .needsLogin {
            return StatusSummary(level: .problem, headline: "Log in to Last.fm again")
        }
        if status.listenbrainz == .needsLogin {
            return StatusSummary(level: .problem, headline: "Paste a new ListenBrainz token")
        }
        if !lastfmConnected && !listenbrainzConnected {
            return StatusSummary(level: .problem, headline: "Connect Last.fm or ListenBrainz")
        }
        if failed > 0 {
            return StatusSummary(level: .problem, headline: failed == 1 ? "1 scrobble failed" : "\(failed) scrobbles failed")
        }
        if case .failing(let message) = status.lastfm {
            return StatusSummary(level: .attention, headline: "Retrying: \(message)")
        }
        if case .failing(let message) = status.listenbrainz {
            return StatusSummary(level: .attention, headline: "Retrying: \(message)")
        }
        if pending > 0 {
            return StatusSummary(level: .attention, headline: pending == 1 ? "1 scrobble waiting" : "\(pending) scrobbles waiting")
        }
        if !lastfmConnected {
            return StatusSummary(level: .attention, headline: "Last.fm not connected")
        }
        if !listenbrainzConnected {
            return StatusSummary(level: .attention, headline: "ListenBrainz not connected")
        }
        return StatusSummary(level: .good, headline: "All caught up")
    }
}

public enum CoverArt {
    /// Cover Art Archive's 250 px front image for a MusicBrainz release.
    public static func url(releaseMBID: String) -> URL? {
        URL(string: "https://coverartarchive.org/release/\(releaseMBID)/front-250")
    }
}

extension ServiceState {
    /// Short text for a settings row.
    public var label: String {
        switch self {
        case .unknown: "Connected"
        case .ok: "Working"
        case .notConnected: "Not connected"
        case .needsLogin: "Needs you to log in again"
        case .suspended: "API key suspended by Last.fm"
        case .failing(let message): message
        }
    }

    public var level: StatusLevel {
        switch self {
        case .unknown, .ok: .good
        case .notConnected, .failing: .attention
        case .needsLogin, .suspended: .problem
        }
    }
}
