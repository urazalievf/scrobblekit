import AppIntents
import ScrobbleCore

// The same file is in Apps/ScrobbleKitiOS/AppIntents and
// Apps/ScrobbleKitMac/AppIntents; only `IntentHost` differs. App Intents
// have to be compiled into each app, so keep the two copies identical.

/// The periods Siri and Shortcuts can ask about.
enum ListeningPeriod: String, AppEnum {
    case thisWeek, thisMonth, thisYear, allTime

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [ListeningPeriod: DisplayRepresentation] = [
        .thisWeek: "This Week",
        .thisMonth: "This Month",
        .thisYear: "This Year",
        .allTime: "All Time",
    ]

    var range: StatsRange {
        switch self {
        case .thisWeek: .thisWeek
        case .thisMonth: .thisMonth
        case .thisYear: .thisYear
        case .allTime: .allTime
        }
    }
}

/// "What did I listen to yesterday?"
struct ListeningOnDayIntent: AppIntent {
    static let title: LocalizedStringResource = "What Did I Listen To"
    static let description = IntentDescription(
        "Says how many tracks you played on a day and which artists you played most. Uses ListenBrainz when it's connected (every device), otherwise this device's scrobbles."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Day", description: "Today if left empty.")
    var day: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("What did I listen to on \(\.$day)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let date = day ?? Date()
        let summary = try await IntentHost.shared.history.summary(ofDay: date)
        let text = summary.sentence(period: Self.phrase(for: date))
        return .result(value: text, dialog: "\(text)")
    }

    static func phrase(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        return "on " + date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// "Who are my top artists this month?"
struct TopArtistsIntent: AppIntent {
    static let title: LocalizedStringResource = "Top Artists"
    static let description = IntentDescription(
        "Your most played artists for a period, from ListenBrainz's statistics when it's connected."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Period", default: .thisWeek)
    var period: ListeningPeriod

    static var parameterSummary: some ParameterSummary {
        Summary("Top artists \(\.$period)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let artists = try await IntentHost.shared.history.topArtists(period.range)
        let text = artists.sentence(range: period.range)
        return .result(value: text, dialog: "\(text)")
    }
}

/// "What are my top tracks this year?"
struct TopTracksIntent: AppIntent {
    static let title: LocalizedStringResource = "Top Tracks"
    static let description = IntentDescription(
        "Your most played tracks for a period, from ListenBrainz's statistics when it's connected."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Period", default: .thisWeek)
    var period: ListeningPeriod

    static var parameterSummary: some ParameterSummary {
        Summary("Top tracks \(\.$period)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tracks = try await IntentHost.shared.history.topTracks(period.range)
        let text = tracks.sentence(range: period.range)
        return .result(value: text, dialog: "\(text)")
    }
}

/// "Love this song": Last.fm and ListenBrainz.
struct LoveTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Love This Song"
    static let description = IntentDescription(
        "Loves what's playing (or the last scrobble) on Last.fm and on ListenBrainz, where it needs a MusicBrainz match."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await IntentHost.shared.loveCurrentTrack()
        return .result(value: text, dialog: "\(text)")
    }
}
