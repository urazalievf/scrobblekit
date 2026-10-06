import Foundation
import Security

/// The Keychain services ScrobbleKit stores credentials under.
public enum KeychainService: String, CaseIterable, Sendable {
    case lastfm = "com.scrobblekit.lastfm"
    case listenbrainz = "com.scrobblekit.listenbrainz"
}

public enum KeychainError: Error, Equatable {
    /// A Security framework call returned a status KeychainStore doesn't handle.
    case unexpectedStatus(OSStatus)
    /// An item exists but its data isn't a UTF-8 string.
    case invalidData
}

/// The four Security framework calls KeychainStore makes. They sit behind a
/// protocol so tests can substitute an in-memory fake: `swift test` builds
/// unsigned binaries, which can't reach the data protection keychain.
public protocol KeychainBackend: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?)
    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// Calls the real Security framework.
public struct SystemKeychain: KeychainBackend {
    public init() {}

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    public func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Stores strings as generic passwords (`kSecClassGenericPassword`), one item
/// per service and account.
///
/// Items go in the data protection keychain on both macOS and iOS. On macOS
/// that only works when the app is signed with an App ID (a provisioning
/// profile); otherwise every call fails with `errSecMissingEntitlement` (-34018).
///
/// New items are readable from the first unlock after a reboot onward, so iOS
/// background tasks can read them while the phone is locked.
public struct KeychainStore: Sendable {
    private let backend: any KeychainBackend

    public init(backend: any KeychainBackend = SystemKeychain()) {
        self.backend = backend
    }

    /// Saves `value`, replacing any existing item for this service and account.
    public func setString(_ value: String, service: KeychainService, account: String) throws {
        let query = Self.itemQuery(service: service, account: account)
        let data = Data(value.utf8)

        let updateStatus = backend.update(query, with: [kSecValueData as String: data])
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = backend.add(attributes)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Returns the stored string, or nil when no item exists.
    public func getString(service: KeychainService, account: String) throws -> String? {
        var query = Self.itemQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = backend.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes the item. Does not throw when there was nothing to remove.
    public func delete(service: KeychainService, account: String) throws {
        let status = backend.delete(Self.itemQuery(service: service, account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// The attributes that identify one item.
    private static func itemQuery(service: KeychainService, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
