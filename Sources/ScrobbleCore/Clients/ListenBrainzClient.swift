import Foundation

public enum ListenType: String, Sendable {
    /// Exactly one listen that just finished.
    case single
    /// Exactly one track that is playing right now. Sent without a timestamp.
    case playingNow = "playing_now"
    /// One or more past listens, up to 1000 per request.
    case `import`
}

public enum ListenBrainzError: Error, Equatable {
    /// 401: the token is missing or invalid. The user must paste a new one.
    case invalidToken
    /// 429. `retryAfter` is the number of seconds to wait, read from
    /// `Retry-After` or, failing that, `X-RateLimit-Reset-In`; nil when the
    /// response carried neither.
    case rateLimited(retryAfter: TimeInterval?)
    /// 400: ListenBrainz rejected the payload. Resending it unchanged won't help.
    case badRequest(message: String)
    /// Any other non-2xx response.
    case httpStatus(Int)
    /// A 2xx response whose body didn't have the expected shape.
    case unexpectedResponse
    /// `single` and `playing_now` take exactly one listen; `import` takes 1 to 1000.
    case invalidListenCount(ListenType, Int)
}

/// ListenBrainz API client for submitting listens and validating user tokens.
///
/// The client doesn't sleep and retry on 429. It throws `rateLimited` with the
/// delay so the caller can schedule the retry.
public struct ListenBrainzClient: Sendable {
    public static let baseURL = URL(string: "https://api.listenbrainz.org/1/")!
    public static let maxListensPerImport = 1000

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    /// POST /1/submit-listens. Album becomes `release_name`; the recording
    /// MBID, the track length (`duration_ms`) and the time actually played
    /// (`duration_played`, seconds) are sent only when known. `listened_at`
    /// is whole Unix seconds (UTC) and is left out for `playingNow`, which
    /// never carries a played time.
    public func submit(_ scrobbles: [Scrobble], as listenType: ListenType, token: String) async throws {
        let allowed = listenType == .import ? 1...Self.maxListensPerImport : 1...1
        guard allowed.contains(scrobbles.count) else {
            throw ListenBrainzError.invalidListenCount(listenType, scrobbles.count)
        }

        let body = SubmitBody(
            listenType: listenType.rawValue,
            payload: scrobbles.map { scrobble in
                Listen(
                    listenedAt: listenType == .playingNow ? nil : Int(scrobble.listenedAt.timeIntervalSince1970),
                    trackMetadata: TrackMetadata(
                        artistName: scrobble.artist,
                        trackName: scrobble.track,
                        releaseName: scrobble.album.nonEmpty,
                        additionalInfo: AdditionalInfo(
                            recordingMbid: scrobble.recordingMBID.nonEmpty,
                            durationMs: scrobble.durationSec.flatMap(Self.durationMs),
                            durationPlayed: listenType == .playingNow ? nil : scrobble.playedSec.flatMap(Self.playedSeconds)
                        )
                    )
                )
            }
        )

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("submit-listens"))
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let data = try await send(request)
        guard (try? JSONDecoder().decode(StatusResponse.self, from: data))?.status == "ok" else {
            throw ListenBrainzError.unexpectedResponse
        }
    }

    /// GET /1/validate-token. Returns the account's user name when the token
    /// is valid, nil when it isn't.
    public func validateToken(_ token: String) async throws -> String? {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("validate-token"))
        request.httpMethod = "GET"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        do {
            data = try await send(request)
        } catch ListenBrainzError.invalidToken {
            // The docs say an invalid token gets 200 with "valid": false;
            // a 401 is treated the same way.
            return nil
        }

        guard let response = try? JSONDecoder().decode(ValidateTokenResponse.self, from: data) else {
            throw ListenBrainzError.unexpectedResponse
        }
        guard response.valid else { return nil }
        guard let userName = response.userName else { throw ListenBrainzError.unexpectedResponse }
        return userName
    }

    /// GET /1/user/{user}/listens: up to 100 of the user's listens at or after
    /// `since`, newest first. Public; no token needed.
    public func listens(user: String, since: Date) async throws -> [Scrobble] {
        try await listensPage(user: user, query: "min_ts=\(Int(since.timeIntervalSince1970))&count=100")
    }

    /// ListenBrainz rejects durations over 24 days.
    static let maxDurationSec = 24 * 24 * 60 * 60

    static func durationMs(_ seconds: Int) -> Int? {
        (1...maxDurationSec).contains(seconds) ? seconds * 1000 : nil
    }

    static func playedSeconds(_ seconds: Int) -> Int? {
        (1...maxDurationSec).contains(seconds) ? seconds : nil
    }

    /// Most listens one `/listens` request returns.
    public static let maxListensPerGet = 1000

    /// The user's listens with `from <= listened_at <= to`, newest first, at
    /// most `limit`. Public; no token needed. Pages backwards with `max_ts`.
    public func listens(user: String, from: Date, to: Date, limit: Int = maxListensPerGet) async throws -> [Scrobble] {
        var result: [Scrobble] = []
        var maxTs = Int(to.timeIntervalSince1970) + 1
        while result.count < limit {
            let count = min(Self.maxListensPerGet, limit - result.count)
            let page = try await listensPage(user: user, query: "max_ts=\(maxTs)&count=\(count)")
            result += page.filter { $0.listenedAt >= from }.prefix(limit - result.count)
            guard page.count == count, let oldest = page.last, oldest.listenedAt >= from else { break }
            let next = Int(oldest.listenedAt.timeIntervalSince1970)
            guard next < maxTs else { break }
            maxTs = next
        }
        return result
    }

    /// GET /1/stats/user/{user}/artists. Empty when ListenBrainz hasn't
    /// computed the statistics yet (204). Statistics update about once a day.
    public func topArtists(user: String, range: StatsRange, count: Int = 5) async throws -> [ArtistCount] {
        let data = try await get("stats/user/\(user.percentEncodedUnreserved)/artists?range=\(range.rawValue)&count=\(count)")
        guard !data.isEmpty else { return [] }
        guard let response = try? JSONDecoder().decode(ArtistStatsResponse.self, from: data) else {
            throw ListenBrainzError.unexpectedResponse
        }
        return response.payload.artists.map { ArtistCount(name: $0.artistName, listens: $0.listenCount) }
    }

    /// GET /1/stats/user/{user}/recordings. Empty when not computed yet (204).
    public func topTracks(user: String, range: StatsRange, count: Int = 5) async throws -> [TrackCount] {
        let data = try await get("stats/user/\(user.percentEncodedUnreserved)/recordings?range=\(range.rawValue)&count=\(count)")
        guard !data.isEmpty else { return [] }
        guard let response = try? JSONDecoder().decode(RecordingStatsResponse.self, from: data) else {
            throw ListenBrainzError.unexpectedResponse
        }
        return response.payload.recordings.map {
            TrackCount(track: $0.trackName, artist: $0.artistName, listens: $0.listenCount)
        }
    }

    /// GET /1/user/{user}/listen-count: every listen the account has.
    public func listenCount(user: String) async throws -> Int {
        let data = try await get("user/\(user.percentEncodedUnreserved)/listen-count")
        guard let response = try? JSONDecoder().decode(ListenCountResponse.self, from: data) else {
            throw ListenBrainzError.unexpectedResponse
        }
        return response.payload.count
    }

    /// POST /1/feedback/recording-feedback with score 1 ("love"). ListenBrainz
    /// needs the MusicBrainz recording, so only matched plays can be loved.
    public func love(recordingMBID: String, token: String) async throws {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("feedback/recording-feedback"))
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["recording_mbid": recordingMBID, "score": 1])
        let data = try await send(request)
        guard (try? JSONDecoder().decode(StatusResponse.self, from: data))?.status == "ok" else {
            throw ListenBrainzError.unexpectedResponse
        }
    }

    private func get(_ pathAndQuery: String) async throws -> Data {
        var request = URLRequest(url: URL(string: Self.baseURL.absoluteString + pathAndQuery)!)
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func listensPage(user: String, query: String) async throws -> [Scrobble] {
        let data = try await get("user/\(user.percentEncodedUnreserved)/listens?\(query)")
        guard let response = try? JSONDecoder().decode(ListensResponse.self, from: data) else {
            throw ListenBrainzError.unexpectedResponse
        }
        return response.payload.listens.map {
            Scrobble(
                artist: $0.trackMetadata.artistName, track: $0.trackMetadata.trackName,
                album: $0.trackMetadata.releaseName,
                listenedAt: Date(timeIntervalSince1970: TimeInterval($0.listenedAt))
            )
        }
    }

    /// Returns the body of a 2xx response and maps everything else to ListenBrainzError.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            return data
        case 400:
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error ?? ""
            throw ListenBrainzError.badRequest(message: message)
        case 401:
            throw ListenBrainzError.invalidToken
        case 429:
            throw ListenBrainzError.rateLimited(retryAfter: Self.retryDelay(from: response))
        default:
            throw ListenBrainzError.httpStatus(response.statusCode)
        }
    }

    /// Seconds to wait before retrying. `Retry-After` wins when present, as
    /// either seconds or an HTTP date (a past date gives 0). ListenBrainz
    /// documents `X-RateLimit-Reset-In` (seconds) instead, so that is the
    /// fallback.
    static func retryDelay(from response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        if let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) {
            if let seconds = TimeInterval(value), seconds >= 0 {
                return seconds
            }
            if let date = httpDate(value) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        if let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset-In"),
           let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return seconds
        }
        return nil
    }

    /// Parses the IMF-fixdate form, e.g. "Wed, 21 Oct 2015 07:28:00 GMT".
    private static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}

private extension Optional where Wrapped == String {
    /// nil for nil or "", so empty fields are left out of the JSON.
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

// MARK: - Request and response bodies
// Keys are converted to snake_case on encoding (artistName -> artist_name).

private struct SubmitBody: Encodable {
    let listenType: String
    let payload: [Listen]
}

private struct Listen: Encodable {
    let listenedAt: Int?
    let trackMetadata: TrackMetadata
}

private struct TrackMetadata: Encodable {
    let artistName: String
    let trackName: String
    let releaseName: String?
    let additionalInfo: AdditionalInfo
}

private struct AdditionalInfo: Encodable {
    let submissionClient = "ScrobbleKit"
    let submissionClientVersion = ScrobbleCore.version
    let musicService = "music.apple.com"
    let recordingMbid: String?
    /// The track's length.
    let durationMs: Int?
    /// How long the user actually listened, in seconds.
    let durationPlayed: Int?
}

private struct StatusResponse: Decodable {
    let status: String
}

private struct ErrorResponse: Decodable {
    let error: String
}

private struct ValidateTokenResponse: Decodable {
    let valid: Bool
    let userName: String?

    enum CodingKeys: String, CodingKey {
        case valid
        case userName = "user_name"
    }
}

private struct ListensResponse: Decodable {
    struct Payload: Decodable {
        let listens: [Item]
    }

    struct Item: Decodable {
        struct Metadata: Decodable {
            let artistName: String
            let trackName: String
            let releaseName: String?

            enum CodingKeys: String, CodingKey {
                case artistName = "artist_name"
                case trackName = "track_name"
                case releaseName = "release_name"
            }
        }

        let listenedAt: Int
        let trackMetadata: Metadata

        enum CodingKeys: String, CodingKey {
            case listenedAt = "listened_at"
            case trackMetadata = "track_metadata"
        }
    }

    let payload: Payload
}

private struct ArtistStatsResponse: Decodable {
    struct Payload: Decodable {
        let artists: [Artist]
    }

    struct Artist: Decodable {
        let artistName: String
        let listenCount: Int

        enum CodingKeys: String, CodingKey {
            case artistName = "artist_name"
            case listenCount = "listen_count"
        }
    }

    let payload: Payload
}

private struct RecordingStatsResponse: Decodable {
    struct Payload: Decodable {
        let recordings: [Recording]
    }

    struct Recording: Decodable {
        let trackName: String
        let artistName: String
        let listenCount: Int

        enum CodingKeys: String, CodingKey {
            case trackName = "track_name"
            case artistName = "artist_name"
            case listenCount = "listen_count"
        }
    }

    let payload: Payload
}

private struct ListenCountResponse: Decodable {
    struct Payload: Decodable {
        let count: Int
    }

    let payload: Payload
}
