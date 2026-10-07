import Foundation

/// Sends one HTTP request. The API clients take this instead of URLSession so
/// tests can reply with canned responses and no network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

extension String {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Percent-encodes everything except RFC 3986 unreserved characters, so
    /// `&`, `=`, `+` and spaces in track names can't break a form body or
    /// query string.
    var percentEncodedUnreserved: String {
        // Only fails for strings that aren't valid Unicode, which a Swift String always is.
        addingPercentEncoding(withAllowedCharacters: Self.unreserved)!
    }
}
