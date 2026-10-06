import Security
import XCTest
@testable import ScrobbleCore

final class KeychainStoreTests: XCTestCase {
    private var keychain: InMemoryKeychain!
    private var store: KeychainStore!

    override func setUp() {
        super.setUp()
        keychain = InMemoryKeychain()
        store = KeychainStore(backend: keychain)
    }

    func testServiceIdentifiers() {
        XCTAssertEqual(KeychainService.lastfm.rawValue, "com.scrobblekit.lastfm")
        XCTAssertEqual(KeychainService.listenbrainz.rawValue, "com.scrobblekit.listenbrainz")
    }

    func testGetMissingItemReturnsNil() throws {
        XCTAssertNil(try store.getString(service: .lastfm, account: "sessionKey"))
    }

    func testSetThenGetRoundTrips() throws {
        try store.setString("abc123", service: .lastfm, account: "sessionKey")
        XCTAssertEqual(try store.getString(service: .lastfm, account: "sessionKey"), "abc123")
    }

    func testSetReplacesExistingValue() throws {
        try store.setString("old", service: .listenbrainz, account: "token")
        try store.setString("new", service: .listenbrainz, account: "token")
        XCTAssertEqual(try store.getString(service: .listenbrainz, account: "token"), "new")
        XCTAssertEqual(keychain.itemCount, 1)
    }

    func testServicesAreSeparate() throws {
        try store.setString("from-lastfm", service: .lastfm, account: "token")
        try store.setString("from-listenbrainz", service: .listenbrainz, account: "token")
        XCTAssertEqual(try store.getString(service: .lastfm, account: "token"), "from-lastfm")
        XCTAssertEqual(try store.getString(service: .listenbrainz, account: "token"), "from-listenbrainz")
    }

    func testDeleteRemovesItem() throws {
        try store.setString("abc123", service: .lastfm, account: "sessionKey")
        try store.delete(service: .lastfm, account: "sessionKey")
        XCTAssertNil(try store.getString(service: .lastfm, account: "sessionKey"))
    }

    func testDeleteMissingItemSucceeds() {
        XCTAssertNoThrow(try store.delete(service: .lastfm, account: "sessionKey"))
    }

    func testNewItemIsGenericPasswordInDataProtectionKeychainAfterFirstUnlock() throws {
        try store.setString("abc123", service: .listenbrainz, account: "token")
        let attributes = try XCTUnwrap(keychain.lastAddAttributes)
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, "com.scrobblekit.listenbrainz")
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "token")
        XCTAssertEqual(attributes[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlock as String
        )
    }

    // iOS returns errSecInteractionNotAllowed when a background task runs
    // before the first unlock after a reboot.
    func testUnexpectedStatusIsThrownFromEveryMethod() {
        keychain.forcedStatus = errSecInteractionNotAllowed
        let expected = KeychainError.unexpectedStatus(errSecInteractionNotAllowed)

        XCTAssertThrowsError(try store.setString("x", service: .lastfm, account: "a")) {
            XCTAssertEqual($0 as? KeychainError, expected)
        }
        XCTAssertThrowsError(try store.getString(service: .lastfm, account: "a")) {
            XCTAssertEqual($0 as? KeychainError, expected)
        }
        XCTAssertThrowsError(try store.delete(service: .lastfm, account: "a")) {
            XCTAssertEqual($0 as? KeychainError, expected)
        }
    }

    func testNonUTF8DataThrowsInvalidData() {
        keychain.seed(Data([0xFF, 0xFE, 0xFD]), service: .lastfm, account: "sessionKey")
        XCTAssertThrowsError(try store.getString(service: .lastfm, account: "sessionKey")) {
            XCTAssertEqual($0 as? KeychainError, .invalidData)
        }
    }
}
