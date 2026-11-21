import Foundation

public struct ArtistCount: Sendable, Equatable, Codable {
    public var name: String
    public var listens: Int

    public init(name: String, listens: Int) {
        self.name = name
        self.listens = listens
    }
}

public struct TrackCount: Sendable, Equatable, Codable {
    public var track: String
    public var artist: String
    public var listens: Int

    public init(track: String, artist: String, listens: Int) {
        self.track = track
        self.artist = artist
        self.listens = listens
    }
}

/// The periods ListenBrainz keeps statistics for, as ScrobbleKit offers them.
public enum StatsRange: String, CaseIterable, Sendable, Codable {
    case thisWeek = "this_week"
    case thisMonth = "this_month"
    case thisYear = "this_year"
    case allTime = "all_time"

    /// "this week", "this month", "this year", "of all time".
    public var phrase: String {
        switch self {
        case .thisWeek: "this week"
        case .thisMonth: "this month"
        case .thisYear: "this year"
        case .allTime: "of all time"
        }
    }

    /// The start of the period in `calendar`, nil for all time.
    public func start(containing date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .thisWeek: calendar.dateInterval(of: .weekOfYear, for: date)?.start
        case .thisMonth: calendar.dateInterval(of: .month, for: date)?.start
        case .thisYear: calendar.dateInterval(of: .year, for: date)?.start
        case .allTime: nil
        }
    }
}

/// Counts over a list of plays: how many, the most played artists and
/// tracks, and the latest play. Used by the weekly recap, the Siri
/// questions and the history connector, whether the plays came from
/// ListenBrainz or from this device.
public struct ListeningSummary: Sendable, Equatable {
    public var plays: Int
    public var topArtists: [ArtistCount]
    public var topTracks: [TrackCount]
    public var latest: Scrobble?

    public init(plays: Int, topArtists: [ArtistCount], topTracks: [TrackCount], latest: Scrobble?) {
        self.plays = plays
        self.topArtists = topArtists
        self.topTracks = topTracks
        self.latest = latest
    }

    /// Names are grouped ignoring case, accents and curly quotes; each group
    /// shows the spelling of its most recent play. Ties keep the artist or
    /// track that was played most recently first.
    public static func make(_ scrobbles: [Scrobble], limit: Int = 5) -> ListeningSummary {
        let newestFirst = scrobbles.sorted { $0.listenedAt > $1.listenedAt }

        var artistOrder: [String] = []
        var artistNames: [String: String] = [:]
        var artistCounts: [String: Int] = [:]
        var trackOrder: [String] = []
        var trackNames: [String: (track: String, artist: String)] = [:]
        var trackCounts: [String: Int] = [:]

        for play in newestFirst {
            let artistKey = MusicBrainzClient.normalize(play.artist)
            if artistCounts[artistKey] == nil {
                artistOrder.append(artistKey)
                artistNames[artistKey] = play.artist
            }
            artistCounts[artistKey, default: 0] += 1

            let trackKey = artistKey + "|" + MusicBrainzClient.normalize(play.track)
            if trackCounts[trackKey] == nil {
                trackOrder.append(trackKey)
                trackNames[trackKey] = (play.track, play.artist)
            }
            trackCounts[trackKey, default: 0] += 1
        }

        let artists = artistOrder.enumerated()
            .sorted { (artistCounts[$0.element]!, -$0.offset) > (artistCounts[$1.element]!, -$1.offset) }
            .prefix(limit)
            .map { ArtistCount(name: artistNames[$0.element]!, listens: artistCounts[$0.element]!) }
        let tracks = trackOrder.enumerated()
            .sorted { (trackCounts[$0.element]!, -$0.offset) > (trackCounts[$1.element]!, -$1.offset) }
            .prefix(limit)
            .map {
                TrackCount(track: trackNames[$0.element]!.track, artist: trackNames[$0.element]!.artist,
                           listens: trackCounts[$0.element]!)
            }
        return ListeningSummary(plays: scrobbles.count, topArtists: artists, topTracks: tracks,
                                latest: newestFirst.first)
    }

    /// One or two plain sentences, e.g. "This week you played 312 tracks.
    /// Most played: Radiohead (40), Björk (31) and Low (20)."
    /// `period` is lowercase and fits "… you played" ("this week", "on Saturday").
    public func sentence(period: String) -> String {
        let opening = period.prefix(1).uppercased() + period.dropFirst()
        guard plays > 0 else { return "\(opening) you didn't play anything that was scrobbled." }
        var text = "\(opening) you played \(plays) \(plays == 1 ? "track" : "tracks")."
        if !topArtists.isEmpty {
            let names = topArtists.prefix(3).map { "\($0.name) (\($0.listens))" }
            text += " Most played: \(Self.list(names))."
        }
        return text
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}

extension Array where Element == ArtistCount {
    /// "Your top artists this month: A (40 plays), B (31) and C (20)."
    public func sentence(range: StatsRange) -> String {
        guard let first else { return "ListenBrainz has no top artists for you \(range.phrase) yet." }
        let rest = dropFirst().prefix(4).map { "\($0.name) (\($0.listens))" }
        let lead = "\(first.name) (\(first.listens) \(first.listens == 1 ? "play" : "plays"))"
        return "Your top artists \(range.phrase): \(ListeningSummary.list([lead] + rest))."
    }
}

extension Array where Element == TrackCount {
    /// "Your top tracks this week: Song by Artist (12 plays), …"
    public func sentence(range: StatsRange) -> String {
        guard let first else { return "ListenBrainz has no top tracks for you \(range.phrase) yet." }
        let rest = dropFirst().prefix(4).map { "\($0.track) by \($0.artist) (\($0.listens))" }
        let lead = "\(first.track) by \(first.artist) (\(first.listens) \(first.listens == 1 ? "play" : "plays"))"
        return "Your top tracks \(range.phrase): \(ListeningSummary.list([lead] + rest))."
    }
}
