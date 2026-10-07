import AppKit
import ScrobbleCore

/// Follows Music.app through its `com.apple.Music.playerInfo` distributed
/// notification, which it posts on every play, pause, stop and track change.
/// Nothing is polled. A 5-second timer only re-checks the scrobble threshold
/// while a track plays.
///
/// At launch, if Music is already playing, the current track is read once
/// with AppleScript (no notification arrives until something changes).
@MainActor
final class MusicWatcher {
    static let notification = Notification.Name("com.apple.Music.playerInfo")

    private var tracker = PlaybackTracker()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private let onEvent: (PlaybackTracker.Event) -> Void
    private let onChange: (PlayingTrack?, Bool) -> Void

    init(onEvent: @escaping (PlaybackTracker.Event) -> Void, onChange: @escaping (PlayingTrack?, Bool) -> Void) {
        self.onEvent = onEvent
        self.onChange = onChange

        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notification, object: nil, queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handle(info) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        readCurrentTrack()
    }

    private func handle(_ info: [AnyHashable: Any]) {
        let (track, state) = Self.parse(info)
        apply(tracker.handle(track: track, state: state, at: Date()))
        onChange(tracker.currentTrack, tracker.isPlaying)
    }

    private func tick() {
        guard tracker.isPlaying else { return }
        apply(tracker.tick(at: Date()))
    }

    private func apply(_ events: [PlaybackTracker.Event]) {
        events.forEach(onEvent)
    }

    /// Reads Music.app's playerInfo keys: Name, Artist, Album, Album Artist,
    /// Player State, Total Time (ms), Store URL and Persistent ID.
    static func parse(_ info: [AnyHashable: Any]) -> (PlayingTrack?, PlayerState) {
        let state: PlayerState = switch info["Player State"] as? String {
        case "Playing": .playing
        case "Paused": .paused
        default: .stopped
        }
        guard let title = info["Name"] as? String, !title.isEmpty,
              let artist = info["Artist"] as? String, !artist.isEmpty
        else { return (nil, state) }

        let totalMs = (info["Total Time"] as? NSNumber)?.doubleValue ?? 0
        let id = persistentID(info) ?? storeID(info) ?? PlayingTrack.fallbackID(artist: artist, title: title)
        let track = PlayingTrack(
            id: id, artist: artist, title: title,
            album: (info["Album"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            albumArtist: (info["Album Artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            durationSec: totalMs > 0 ? Int((totalMs / 1000).rounded()) : nil
        )
        return (track, state)
    }

    private static func persistentID(_ info: [AnyHashable: Any]) -> String? {
        for key in ["Persistent ID", "PersistentID"] {
            if let value = info[key] as? NSNumber, value.int64Value != 0 { return "pid:\(value.int64Value)" }
            if let value = info[key] as? String, !value.isEmpty { return "pid:\(value)" }
        }
        return nil
    }

    /// The `i=` parameter of a Store URL such as `itms://itunes.com/album?p=…&i=…`.
    private static func storeID(_ info: [AnyHashable: Any]) -> String? {
        guard let string = info["Store URL"] as? String,
              let item = URLComponents(string: string)?.queryItems?.first(where: { $0.name == "i" })?.value,
              !item.isEmpty
        else { return nil }
        return "store:\(item)"
    }

    // MARK: Launch-time read

    private func readCurrentTrack() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return }
        Task.detached(priority: .utility) {
            guard let snapshot = Self.currentTrackViaAppleScript() else { return }
            await MainActor.run { self.applySnapshot(snapshot) }
        }
    }

    private struct Snapshot: Sendable {
        let title, artist, album, albumArtist, persistentID: String
        let duration, position: Double
        let playing: Bool
    }

    private func applySnapshot(_ snapshot: Snapshot) {
        guard tracker.currentTrack == nil else { return } // a notification got there first
        let track = PlayingTrack(
            id: snapshot.persistentID.isEmpty
                ? PlayingTrack.fallbackID(artist: snapshot.artist, title: snapshot.title)
                : "pid:\(snapshot.persistentID)",
            artist: snapshot.artist, title: snapshot.title,
            album: snapshot.album.isEmpty ? nil : snapshot.album,
            albumArtist: snapshot.albumArtist.isEmpty ? nil : snapshot.albumArtist,
            durationSec: snapshot.duration > 0 ? Int(snapshot.duration.rounded()) : nil
        )
        // Started `position` seconds ago, as far as we can tell.
        let started = Date().addingTimeInterval(-snapshot.position)
        apply(tracker.handle(track: track, state: snapshot.playing ? .playing : .paused, at: started))
        apply(tracker.tick(position: snapshot.position, at: Date()))
        onChange(tracker.currentTrack, tracker.isPlaying)
    }

    /// Runs off the main thread: the first call can wait on the Automation
    /// permission prompt.
    private nonisolated static func currentTrackViaAppleScript() -> Snapshot? {
        let source = """
        tell application "Music"
            if player state is stopped then return {}
            set t to current track
            return {name of t, artist of t, album of t, album artist of t, persistent ID of t, ¬
                duration of t, player position, (player state as text)}
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error),
              result.numberOfItems == 8
        else { return nil }
        func string(_ index: Int) -> String { result.atIndex(index)?.stringValue ?? "" }
        func number(_ index: Int) -> Double { result.atIndex(index)?.doubleValue ?? 0 }
        return Snapshot(
            title: string(1), artist: string(2), album: string(3), albumArtist: string(4), persistentID: string(5),
            duration: number(6), position: number(7), playing: string(8) == "playing"
        )
    }
}
