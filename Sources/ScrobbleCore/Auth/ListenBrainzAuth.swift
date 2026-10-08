import Foundation

/// ListenBrainz uses a pasted user token (listenbrainz.org/settings). It's
/// validated before anything is stored; the token and user name are kept in
/// the Keychain.
public struct ListenBrainzAuth: Sendable {
    private let client: ListenBrainzClient
    private let keychain: KeychainStore

    public init(client: ListenBrainzClient = ListenBrainzClient(), keychain: KeychainStore = KeychainStore()) {
        self.client = client
        self.keychain = keychain
    }

    /// Validates and stores the token. Throws `ListenBrainzError.invalidToken`
    /// when ListenBrainz rejects it. Returns the user name.
    @discardableResult
    public func connect(token rawToken: String) async throws -> String {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let username = try await client.validateToken(token) else {
            throw ListenBrainzError.invalidToken
        }
        try keychain.setString(token, service: .listenbrainz, account: Account.token)
        try keychain.setString(username, service: .listenbrainz, account: Account.username)
        Log.auth.info("Connected ListenBrainz as \(username, privacy: .public)")
        return username
    }

    public var token: String? { try? keychain.getString(service: .listenbrainz, account: Account.token) }
    public var username: String? { try? keychain.getString(service: .listenbrainz, account: Account.username) }

    public func disconnect() {
        try? keychain.delete(service: .listenbrainz, account: Account.token)
        try? keychain.delete(service: .listenbrainz, account: Account.username)
    }

    private enum Account {
        static let token = "token"
        static let username = "username"
    }
}
