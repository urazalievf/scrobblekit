import AppIntents
import ScrobbleCore

/// "Sync Scrobbles" for Shortcuts and Siri: polls Recently Played and sends
/// what's waiting. Meant for an hourly Personal Automation in Shortcuts,
/// which catches plays that background refresh missed.
struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Scrobbles"
    static let description = IntentDescription(
        "Checks Recently Played and sends waiting scrobbles to ListenBrainz and Last.fm."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let report = await AppModel.shared.sync()
        let pending = AppModel.shared.pendingCount
        let sent = "Sent \(report.lastfmSent) to Last.fm and \(report.listenbrainzSent) to ListenBrainz."
        let dialog: IntentDialog = pending > 0 ? "\(sent) \(pending) still waiting." : "\(sent)"
        return .result(dialog: dialog)
    }
}

/// The app whose state the intents read.
typealias IntentHost = AppModel

/// Siri phrases have to include the app name.
struct ScrobbleKitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: ["Sync scrobbles in \(.applicationName)", "\(.applicationName) sync scrobbles"],
            shortTitle: "Sync Scrobbles",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: ListeningOnDayIntent(),
            phrases: ["What did I listen to in \(.applicationName)", "\(.applicationName) what did I play today"],
            shortTitle: "What I Played",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: TopArtistsIntent(),
            phrases: ["My top artists in \(.applicationName)", "Top artists \(\.$period) in \(.applicationName)"],
            shortTitle: "Top Artists",
            systemImageName: "music.mic"
        )
        AppShortcut(
            intent: TopTracksIntent(),
            phrases: ["My top tracks in \(.applicationName)", "Top tracks \(\.$period) in \(.applicationName)"],
            shortTitle: "Top Tracks",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: LoveTrackIntent(),
            phrases: ["Love this song in \(.applicationName)", "\(.applicationName) love this song"],
            shortTitle: "Love This Song",
            systemImageName: "heart"
        )
    }
}
