import XCTest
@testable import ScrobbleCore

// Expected hashes come from macOS `md5`, not from the code under test.
final class SignatureTests: XCTestCase {
    // RFC 1321 appendix A.5 test suite.
    func testMD5MatchesRFC1321Vectors() {
        XCTAssertEqual(Signature.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(Signature.md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(Signature.md5Hex("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")
    }

    func testStringToSignSortsByNameAndAppendsSecret() {
        let parameters = ["token": "testtoken", "method": "auth.getSession", "api_key": "testapikey"]
        XCTAssertEqual(
            Signature.stringToSign(parameters, secret: "testsecret"),
            "api_keytestapikeymethodauth.getSessiontokentesttokentestsecret"
        )
    }

    func testFormatAndCallbackAreNotSigned() {
        let parameters = ["method": "auth.getSession", "format": "json", "callback": "cb"]
        XCTAssertEqual(Signature.stringToSign(parameters, secret: "s"), "methodauth.getSessions")
    }

    func testAuthGetSessionSignature() {
        let parameters = [
            "method": "auth.getSession",
            "api_key": "testapikey",
            "token": "testtoken",
            "format": "json",
        ]
        XCTAssertEqual(
            Signature.lastFM(parameters, secret: "testsecret"),
            "dff91a0c1be9825346653bee9ea590cb"
        )
    }

    func testNonASCIIValuesAreHashedAsUTF8() {
        let parameters = ["artist": "Sigur Rós", "track": "Hoppípolla"]
        XCTAssertEqual(
            Signature.lastFM(parameters, secret: "testsecret"),
            "e89f8fbca1d440d42bef208f2581feb6"
        )
    }

    // Byte order puts "artist[10]" before "artist[1]" because '0' (0x30)
    // sorts before ']' (0x5D). Batch scrobbles with 11+ items depend on this.
    func testIndexedBatchKeysSortInByteOrder() {
        let parameters = ["artist[1]": "B", "artist[10]": "K", "artist[0]": "A"]
        XCTAssertEqual(
            Signature.stringToSign(parameters, secret: ""),
            "artist[0]Aartist[10]Kartist[1]B"
        )
    }
}
