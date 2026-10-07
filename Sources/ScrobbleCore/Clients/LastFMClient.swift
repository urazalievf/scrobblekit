import Foundation

public struct LastFMSession: Sendable, Equatable {
    public let username: String
    public let key: String

    public init(username: String, key: String) {
        self.username = username
        self.key = key
    }
}

/// What Last.fm reported for one `track.scrobble` batch.
public struct LastFMScrobbleResult: Sendable, Equatable {
    public let accepted: Int
    public let ignored: Int
    /// One entry per scrobble, in the order Last.fm lists them: 0 when
    /// accepted, otherwise Last.fm's ignored-message code (for example 3 =
    /// timestamp too old, 5 = daily scrobble limit exceeded).
    public let ignoredCodes: [Int]

    public init(accepted: Int, ignored: Int, ignoredCodes: [Int]) {
        self.accepted = accepted
        self.ignored = ignored
        self.ignoredCodes = ignoredCodes
    }
}

public enum LastFMError: Error, Equatable {
    /// Error 9: the session key is no longer valid. The user must log in again.
    case invalidSession
    /// Error 11: Last.fm is offline. Try again later.
    case serviceOffline
    /// Error 16: a temporary error on Last.fm's side. Try again later.
    case temporaryError
    /// Error 29: rate limit exceeded.
    case rateLimitExceeded
    /// Any other Last.fm error code.
    case api(code: Int, message: String)
    /// A non-2xx response with no Last.fm error body.
    case httpStatus(Int)
    /// A 2xx response whose body didn't have the expected shape.
    case unexpectedResponse
    /// `track.scrobble` takes 1 to 50 scrobbles per request.
    case invalidBatchSize(Int)

    init(code: Int, message: String) {
        switch code {
        case 9: self = .invalidSession
        case 11: self = .serviceOffline
        case 16: self = .temporaryError
        case 29: self = .rateLimitExceeded
        default: self = .api(code: code, message: message)
        }
    }
}

/// Last.fm API 2.0 client. Every call is a signed, form-urlencoded POST with
/// `format=json`.
public struct LastFMClient: Sendable {
    public static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    public static let maxBatchSize = 50

    private let apiKey: String
    private let sharedSecret: String
    private let transport: any HTTPTransport

    public init(apiKey: String, sharedSecret: String, transport: any HTTPTransport = URLSession.shared) {
        self.apiKey = apiKey
        self.sharedSecret = sharedSecret
        self.transport = transport
    }

    /// Exchanges the token from the web login callback for a session key.
    public func getSession(token: String) async throws -> LastFMSession {
        let data = try await call("auth.getSession", ["token": token], sessionKey: nil)
        guard let response = try? JSONDecoder().decode(SessionResponse.self, from: data) else {
            throw LastFMError.unexpectedResponse
        }
        return LastFMSession(username: response.session.name, key: response.session.key)
    }

    /// Ignores `track.listenedAt`. Succeeds on any 2xx response without a
    /// Last.fm error body; the response content isn't checked.
    public func updateNowPlaying(_ track: Scrobble, sessionKey: String) async throws {
        var parameters = ["artist": track.artist, "track": track.track]
        parameters.addIfPresent("album", track.album)
        parameters.addIfPresent("albumArtist", track.albumArtist)
        parameters.addIfPresent("duration", track.durationSec.map(String.init))
        parameters.addIfPresent("mbid", track.recordingMBID)
        _ = try await call("track.updateNowPlaying", parameters, sessionKey: sessionKey)
    }

    /// Submits 1 to 50 scrobbles in one request. Timestamps are sent as whole
    /// Unix seconds (UTC).
    public func scrobble(_ scrobbles: [Scrobble], sessionKey: String) async throws -> LastFMScrobbleResult {
        guard (1...Self.maxBatchSize).contains(scrobbles.count) else {
            throw LastFMError.invalidBatchSize(scrobbles.count)
        }

        var parameters: [String: String] = [:]
        for (index, scrobble) in scrobbles.enumerated() {
            parameters["artist[\(index)]"] = scrobble.artist
            parameters["track[\(index)]"] = scrobble.track
            parameters["timestamp[\(index)]"] = String(Int(scrobble.listenedAt.timeIntervalSince1970))
            parameters.addIfPresent("album[\(index)]", scrobble.album)
            parameters.addIfPresent("albumArtist[\(index)]", scrobble.albumArtist)
            parameters.addIfPresent("duration[\(index)]", scrobble.durationSec.map(String.init))
            parameters.addIfPresent("mbid[\(index)]", scrobble.recordingMBID)
        }

        let data = try await call("track.scrobble", parameters, sessionKey: sessionKey)
        guard let response = try? JSONDecoder().decode(ScrobbleResponse.self, from: data) else {
            throw LastFMError.unexpectedResponse
        }
        let body = response.scrobbles
        return LastFMScrobbleResult(
            accepted: body.attr.accepted.value,
            ignored: body.attr.ignored.value,
            ignoredCodes: body.scrobble.values.map(\.ignoredMessage.code.value)
        )
    }

    /// Adds method, api_key, sk (if given), api_sig and format, sends the
    /// request, and returns the body of a successful response.
    private func call(_ method: String, _ parameters: [String: String], sessionKey: String?) async throws -> Data {
        var parameters = parameters
        parameters["method"] = method
        parameters["api_key"] = apiKey
        if let sessionKey { parameters["sk"] = sessionKey }
        parameters["api_sig"] = Signature.lastFM(parameters, secret: sharedSecret)
        parameters["format"] = "json"

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(parameters).utf8)

        let (data, response) = try await transport.send(request)
        // Last.fm sends error bodies with 4xx/5xx and sometimes with 200.
        if let error = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            throw LastFMError(code: error.error.value, message: error.message ?? "")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw LastFMError.httpStatus(response.statusCode)
        }
        return data
    }

    static func formEncode(_ parameters: [String: String]) -> String {
        parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key.percentEncodedUnreserved)=\($0.value.percentEncodedUnreserved)" }
            .joined(separator: "&")
    }
}

private extension Dictionary where Key == String, Value == String {
    /// Leaves out nil and empty values instead of sending empty fields.
    mutating func addIfPresent(_ key: String, _ value: String?) {
        if let value, !value.isEmpty { self[key] = value }
    }
}

// MARK: - Response bodies

private struct ErrorResponse: Decodable {
    let error: LenientInt
    let message: String?
}

private struct SessionResponse: Decodable {
    struct Session: Decodable {
        let name: String
        let key: String
    }

    let session: Session
}

private struct ScrobbleResponse: Decodable {
    struct Body: Decodable {
        struct Attr: Decodable {
            let accepted: LenientInt
            let ignored: LenientInt
        }

        struct Item: Decodable {
            struct IgnoredMessage: Decodable {
                let code: LenientInt
            }

            let ignoredMessage: IgnoredMessage
        }

        let attr: Attr
        let scrobble: OneOrMany<Item>

        enum CodingKeys: String, CodingKey {
            case attr = "@attr"
            case scrobble
        }
    }

    let scrobbles: Body
}

/// Last.fm's JSON sends some integers as strings ("0").
private struct LenientInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let int = Int(try container.decode(String.self)) {
            value = int
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an integer")
        }
    }
}

/// Last.fm's JSON sends a lone object where a one-element array is expected.
private struct OneOrMany<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([Element].self) {
            values = many
        } else {
            values = [try container.decode(Element.self)]
        }
    }
}
