import AppIntents
import ScrobbleCore

/// "Sync Scrobbles" for Shortcuts and Siri: polls Recently Played and sends
/// what's waiting. Meant for an hourly Personal Automation in Shortcuts,
/// which catches plays that background refresh missed.
struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Scrobbles"
    static let description = IntentDescription(
        "Checks Apple Music's Recently Played and sends waiting scrobbles to Last.fm and ListenBrainz."
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

/// Siri phrases have to include the app name.
struct ScrobbleKitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: ["Sync scrobbles in \(.applicationName)", "\(.applicationName) sync scrobbles"],
            shortTitle: "Sync Scrobbles",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
