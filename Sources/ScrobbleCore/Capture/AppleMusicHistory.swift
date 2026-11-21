import Foundation

/// Apple Music's account-wide Recently Played tracks, read from the Apple
/// Music API (`/v1/me/recent/played/tracks`) instead of MusicKit's
/// `MusicRecentlyPlayedRequest`.
///
/// Why the raw endpoint: since 5 August 2026 Apple leaves out plays started
/// from the library or from the user's own playlists unless the request
/// names library songs in `types` (Apple Developer Forums threads 841024 and
/// 845320). `MusicRecentlyPlayedRequest` has no way to say that.
///
/// The list covers every device that writes to the account's listening
/// history (iPhone, CarPlay, Mac, iPad, HomePod when it reports), newest
/// first, one entry per track, with no play times. Pure parsing lives here;
/// `RecentPlaysPoller` does the fetching.
public enum AppleMusicHistory {
    /// The endpoint's maximum page size.
    public static let pageSize = 30

    public static func url(offset: Int) -> URL {
        var components = URLComponents(string: "https://api.music.apple.com/v1/me/recent/played/tracks")!
        components.queryItems = [
            URLQueryItem(name: "types", value: "songs,library-songs"),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        return components.url!
    }

    public struct Page: Sendable, Equatable {
        public var items: [RecentPlay]
        /// Apple sent a `next` link: there is more history after this page.
        public var hasMore: Bool
    }

    public enum ParseError: Error, Equatable {
        case unexpectedResponse
    }

    /// Reads one page. Items without a name or artist (rare: unavailable
    /// tracks) are dropped; music videos aren't requested.
    public static func parsePage(_ data: Data) throws -> Page {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ParseError.unexpectedResponse
        }
        let items = response.data.compactMap { resource -> RecentPlay? in
            guard let attributes = resource.attributes,
                  let title = attributes.name, !title.isEmpty,
                  let artist = attributes.artistName, !artist.isEmpty
            else { return nil }
            return RecentPlay(
                id: resource.id,
                artist: artist,
                title: title,
                album: attributes.albumName.flatMap { $0.isEmpty ? nil : $0 },
                durationSec: attributes.durationInMillis.map { Int((Double($0) / 1000).rounded()) },
                lastPlayedDate: nil,
                catalogID: attributes.playParams?.catalogId
            )
        }
        return Page(items: items, hasMore: response.next != nil)
    }

    /// Copies play dates from MusicKit's Recently Played (which has them for
    /// library items) onto the raw list, matched by ID, then catalog ID, then
    /// artist and title. The raw list's order and contents are kept.
    public static func addingPlayDates(to items: [RecentPlay], from dated: [RecentPlay]) -> [RecentPlay] {
        var byID: [String: Date] = [:]
        var byName: [String: Date] = [:]
        for item in dated {
            guard let date = item.lastPlayedDate else { continue }
            byID[item.id] = byID[item.id] ?? date
            if let catalogID = item.catalogID { byID[catalogID] = byID[catalogID] ?? date }
            byName[nameKey(item)] = byName[nameKey(item)] ?? date
        }
        var usedNames: Set<String> = []
        return items.map { item in
            var item = item
            if let date = byID[item.id] ?? item.catalogID.flatMap({ byID[$0] }) {
                item.lastPlayedDate = date
            } else if !usedNames.contains(nameKey(item)), let date = byName[nameKey(item)] {
                // A track is listed once, so the first raw item with this
                // name is the one MusicKit dated.
                item.lastPlayedDate = date
            }
            usedNames.insert(nameKey(item))
            return item
        }
    }

    private static func nameKey(_ item: RecentPlay) -> String {
        MusicBrainzClient.normalize(item.artist) + "|" + MusicBrainzClient.normalize(item.title)
    }

    // MARK: Response body

    private struct Response: Decodable {
        let data: [Resource]
        let next: String?
    }

    private struct Resource: Decodable {
        let id: String
        let attributes: Attributes?
    }

    private struct Attributes: Decodable {
        struct PlayParams: Decodable {
            let catalogId: String?
        }

        let name: String?
        let artistName: String?
        let albumName: String?
        let durationInMillis: Int?
        let playParams: PlayParams?
    }
}
