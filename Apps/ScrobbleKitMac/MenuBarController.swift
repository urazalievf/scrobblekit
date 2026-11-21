import AppKit
import MusicKit
import ScrobbleCore
import ServiceManagement
import SwiftData

/// Owns the Mac app's runtime: database, queue, Music.app watcher, the
/// other-devices check, logins and the 60-second flush loop. Views read its
/// state; it's the only writer.
@MainActor
@Observable
final class MenuBarController {
    static let shared = MenuBarController()
    static let flushInterval: Duration = .seconds(60)
    /// How often Recently Played is read while "Catch plays from my other
    /// devices" is on. Estimated play times are off by at most about this.
    static let otherDevicesInterval: Duration = .seconds(180)

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

    /// Read Apple Music's account-wide Recently Played for plays from the
    /// iPhone, CarPlay, iPad or HomePod. Off until the user turns it on.
    private(set) var catchOtherDevices: Bool
    private(set) var musicAuthorized = false
    private(set) var lastOtherDevicesCheck: Date?
    private(set) var otherDevicesError: String?
    private(set) var captureReport: CaptureCheck.Report?

    private(set) var recap: ListeningSummary?
    private(set) var recapSentence: String?
    private(set) var isLoadingRecap = false

    @ObservationIgnored private let resolver: MBIDResolver
    @ObservationIgnored private var watcher: MusicWatcher?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private let lastfmClient: LastFMClient?
    @ObservationIgnored private let listenbrainzClient = ListenBrainzClient()
    /// 2 pages = the last 60 tracks, plenty for a check every 3 minutes.
    @ObservationIgnored private let poller = RecentPlaysPoller(pages: 2)
    @ObservationIgnored private let recentSync: RecentPlaysSync
    @ObservationIgnored private let captureCheck = CaptureCheck()
    @ObservationIgnored private var otherDevicesTask: Task<Void, Never>?

    private enum Keys {
        static let catchOtherDevices = "catchOtherDevices"
    }

    private init() {
        do {
            container = try ModelContainer(for: ScrobbleRecord.self, MBIDCache.self)
        } catch {
            fatalError("Couldn't open the scrobble database: \(error)")
        }

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
        catchOtherDevices = UserDefaults.standard.bool(forKey: Keys.catchOtherDevices)
        musicAuthorized = MusicAuthorization.currentStatus == .authorized
        lastfmUser = lastfmAuth?.username
        listenbrainzUser = listenbrainzAuth.username
        refreshCounts()

        watcher = MusicWatcher(
            onEvent: { [weak self] event in self?.handle(event) },
            onChange: { [weak self] track, playing in self?.trackChanged(track, playing: playing) }
        )
        startFlushLoop()
        if catchOtherDevices { startOtherDevicesLoop() }
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
        case .finished(let scrobble):
            // ListenBrainz gets the play now, with how long it played.
            queue.recordPlayedTime(scrobble)
            Task { await syncNow() }
        }
    }

    // MARK: Other devices

    /// Turning it on asks for Apple Music access the first time and starts
    /// from a fresh baseline, so plays from before it was on aren't sent.
    func setCatchOtherDevices(_ on: Bool) async {
        otherDevicesError = nil
        if on {
            if MusicAuthorization.currentStatus != .authorized {
                _ = await MusicAuthorization.request()
            }
            musicAuthorized = MusicAuthorization.currentStatus == .authorized
            guard musicAuthorized else {
                otherDevicesError = "ScrobbleKit isn't allowed to read Apple Music. Allow it in System Settings → Privacy & Security → Media & Apple Music, then turn this on again."
                return
            }
            poller.reset()
            captureCheck.start(at: Date())
        } else {
            otherDevicesTask?.cancel()
            otherDevicesTask = nil
            captureCheck.stop()
            captureReport = nil
            lastOtherDevicesCheck = nil
        }
        catchOtherDevices = on
        UserDefaults.standard.set(on, forKey: Keys.catchOtherDevices)
        if on { startOtherDevicesLoop() }
    }

    private func startOtherDevicesLoop() {
        otherDevicesTask?.cancel()
        otherDevicesTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkOtherDevices()
                try? await Task.sleep(for: Self.otherDevicesInterval)
            }
        }
    }

    /// One Recently Played check. Plays this Mac caught itself, and plays
    /// already in the user's ListenBrainz history, are skipped.
    func checkOtherDevices() async {
        guard catchOtherDevices else { return }
        musicAuthorized = MusicAuthorization.currentStatus == .authorized
        guard musicAuthorized else {
            otherDevicesError = "ScrobbleKit lost access to Apple Music. Allow it in System Settings → Privacy & Security → Media & Apple Music."
            return
        }
        do {
            let outcome = try await recentSync.run(
                listenbrainzUser: listenbrainzUser, checkListenBrainz: true, captureCheck: captureCheck
            )
            lastOtherDevicesCheck = Date()
            otherDevicesError = nil
            refreshCaptureReport()
            if outcome.stored > 0 { await syncNow() }
        } catch {
            otherDevicesError = "Apple Music's Recently Played didn't answer: \(error.localizedDescription)"
            Log.capture.error("Other-devices check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshCaptureReport() {
        let now = Date()
        let mine = queue.scrobbles(from: now.addingTimeInterval(-CaptureCheck.period), to: now, sources: [.mac])
        captureReport = captureCheck.report(exactPlays: mine, now: now)
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
                queue.lastfmLoginFailed(error)
                lastfmLoginError = (error as? LastFMError)?.rejectsAPIKey == true
                    ? "Last.fm didn't accept this build's API key, so logging in can't work."
                    : "Last.fm login failed: \(error)"
            }
        }
    }

    func logOutLastFM() {
        lastfmAuth?.logOut()
        lastfmUser = nil
        queue.credentialsChanged()
        refreshCounts()
    }

    func resumeLastFM() {
        queue.resumeLastFM()
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

    // MARK: History, recap and Siri

    /// ListenBrainz when connected (every device), otherwise this Mac's plays.
    var history: ListeningHistory {
        ListeningHistory(listenbrainzUser: listenbrainzUser) { [queue] from, to in
            queue.scrobbles(from: from, to: to)
        }
    }

    var historySourceLabel: String {
        listenbrainzUser.map { "From ListenBrainz (\($0)), every device" } ?? "From this Mac's scrobbles"
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

    /// Loves what's playing, or the last scrobble. Returns what happened.
    func loveCurrentTrack() async -> String {
        let target: Scrobble? = nowPlaying.map {
            Scrobble(artist: $0.artist, track: $0.title, album: $0.album, durationSec: $0.durationSec, listenedAt: Date())
        } ?? queue.latestScrobble()
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
