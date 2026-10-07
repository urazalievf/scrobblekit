import Foundation
@testable import ScrobbleCore

/// Records requests and replies with queued canned responses, in order.
///
/// `@unchecked Sendable` with no lock is safe only because each test uses its
/// own instance and awaits one request at a time.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data

        static func json(_ body: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(body.utf8))
        }
    }

    private var queued: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: Response...) {
        queued = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !queued.isEmpty else { throw URLError(.resourceUnavailable) }
        let response = queued.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (response.body, http)
    }
}

extension URLRequest {
    /// The body decoded as application/x-www-form-urlencoded.
    var formParameters: [String: String] {
        guard let body = httpBody, let string = String(data: body, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ part: Substring) -> String {
                part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            result[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return result
    }
}
