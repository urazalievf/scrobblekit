import Foundation
import MusicKit
import ScrobbleCore

/// Reads Apple Music's Recently Played tracks and returns plays that appeared
/// since the last poll. The comparison lives in `RecentPlaysDiff`; this type
/// fetches the list and keeps the last-seen map in UserDefaults.
@MainActor
final class RecentPlaysPoller {
    private let key = "recentPlays.lastSeen"

    func poll(now: Date) async throws -> [DetectedPlay] {
        var request = MusicRecentlyPlayedRequest<Track>()
        request.limit = 30
        let response = try await request.response()

        let items = response.items.map { track in
            RecentPlay(
                id: track.id.rawValue,
                artist: track.artistName,
                title: track.title,
                album: track.albumTitle,
                durationSec: track.duration.map { Int($0.rounded()) },
                lastPlayedDate: track.lastPlayedDate
            )
        }
        let result = RecentPlaysDiff.newPlays(in: Array(items), lastSeen: loadLastSeen(), now: now)
        UserDefaults.standard.set(result.lastSeen, forKey: key)
        if !result.plays.isEmpty {
            Log.capture.info("Recently Played: \(result.plays.count) new plays")
        }
        return result.plays
    }

    private func loadLastSeen() -> [String: Double]? {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
    }
}
