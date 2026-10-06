import Foundation
import Security
@testable import ScrobbleCore

/// Replaces the Security framework in tests. It returns the same SecItem
/// status codes that KeychainStore branches on: duplicate add, and missing
/// item on update, copy and delete.
///
/// `@unchecked Sendable` with no lock is safe only because each test uses its
/// own instance from a single thread.
final class InMemoryKeychain: KeychainBackend, @unchecked Sendable {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private var items: [Key: Data] = [:]

    /// When set, every call returns this status and changes nothing.
    var forcedStatus: OSStatus?

    /// The attributes passed to the most recent successful `add`.
    private(set) var lastAddAttributes: [String: Any]?

    var itemCount: Int { items.count }

    /// Stores raw bytes directly, bypassing KeychainStore.
    func seed(_ data: Data, service: KeychainService, account: String) {
        items[Key(service: service.rawValue, account: account)] = data
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        if let forcedStatus { return forcedStatus }
        guard let key = Self.key(attributes),
              let data = attributes[kSecValueData as String] as? Data
        else { return errSecParam }
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = data
        lastAddAttributes = attributes
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        if let forcedStatus { return (forcedStatus, nil) }
        guard let key = Self.key(query) else { return (errSecParam, nil) }
        guard let data = items[key] else { return (errSecItemNotFound, nil) }
        let returnData = query[kSecReturnData as String] as? Bool == true
        return (errSecSuccess, returnData ? data as NSData : nil)
    }

    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        if let forcedStatus { return forcedStatus }
        guard let key = Self.key(query),
              let data = attributes[kSecValueData as String] as? Data
        else { return errSecParam }
        guard items[key] != nil else { return errSecItemNotFound }
        items[key] = data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        if let forcedStatus { return forcedStatus }
        guard let key = Self.key(query) else { return errSecParam }
        return items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
    }

    /// Accepts only generic-password queries that name both service and account.
    private static func key(_ query: [String: Any]) -> Key? {
        guard query[kSecClass as String] as? String == kSecClassGenericPassword as String,
              let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String
        else { return nil }
        return Key(service: service, account: account)
    }
}
