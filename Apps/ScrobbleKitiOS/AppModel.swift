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
    private(set) var recap: ListeningSummary?
    private(set) var recapSentence: String?
    private(set) var isLoadingRecap = false

    /// On by default. See SettingsView for what it does on iPhone.
    var ignoreOtherDevices: Bool {
        didSet { UserDefaults.standard.set(ignoreOtherDevices, forKey: Keys.ignoreOtherDevices) }
    }

    @ObservationIgnored private let resolver: MBIDResolver
    @ObservationIgnored private let monitor = ForegroundMonitor()
    /// 4 pages = the last 120 tracks: background checks can be hours apart.
    @ObservationIgnored private let poller = RecentPlaysPoller(pages: 4)
    @ObservationIgnored private let recentSync: RecentPlaysSync
    @ObservationIgnored private let listenbrainzClient = ListenBrainzClient()
    @ObservationIgnored private let lastfmClient: LastFMClient?

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
        self.lastfmClient = lastfmClient
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

        recentSync = RecentPlaysSync(poller: poller, queue: queue)
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
        case .finished(let scrobble):
            // ListenBrainz gets the play now, with how long it played.
            queue.recordPlayedTime(scrobble)
            Task { await flush() }
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
            // Plays another device already scrobbled show up in the user's
            // ListenBrainz history; with "Ignore other devices" on, skip those.
            _ = try await recentSync.run(listenbrainzUser: listenbrainzUser, checkListenBrainz: ignoreOtherDevices)
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
        do {
            lastfmUser = try await lastfmAuth.completeLogin(token: token).username
        } catch {
            queue.lastfmLoginFailed(error)
            throw error
        }
        queue.credentialsChanged()
        await flush()
    }

    func logOutLastFM() {
        lastfmAuth?.logOut()
        lastfmUser = nil
        queue.credentialsChanged()
        refreshCounts()
    }

    func resumeLastFM() {
        queue.resumeLastFM()
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

    // MARK: History, recap and Siri

    /// ListenBrainz when connected (every device), otherwise this iPhone's plays.
    var history: ListeningHistory {
        ListeningHistory(listenbrainzUser: listenbrainzUser) { [queue] from, to in
            queue.scrobbles(from: from, to: to)
        }
    }

    var historySourceLabel: String {
        listenbrainzUser.map { "From ListenBrainz (\($0)), every device" } ?? "From this iPhone's scrobbles"
    }

    func refreshRecap() async {
        isLoadingRecap = true
        defer { isLoadingRecap = false }
        do {
            let summary = try await history.summary(of: .thisWeek)
            // The on-device sentence only changes when the counts do.
            guard summary != recap || recapSentence == nil else { return }
            recap = summary
            recapSentence = await RecapNarrator.sentence(for: summary, period: "this week")
        } catch {
            Log.capture.error("Couldn't load the weekly recap: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loves what's playing, or the last scrobble, on every connected service
    /// that can take it. Returns what happened, for Siri to say.
    func loveCurrentTrack() async -> String {
        let player = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem
        let target: Scrobble? = if let player, let title = player.title, let artist = player.artist {
            Scrobble(artist: artist, track: title, album: player.albumTitle,
                     durationSec: player.playbackDuration > 0 ? Int(player.playbackDuration.rounded()) : nil,
                     listenedAt: Date())
        } else {
            queue.latestScrobble()
        }
        guard let target else { return "Nothing has played yet, so there's nothing to love." }
        let mbid = try? await resolver.resolve(
            artist: target.artist, track: target.track, album: target.album, durationSec: target.durationSec
        ).match?.recordingMBID
        return await Love.send(
            target, recordingMBID: target.recordingMBID ?? mbid,
            lastfm: lastfmClient, lastfmSession: lastfmAuth?.sessionKey,
            listenbrainz: listenbrainzClient, listenbrainzToken: listenbrainzAuth.token
        )
    }

    /// Filled into Info.plist at build time from .env by scripts/inject-lastfm-keys.sh.
    private static func lastfmKeysFromBundle() -> (apiKey: String, secret: String)? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "LastFMAPIKey") as? String, !key.isEmpty,
              let secret = Bundle.main.object(forInfoDictionaryKey: "LastFMSharedSecret") as? String, !secret.isEmpty
        else { return nil }
        return (key, secret)
    }
}
