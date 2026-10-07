import AppKit
import ScrobbleCore
import ServiceManagement
import SwiftData

/// Owns the Mac app's runtime: database, queue, Music.app watcher, logins and
/// the 60-second flush loop. Views read its state; it's the only writer.
@MainActor
@Observable
final class MenuBarController {
    static let shared = MenuBarController()
    static let flushInterval: Duration = .seconds(60)

    let container: ModelContainer
    let queue: ScrobbleQueue
    /// nil when the build has no Last.fm API key (see .env.example).
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
    var lastfmLoginError: String?

    @ObservationIgnored private let resolver: MBIDResolver
    @ObservationIgnored private var watcher: MusicWatcher?
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    private init() {
        do {
            container = try ModelContainer(for: ScrobbleRecord.self, MBIDCache.self)
        } catch {
            fatalError("Couldn't open the scrobble database: \(error)")
        }

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
        refreshCounts()

        watcher = MusicWatcher(
            onEvent: { [weak self] event in self?.handle(event) },
            onChange: { [weak self] track, playing in self?.trackChanged(track, playing: playing) }
        )
        startFlushLoop()
    }

    // MARK: Status

    var summary: StatusSummary {
        StatusSummary.make(
            status: queue.status,
            lastfmConnected: lastfmUser != nil,
            listenbrainzConnected: listenbrainzUser != nil,
            pending: pendingCount,
            failed: failedCount
        )
    }

    var menuBarSymbol: String {
        switch summary.level {
        case .good: "waveform"
        case .attention: "waveform.badge.exclamationmark"
        case .problem: "waveform.slash"
        }
    }

    // MARK: Playback

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
                // Looked up now for the artwork; the scrobble later hits the cache.
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
                    try await queue.enqueue(scrobble, source: .mac)
                } catch {
                    Log.queue.error("Couldn't store a scrobble: \(error.localizedDescription, privacy: .public)")
                }
                await syncNow()
            }
        }
    }

    // MARK: Sending

    func syncNow() async {
        isSyncing = true
        await queue.flush()
        refreshCounts()
        isSyncing = false
    }

    private func startFlushLoop() {
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: Self.flushInterval)
            }
        }
    }

    func refreshCounts() {
        pendingCount = queue.pendingCount()
        failedCount = queue.failedCount()
    }

    func retry(_ record: ScrobbleRecord) {
        queue.retryNow(record)
        Task { await syncNow() }
    }

    func delete(_ record: ScrobbleRecord) {
        queue.delete(record)
        refreshCounts()
    }

    // MARK: Last.fm

    func startLastFMLogin() {
        guard let lastfmAPIKey else { return }
        lastfmLoginError = nil
        NSWorkspace.shared.open(LastFMAuth.authorizationURL(apiKey: lastfmAPIKey))
    }

    func handleCallback(_ url: URL) {
        guard let token = LastFMAuth.token(from: url), let lastfmAuth else { return }
        Task {
            do {
                let session = try await lastfmAuth.completeLogin(token: token)
                lastfmUser = session.username
                lastfmLoginError = nil
                queue.credentialsChanged()
                await syncNow()
            } catch {
                lastfmLoginError = "Last.fm login failed: \(error)"
            }
        }
    }

    func logOutLastFM() {
        lastfmAuth?.logOut()
        lastfmUser = nil
        queue.credentialsChanged()
        refreshCounts()
    }

    func clearLastFMSuspension() {
        queue.clearLastFMSuspension()
        Task { await syncNow() }
    }

    // MARK: ListenBrainz

    func connectListenBrainz(token: String) async throws {
        listenbrainzUser = try await listenbrainzAuth.connect(token: token)
        queue.credentialsChanged()
        await syncNow()
    }

    func disconnectListenBrainz() {
        listenbrainzAuth.disconnect()
        listenbrainzUser = nil
        queue.credentialsChanged()
        refreshCounts()
    }

    // MARK: Launch at login

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.auth.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Configuration

    /// Filled into Info.plist at build time from .env by scripts/inject-lastfm-keys.sh.
    private static func lastfmKeysFromBundle() -> (apiKey: String, secret: String)? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "LastFMAPIKey") as? String, !key.isEmpty,
              let secret = Bundle.main.object(forInfoDictionaryKey: "LastFMSharedSecret") as? String, !secret.isEmpty
        else { return nil }
        return (key, secret)
    }
}
