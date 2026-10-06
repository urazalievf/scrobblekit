import CryptoKit
import Foundation

/// Last.fm API method signatures (`api_sig`), per https://www.last.fm/api/authspec:
/// sort parameters by name, concatenate each `<name><value>`, append the
/// shared secret, and take the MD5 of the UTF-8 bytes as lowercase hex.
public enum Signature {
    /// Parameters Last.fm leaves out of the signature.
    static let unsignedParameters: Set<String> = ["format", "callback"]

    public static func lastFM(_ parameters: [String: String], secret: String) -> String {
        md5Hex(stringToSign(parameters, secret: secret))
    }

    /// Names are compared byte by byte (ASCII order), so "artist[10]" sorts
    /// before "artist[1]".
    static func stringToSign(_ parameters: [String: String], secret: String) -> String {
        parameters
            .filter { !unsignedParameters.contains($0.key) }
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .map { $0.key + $0.value }
            .joined() + secret
    }

    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
