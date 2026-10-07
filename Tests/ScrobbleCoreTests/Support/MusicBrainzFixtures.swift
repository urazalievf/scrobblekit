import Foundation
@testable import ScrobbleCore

/// Builds MusicBrainz recording-search JSON shaped like the real
/// /ws/2/recording responses (checked against live results for these tracks).
enum MusicBrainzFixtures {
    struct Recording {
        var id: String
        var title: String
        /// (name, joinphrase) pairs, as in "artist-credit".
        var credits: [(String, String)] = [("Rick Astley", "")]
        var lengthMs: Int?
        /// (release id, release title) pairs.
        var releases: [(String, String)] = []
    }

    static func search(_ recordings: [Recording]) -> StubTransport.Response {
        let objects: [[String: Any]] = recordings.enumerated().map { index, recording in
            var object: [String: Any] = [
                "id": recording.id,
                "score": 100 - index,
                "title": recording.title,
                "artist-credit": recording.credits.map { ["name": $0.0, "joinphrase": $0.1] },
                "releases": recording.releases.map { ["id": $0.0, "title": $0.1] },
            ]
            if let length = recording.lengthMs { object["length"] = length }
            return object
        }
        let body: [String: Any] = ["count": recordings.count, "offset": 0, "recordings": objects]
        return StubTransport.Response(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
    }

    static let empty = search([])

    /// One clean hit for Radiohead – Reckoner on In Rainbows.
    static let reckoner = search([
        Recording(
            id: "d9b46ecb-5472-4dcd-8fa4-dd6723189e27", title: "Reckoner",
            credits: [("Radiohead", "")], lengthMs: 290_213,
            releases: [("f6efda86-0000-4000-8000-000000000000", "In Rainbows")]
        ),
    ])
}
