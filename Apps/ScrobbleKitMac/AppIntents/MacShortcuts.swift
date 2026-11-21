import AppIntents
import ScrobbleCore

/// The app whose state the intents read.
typealias IntentHost = MenuBarController

/// "Sync Scrobbles" on the Mac: checks other devices' plays (when that's on)
/// and sends what's waiting.
struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Scrobbles"
    static let description = IntentDescription(
        "Checks Recently Played for your other devices' plays (when that's on) and sends waiting scrobbles."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = MenuBarController.shared
        await controller.checkOtherDevices()
        await controller.syncNow()
        let pending = controller.pendingCount
        let dialog: IntentDialog = pending > 0 ? "Synced. \(pending) still waiting." : "Synced. Everything is sent."
        return .result(dialog: dialog)
    }
}

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
