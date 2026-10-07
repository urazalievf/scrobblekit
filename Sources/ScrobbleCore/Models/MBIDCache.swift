import CryptoKit
import Foundation
import SwiftData

/// One cached MusicBrainz lookup, keyed by artist, track and album.
///
/// A row with a recording MBID is a hit and never expires. A row without one
/// is a miss and is retried after `missTTL`.
@Model
public final class MBIDCache {
    @Attribute(.unique) public var key: String
    public var recordingMBID: String?
    public var releaseMBID: String?
    public var resolvedAt: Date

    public static let missTTL: TimeInterval = 7 * 24 * 60 * 60

    public init(key: String, recordingMBID: String?, releaseMBID: String?, resolvedAt: Date) {
        self.key = key
        self.recordingMBID = recordingMBID
        self.releaseMBID = releaseMBID
        self.resolvedAt = resolvedAt
    }

    /// SHA-256 (lowercase hex) of "artist|track|album", lowercased. A missing
    /// album counts as "".
    public static func key(artist: String, track: String, album: String?) -> String {
        let joined = "\(artist)|\(track)|\(album ?? "")".lowercased()
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isUsable(at now: Date) -> Bool {
        recordingMBID != nil || now.timeIntervalSince(resolvedAt) < Self.missTTL
    }
}

public enum MBIDLookup: Sendable, Equatable {
    /// Found in the cache with a recording MBID.
    case cachedHit(MusicBrainzMatch)
    /// Found in the cache as a miss less than 7 days old. MusicBrainz wasn't asked.
    case cachedMiss
    /// Asked MusicBrainz and cached the answer; nil when nothing matched.
    case queried(MusicBrainzMatch?)

    public var match: MusicBrainzMatch? {
        switch self {
        case .cachedHit(let match): match
        case .cachedMiss: nil
        case .queried(let match): match
        }
    }
}

/// Resolves a play to a MusicBrainz recording MBID: from the cache when
/// possible, otherwise from MusicBrainz, caching the answer. Network and
/// server errors are thrown and not cached.
public actor MBIDResolver: ModelActor {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor
    private let client: MusicBrainzClient

    public init(modelContainer: ModelContainer, client: MusicBrainzClient) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.client = client
    }

    public func resolve(
        artist: String, track: String, album: String?, durationSec: Int?, now: Date = Date()
    ) async throws -> MBIDLookup {
        let key = MBIDCache.key(artist: artist, track: track, album: album)
        var descriptor = FetchDescriptor<MBIDCache>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        let cached = try modelContext.fetch(descriptor).first

        if let cached, cached.isUsable(at: now) {
            guard let recordingMBID = cached.recordingMBID else { return .cachedMiss }
            return .cachedHit(MusicBrainzMatch(recordingMBID: recordingMBID, releaseMBID: cached.releaseMBID))
        }

        let match = try await client.searchRecording(artist: artist, track: track, album: album, durationSec: durationSec)

        if let cached {
            cached.recordingMBID = match?.recordingMBID
            cached.releaseMBID = match?.releaseMBID
            cached.resolvedAt = now
        } else {
            modelContext.insert(MBIDCache(
                key: key, recordingMBID: match?.recordingMBID, releaseMBID: match?.releaseMBID, resolvedAt: now
            ))
        }
        try modelContext.save()
        return .queried(match)
    }
}
