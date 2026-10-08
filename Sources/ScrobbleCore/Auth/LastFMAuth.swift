import Foundation

/// Last.fm web login: open `authorizationURL` in a browser, Last.fm redirects
/// to `scrobblekit://lastfm-callback?token=…`, and `completeLogin` exchanges
/// the token for a session key. The session key and user name are kept in
/// the Keychain.
public struct LastFMAuth: Sendable {
    public static let callbackScheme = "scrobblekit"
    public static let callbackHost = "lastfm-callback"

    private let client: LastFMClient
    private let keychain: KeychainStore

    public init(client: LastFMClient, keychain: KeychainStore = KeychainStore()) {
        self.client = client
        self.keychain = keychain
    }

    public static func authorizationURL(apiKey: String) -> URL {
        URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey.percentEncodedUnreserved)"
            + "&cb=\(callbackScheme)://\(callbackHost)")!
    }

    /// The token from a login callback URL, or nil if the URL isn't one.
    public static func token(from url: URL) -> String? {
        guard url.scheme == callbackScheme, url.host == callbackHost else { return nil }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "token" }?.value
        return token?.isEmpty == false ? token : nil
    }

    @discardableResult
    public func completeLogin(token: String) async throws -> LastFMSession {
        let session = try await client.getSession(token: token)
        try keychain.setString(session.key, service: .lastfm, account: Account.sessionKey)
        try keychain.setString(session.username, service: .lastfm, account: Account.username)
        Log.auth.info("Logged in to Last.fm as \(session.username, privacy: .public)")
        return session
    }

    public var sessionKey: String? { try? keychain.getString(service: .lastfm, account: Account.sessionKey) }
    public var username: String? { try? keychain.getString(service: .lastfm, account: Account.username) }

    public func logOut() {
        try? keychain.delete(service: .lastfm, account: Account.sessionKey)
        try? keychain.delete(service: .lastfm, account: Account.username)
    }

    private enum Account {
        static let sessionKey = "sessionKey"
        static let username = "username"
    }
}
