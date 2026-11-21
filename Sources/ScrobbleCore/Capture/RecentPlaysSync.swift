import Foundation

/// One Recently Played check, as both apps run it: poll, drop plays another
/// capture path already has, store the rest. Sending is left to the caller.
@MainActor
public struct RecentPlaysSync {
    public struct Outcome: Sendable, Equatable {
        /// New plays Recently Played listed since the previous check.
        public var found: Int
        /// How many of them were stored (the rest were already scrobbled).
        public var stored: Int
    }

    private let poller: RecentPlaysPoller
    private let queue: ScrobbleQueue
    private let listenbrainz: ListenBrainzClient

    public init(poller: RecentPlaysPoller, queue: ScrobbleQueue, listenbrainz: ListenBrainzClient = ListenBrainzClient()) {
        self.poller = poller
        self.queue = queue
        self.listenbrainz = listenbrainz
    }

    /// - Parameters:
    ///   - listenbrainzUser: when set and `checkListenBrainz` is on, plays in
    ///     the user's ListenBrainz history (sent by another device) are skipped.
    ///   - captureCheck: notes which of this Mac's exact plays were listed.
    public func run(
        listenbrainzUser: String?, checkListenBrainz: Bool, captureCheck: CaptureCheck? = nil, now: Date = Date()
    ) async throws -> Outcome {
        let result = try await poller.poll(now: now)
        guard let start = OtherDeviceFilter.historyStart(for: result.plays, previousCheck: result.previousCheck) else {
            return Outcome(found: 0, stored: 0)
        }

        let stored = queue.scrobbles(from: start, to: now)
        let exact = queue.scrobbles(from: start, to: now, sources: [.mac, .foreground, .manual])
        captureCheck?.note(detected: result.plays, exactPlays: queue.scrobbles(from: start, to: now, sources: [.mac]),
                           previousCheck: result.previousCheck, now: now)

        var history = exact
        if checkListenBrainz, let listenbrainzUser,
           let listens = try? await listenbrainz.listens(user: listenbrainzUser, from: start, to: now) {
            history += Self.otherDevicesListens(listens, storedHere: stored, exactHere: exact)
        }
        let plays = OtherDeviceFilter.removingAlreadyScrobbled(
            result.plays, history: history, previousCheck: result.previousCheck, now: now
        )
        for play in plays {
            try await queue.enqueue(play.scrobble, source: play.source, now: now)
        }
        return Outcome(found: result.plays.count, stored: plays.count)
    }

    /// ListenBrainz listens minus the ones this device sent from earlier
    /// Recently Played checks. Without this, a song replayed later would be
    /// matched against its own earlier listen and dropped.
    static func otherDevicesListens(_ listens: [Scrobble], storedHere: [Scrobble], exactHere: [Scrobble]) -> [Scrobble] {
        let exactKeys = Set(exactHere.map(Self.key))
        let polledHere = Set(storedHere.map(Self.key)).subtracting(exactKeys)
        return listens.filter { !polledHere.contains(Self.key($0)) }
    }

    private static func key(_ play: Scrobble) -> String {
        Dedup.key(artist: play.artist, track: play.track, listenedAt: play.listenedAt)
    }
}
