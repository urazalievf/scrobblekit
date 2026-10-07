import MediaPlayer
import MusicKit
import ScrobbleCore
import SwiftData
import SwiftUI

/// Owns the iPhone app's runtime: database, queue, the three capture layers
/// and logins. Background tasks and the Shortcuts intent call `sync()`.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let container: ModelContainer
    let queue: ScrobbleQueue
    let lastfmAuth: LastFMAuth?
    let listenbrainzAuth: ListenBrainzAuth
    let lastfmAPIKey: String?

    private(set) var nowPlaying: PlayingTrack?
    private(set) var isPlaying = false
    private(set) var nowPlayingReleaseMBID: String?
    private(set) var nowPlayingScrobbled = false
    private(set) var pendingCount = 0
    private(set) var failedCount = 0
    private(set) var lastfmUser: String?
    private(set) var listenbrainzUser: String?
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var musicAuthorized = false

    /// On by default. See SettingsView for what it does on iPhone.
    var ignoreOtherDevices: Bool {
        didSet { UserDefaults.standard.set(ignoreOtherDevices, forKey: Keys.ignoreOtherDevices) }
    }

    @ObservationIgnored private let resolver: MBIDResolver
    @ObservationIgnored private let monitor = ForegroundMonitor()
    @ObservationIgnored private let poller = RecentPlaysPoller()
    @ObservationIgnored private let listenbrainzClient = ListenBrainzClient()

    private enum Keys {
        static let ignoreOtherDevices = "ignoreOtherDevices"
        static let lastSync = "lastSync"
    }

    private init() {
        do {
            container = try ModelContainer(for: ScrobbleRecord.self, MBIDCache.self)
        } catch {
            fatalError("Couldn't open the scrobble database: \(error)")
        }
        UserDefaults.standard.register(defaults: [Keys.ignoreOtherDevices: true])
        ignoreOtherDevices = UserDefaults.standard.bool(forKey: Keys.ignoreOtherDevices)
        lastSync = UserDefaults.standard.object(forKey: Keys.lastSync) as? Date

        let keys = Self.lastfmKeysFromBundle()
        lastfmAPIKey = keys?.apiKey
        let lastfmClient = keys.map { LastFMClient(apiKey: $0.apiKey, sharedSecret: $0.secret) }
        let lastfmAuth = lastfmClient.map { LastFMAuth(client: $0) }
        let listenbrainzAuth = ListenBrainzAuth()
        self.lastfmAuth = lastfmAuth
        self.listenbrainzAuth = listenbrainzAuth

        resolver = MBIDResolver(modelContainer: container, client: MusicBrainzClient())
        queue = ScrobbleQueue(
            context: container.mainContext,
            lastfm: lastfmClient,
            listenbrainz: ListenBrainzClient(),
            resolver: resolver,
            credentials: {
                Credentials(lastfmSessionKey: lastfmAuth?.sessionKey, listenbrainzToken: listenbrainzAuth.token)
            }
        )

        lastfmUser = lastfmAuth?.username
        listenbrainzUser = listenbrainzAuth.username
        musicAuthorized = MusicAuthorization.currentStatus == .authorized
        refreshCounts()

        monitor.onEvent = { [weak self] event in self?.handle(event) }
        monitor.onChange = { [weak self] track, playing in self?.trackChanged(track, playing: playing) }
    }

    var summary: StatusSummary {
        StatusSummary.make(
            status: queue.status,
            lastfmConnected: lastfmUser != nil,
            listenbrainzConnected: listenbrainzUser != nil,
            pending: pendingCount,
            failed: failedCount
        )
    }

    // MARK: Lifecycle

    func becameActive() {
        musicAuthorized = MusicAuthorization.currentStatus == .authorized
        monitor.start()
        Task { await sync() }
    }

    func enteredBackground() {
        monitor.stop()
        BackgroundTaskScheduler.scheduleAll()
    }

    func requestMusicAccess() async {
        _ = await MusicAuthorization.request()
        _ = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        musicAuthorized = MusicAuthorization.currentStatus == .authorized
        monitor.start()
    }

    // MARK: Capture

    private func trackChanged(_ track: PlayingTrack?, playing: Bool) {
        if track?.id != nowPlaying?.id {
            nowPlayingReleaseMBID = nil
            nowPlayingScrobbled = false
        }
        nowPlaying = track
        isPlaying = playing
    }

    private func handle(_ event: PlaybackTracker.Event) {
        switch event {
        case .nowPlaying(let scrobble):
            Task {
                await queue.sendNowPlaying(scrobble)
                let lookup = try? await resolver.resolve(
                    artist: scrobble.artist, track: scrobble.track, album: scrobble.album,
                    durationSec: scrobble.durationSec
                )
                if nowPlaying?.title == scrobble.track {
                    nowPlayingReleaseMBID = lookup?.match?.releaseMBID
                }
            }
        case .scrobble(let scrobble):
            if nowPlaying?.title == scrobble.track { nowPlayingScrobbled = true }
            Task {
                do {
                    try await queue.enqueue(scrobble, source: .foreground)
                } catch {
                    Log.queue.error("Couldn't store a scrobble: \(error.localizedDescription, privacy: .public)")
                }
                await flush()
            }
        }
    }

    /// Polls Recently Played, then sends everything due. Called on launch,
    /// from background tasks, from pull-to-refresh and from SyncNowIntent.
    @discardableResult
    func sync() async -> FlushReport {
        guard !isSyncing else { return FlushReport() }
        isSyncing = true
        defer { isSyncing = false }

        await pollRecentlyPlayed()
        let report = await queue.flush()
        refreshCounts()
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: Keys.lastSync)
        return report
    }

    private func flush() async {
        await queue.flush()
        refreshCounts()
    }

    private func pollRecentlyPlayed() async {
        guard musicAuthorized else { return }
        do {
            var plays = try await poller.poll(now: Date())
            if ignoreOtherDevices, let user = listenbrainzUser,
               let earliest = plays.map(\.scrobble.listenedAt).min() {
                // Plays another device already scrobbled show up in the user's
                // ListenBrainz history; skip those.
                if let history = try? await listenbrainzClient.listens(
                    user: user, since: earliest.addingTimeInterval(-OtherDeviceFilter.window)
                ) {
                    let kept = OtherDeviceFilter.removingAlreadyScrobbled(plays.map(\.scrobble), history: history)
                    plays = plays.filter { kept.contains($0.scrobble) }
                }
            }
            for play in plays {
                try await queue.enqueue(play.scrobble, source: play.source)
            }
        } catch {
            Log.capture.error("Recently Played poll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshCounts() {
        pendingCount = queue.pendingCount()
        failedCount = queue.failedCount()
    }

    func retry(_ record: ScrobbleRecord) {
        queue.retryNow(record)
        Task { await flush() }
    }

    func delete(_ record: ScrobbleRecord) {
        queue.delete(record)
        refreshCounts()
    }

    // MARK: Accounts

    func completeLastFMLogin(callbackURL: URL) async throws {
        guard let lastfmAuth, let token = LastFMAuth.token(from: callbackURL) else { return }
        lastfmUser = try await lastfmAuth.completeLogin(token: token).username
        queue.credentialsChanged()
        await flush()
    }

    func logOutLastFM() {
        lastfmAuth?.logOut()
        lastfmUser = nil
        queue.credentialsChanged()
        refreshCounts()
    }

    func clearLastFMSuspension() {
        queue.clearLastFMSuspension()
        Task { await flush() }
    }

    func connectListenBrainz(token: String) async throws {
        listenbrainzUser = try await listenbrainzAuth.connect(token: token)
        queue.credentialsChanged()
        await flush()
    }

    func disconnectListenBrainz() {
        listenbrainzAuth.disconnect()
        listenbrainzUser = nil
        queue.credentialsChanged()
        refreshCounts()
    }

    /// Filled into Info.plist at build time from .env by scripts/inject-lastfm-keys.sh.
    private static func lastfmKeysFromBundle() -> (apiKey: String, secret: String)? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "LastFMAPIKey") as? String, !key.isEmpty,
              let secret = Bundle.main.object(forInfoDictionaryKey: "LastFMSharedSecret") as? String, !secret.isEmpty
        else { return nil }
        return (key, secret)
    }
}
