import CryptoKit
import Foundation
import SwiftData

public enum DedupResult {
    case inserted(ScrobbleRecord)
    case merged(ScrobbleRecord)

    public var record: ScrobbleRecord {
        switch self {
        case .inserted(let record), .merged(let record): record
        }
    }
}

/// Keeps one record per play when several capture paths, or iCloud history,
/// report the same play.
///
/// Tradeoff: plays are grouped by the minute they were listened in. Two
/// reports of one play whose timestamps straddle a minute boundary get
/// different keys and both stay.
public enum Dedup {
    /// SHA-256 (lowercase hex) of "artist|track|minute", with artist and track
    /// lowercased and minute = whole Unix seconds / 60. The album isn't part
    /// of the key. A "|" inside a name could in theory make two different
    /// plays share a key.
    public static func key(artist: String, track: String, listenedAt: Date) -> String {
        let minute = Int(listenedAt.timeIntervalSince1970) / 60
        let joined = "\(artist.lowercased())|\(track.lowercased())|\(minute)"
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Inserts a record for the play, or merges it into an existing record
    /// with the same key. A merge only fills in fields the existing record
    /// lacks; it never resets send state, source or timestamps. Doesn't save
    /// the context.
    public static func insertOrMerge(
        _ scrobble: Scrobble, source: ScrobbleSource, into context: ModelContext, now: Date = Date()
    ) throws -> DedupResult {
        let key = key(artist: scrobble.artist, track: scrobble.track, listenedAt: scrobble.listenedAt)
        var descriptor = FetchDescriptor<ScrobbleRecord>(predicate: #Predicate { $0.dedupKey == key })
        descriptor.fetchLimit = 1

        guard let existing = try context.fetch(descriptor).first else {
            let record = ScrobbleRecord(scrobble, source: source, createdAt: now)
            context.insert(record)
            return .inserted(record)
        }

        if existing.album.isNilOrEmpty { existing.album = scrobble.album }
        if existing.albumArtist.isNilOrEmpty { existing.albumArtist = scrobble.albumArtist }
        if existing.recordingMBID.isNilOrEmpty { existing.recordingMBID = scrobble.recordingMBID }
        if existing.durationSec == 0, let duration = scrobble.durationSec { existing.durationSec = duration }
        return .merged(existing)
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
