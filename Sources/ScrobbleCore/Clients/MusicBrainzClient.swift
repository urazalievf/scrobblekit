import Foundation

/// A MusicBrainz recording that matched a play.
public struct MusicBrainzMatch: Sendable, Equatable {
    public let recordingMBID: String
    /// A release with the same title as the play's album, when the matched
    /// recording lists one. MusicBrainz often has several releases with that
    /// title (CD, vinyl, digital); this is the first one listed.
    public let releaseMBID: String?

    public init(recordingMBID: String, releaseMBID: String?) {
        self.recordingMBID = recordingMBID
        self.releaseMBID = releaseMBID
    }
}

public enum MusicBrainzError: Error, Equatable {
    /// A non-2xx response. MusicBrainz answers 503 when rate limited.
    case httpStatus(Int)
    /// A 2xx response whose body didn't have the expected shape.
    case unexpectedResponse
}

/// Searches MusicBrainz for the recording behind a play.
///
/// Requests start at least one second apart, which is MusicBrainz's limit.
/// Each request reserves its start time inside the actor before awaiting, so
/// concurrent callers queue in order like a serial queue.
///
/// Matching favours precision. A wrong recording MBID is worse than none,
/// because ListenBrainz trusts a submitted MBID over its own matching. A
/// candidate counts only when its title and artist equal the play's (ignoring
/// case, accents and typographic punctuation) and its length is within 10
/// seconds of the play's duration, when both are known.
public actor MusicBrainzClient {
    public static let userAgent = "ScrobbleKit/\(ScrobbleCore.version) ( https://feruzurazaliev.com )"
    public static let minimumInterval: TimeInterval = 1
    /// The top hit is often a variant ("… (instrumental)", a live take), so a
    /// page of candidates is fetched and filtered.
    static let candidateLimit = 25
    static let durationTolerance: TimeInterval = 10

    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var nextSlot = Date.distantPast

    public init(transport: any HTTPTransport = URLSession.shared) {
        self.init(
            transport: transport,
            now: { Date() },
            sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        )
    }

    init(
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    /// Returns the best exact match, or nil when no candidate qualifies.
    public func searchRecording(
        artist: String, track: String, album: String?, durationSec: Int?
    ) async throws -> MusicBrainzMatch? {
        var request = URLRequest(url: Self.searchURL(artist: artist, track: track, album: album))
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        try await waitForTurn()
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MusicBrainzError.httpStatus(response.statusCode)
        }
        guard let body = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw MusicBrainzError.unexpectedResponse
        }
        return Self.bestMatch(in: body.recordings, artist: artist, track: track, album: album, durationSec: durationSec)
    }

    /// Reserves the next start slot synchronously (no await between reading
    /// and updating `nextSlot`), then sleeps until it arrives.
    private func waitForTurn() async throws {
        let current = now()
        let slot = max(current, nextSlot)
        nextSlot = slot.addingTimeInterval(Self.minimumInterval)
        let wait = slot.timeIntervalSince(current)
        if wait > 0 {
            try await sleep(wait)
        }
    }

    // MARK: Query

    /// `artist:"…" AND recording:"…"`, plus an optional `release:"…"` term
    /// when the album is known. Without AND, the release term only boosts
    /// ranking, so an album name MusicBrainz doesn't have can't hide the match.
    static func searchURL(artist: String, track: String, album: String?) -> URL {
        var query = "artist:\(phrase(artist)) AND recording:\(phrase(stripFeaturing(track)))"
        if let album, case let cleaned = cleanAlbum(album), !cleaned.isEmpty {
            query += " release:\(phrase(cleaned))"
        }
        let encoded = query.percentEncodedUnreserved
        return URL(string: "https://musicbrainz.org/ws/2/recording/?query=\(encoded)&fmt=json&limit=\(candidateLimit)")!
    }

    /// A Lucene phrase: quoted, with backslashes and quotes escaped.
    private static func phrase(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Removes Apple's " - Single" / " - EP" suffix and trailing (…) or […]
    /// groups such as "(Deluxe Edition)". Keeps the original if nothing
    /// would be left.
    static func cleanAlbum(_ album: String) -> String {
        let cleaned = album
            .replacingOccurrences(of: #"\s+-\s+(Single|EP)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(\s*(\([^()]*\)|\[[^\[\]]*\]))+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? album : cleaned
    }

    /// Removes a trailing "(feat. …)", "(ft. …)" or "(featuring …)" group,
    /// which Apple puts in titles and MusicBrainz puts in the artist credit.
    static func stripFeaturing(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*[\(\[](feat\.|ft\.|featuring)\s[^\)\]]*[\)\]]\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // MARK: Matching

    static func bestMatch(
        in recordings: [Recording], artist: String, track: String, album: String?, durationSec: Int?
    ) -> MusicBrainzMatch? {
        let wantedTitle = normalize(stripFeaturing(track))
        let wantedArtist = normalize(artist)

        let candidates = recordings.filter { recording in
            guard normalize(recording.title) == wantedTitle else { return false }

            let credits = recording.artistCredit ?? []
            let fullCredit = credits.map { $0.name + ($0.joinphrase ?? "") }.joined()
            let firstArtist = credits.first?.name ?? ""
            guard normalize(fullCredit) == wantedArtist || normalize(firstArtist) == wantedArtist else { return false }

            if let durationSec, let length = recording.length {
                return abs(Double(length) / 1000 - Double(durationSec)) <= durationTolerance
            }
            return true
        }

        if let album {
            let wantedAlbum = normalize(cleanAlbum(album))
            for recording in candidates {
                if let release = recording.releases?.first(where: { normalize($0.title) == wantedAlbum }) {
                    return MusicBrainzMatch(recordingMBID: recording.id, releaseMBID: release.id)
                }
            }
        }
        return candidates.first.map { MusicBrainzMatch(recordingMBID: $0.id, releaseMBID: nil) }
    }

    /// Folds case, accents and width, maps typographic quotes and dashes to
    /// ASCII, and collapses whitespace.
    static func normalize(_ string: String) -> String {
        var folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        for (typographic, ascii) in [("’", "'"), ("‘", "'"), ("ʼ", "'"), ("“", "\""), ("”", "\""),
                                     ("‐", "-"), ("‑", "-"), ("–", "-"), ("—", "-"), ("…", "...")] {
            folded = folded.replacingOccurrences(of: typographic, with: ascii)
        }
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Response body

    struct SearchResponse: Decodable {
        let recordings: [Recording]
    }

    struct Recording: Decodable {
        struct Credit: Decodable {
            let name: String
            let joinphrase: String?
        }

        struct Release: Decodable {
            let id: String
            let title: String
        }

        let id: String
        let title: String
        /// Milliseconds; missing for some recordings.
        let length: Int?
        let artistCredit: [Credit]?
        let releases: [Release]?

        enum CodingKeys: String, CodingKey {
            case id, title, length, releases
            case artistCredit = "artist-credit"
        }
    }
}
