import BackgroundTasks
import ScrobbleCore

/// Two background tasks, both running Recently Played polling plus a queue
/// flush. iOS decides when (and whether) they run:
/// - `com.scrobblekit.refresh`: app refresh, asked for every 15 minutes at
///   the earliest. In practice it's often less frequent.
/// - `com.scrobblekit.flush`: processing task with network, asked for
///   overnight.
enum BackgroundTaskScheduler {
    static let refreshID = "com.scrobblekit.refresh"
    static let flushID = "com.scrobblekit.flush"

    static func register() {
        for id in [refreshID, flushID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
                MainActor.assumeIsolated { run(task) }
            }
        }
    }

    static func scheduleAll() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        submit(refresh)

        let flush = BGProcessingTaskRequest(identifier: flushID)
        flush.requiresNetworkConnectivity = true
        flush.requiresExternalPower = false
        flush.earliestBeginDate = nextNight()
        submit(flush)
    }

    @MainActor
    private static func run(_ task: BGTask) {
        scheduleAll()
        let work = Task { await AppModel.shared.sync() }
        task.expirationHandler = { work.cancel() }
        Task {
            _ = await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }

    private static func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.capture.error("Couldn't schedule \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 2 a.m. tonight, or tomorrow if that has passed.
    private static func nextNight() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let twoAM = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: now) ?? now
        return twoAM > now ? twoAM : calendar.date(byAdding: .day, value: 1, to: twoAM) ?? now
    }
}
