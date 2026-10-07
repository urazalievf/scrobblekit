import MediaPlayer
import ScrobbleCore

/// Real-time capture while the app is in the foreground, from the system
/// music player's notifications. iOS stops delivering them once the app is
/// suspended; the Recently Played poller covers that time.
@MainActor
final class ForegroundMonitor {
    var onEvent: ((PlaybackTracker.Event) -> Void)?
    var onChange: ((PlayingTrack?, Bool) -> Void)?

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var tracker = PlaybackTracker()
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    func start() {
        guard observers.isEmpty, MPMediaLibrary.authorizationStatus() == .authorized else { return }
        player.beginGeneratingPlaybackNotifications()
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        update()
    }

    func stop() {
        guard !observers.isEmpty else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        player.endGeneratingPlaybackNotifications()
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        let track = player.nowPlayingItem.flatMap(Self.track(from:))
        let state: PlayerState = switch player.playbackState {
        case .playing, .seekingForward, .seekingBackward: .playing
        case .stopped: .stopped
        default: .paused
        }
        emit(tracker.handle(track: track, state: state, position: position, at: Date()))
        onChange?(tracker.currentTrack, tracker.isPlaying)
    }

    private func tick() {
        guard tracker.isPlaying else { return }
        emit(tracker.tick(position: position, at: Date()))
    }

    private var position: TimeInterval? {
        let time = player.currentPlaybackTime
        return time.isFinite && time >= 0 ? time : nil
    }

    private func emit(_ events: [PlaybackTracker.Event]) {
        events.forEach { onEvent?($0) }
    }

    /// Radio tracks may have neither a persistent ID nor a store ID; they're
    /// identified by artist and title instead.
    static func track(from item: MPMediaItem) -> PlayingTrack? {
        guard let title = item.title, !title.isEmpty, let artist = item.artist, !artist.isEmpty else { return nil }
        let id: String
        if item.persistentID != 0 {
            id = "pid:\(item.persistentID)"
        } else if !item.playbackStoreID.isEmpty {
            id = "store:\(item.playbackStoreID)"
        } else {
            id = PlayingTrack.fallbackID(artist: artist, title: title)
        }
        return PlayingTrack(
            id: id, artist: artist, title: title,
            album: item.albumTitle.flatMap { $0.isEmpty ? nil : $0 },
            albumArtist: item.albumArtist.flatMap { $0.isEmpty ? nil : $0 },
            durationSec: item.playbackDuration > 0 ? Int(item.playbackDuration.rounded()) : nil,
            isPodcast: item.mediaType.contains(.podcast)
        )
    }
}
