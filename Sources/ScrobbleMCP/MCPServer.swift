import Foundation
import ScrobbleCore

/// A small MCP server (stdio, tools only) that answers questions about the
/// user's listening from their public ListenBrainz history: recent listens,
/// a day's or a period's summary, top artists and tracks, and the total
/// count. Every tool only reads; nothing is written anywhere.
///
/// The protocol is JSON-RPC 2.0, one message per line. Only what a tools
/// server needs is implemented: `initialize`, `ping`, `tools/list` and
/// `tools/call`. Notifications get no reply.
@MainActor
public final class MCPServer {
    public struct Configuration: Sendable {
        /// The ListenBrainz account to read. Listening history is public, so
        /// no token is needed.
        public var listenbrainzUser: String?
        public var transport: any HTTPTransport
        public var calendar: Calendar
        public var now: @Sendable () -> Date

        public init(listenbrainzUser: String?, transport: any HTTPTransport = URLSession.shared,
                    calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
            self.listenbrainzUser = listenbrainzUser
            self.transport = transport
            self.calendar = calendar
            self.now = now
        }

        /// `LISTENBRAINZ_USER` from the environment, or `--user NAME`.
        public static func fromEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment,
            arguments: [String] = CommandLine.arguments
        ) -> Configuration {
            var user = environment["LISTENBRAINZ_USER"].flatMap { $0.isEmpty ? nil : $0 }
            if let index = arguments.firstIndex(of: "--user"), index + 1 < arguments.count {
                user = arguments[index + 1]
            }
            return Configuration(listenbrainzUser: user)
        }
    }

    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let configuration: Configuration
    private let client: ListenBrainzClient

    public init(configuration: Configuration) {
        self.configuration = configuration
        client = ListenBrainzClient(transport: configuration.transport)
    }

    /// Handles one line and returns the reply line, or nil for notifications.
    public func handle(_ line: String) async -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let message = object as? [String: Any]
        else {
            return Self.encode(Self.error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let method = message["method"] as? String else {
            return Self.encode(Self.error(id: message["id"] ?? NSNull(), code: -32600, message: "Invalid request"))
        }
        // A message without an id is a notification: never answered.
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        let reply: [String: Any]
        switch method {
        case "initialize":
            reply = Self.result(id: id, initialize(params))
        case "ping":
            reply = Self.result(id: id, [:])
        case "tools/list":
            reply = Self.result(id: id, ["tools": Tool.allCases.map(\.definition)])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = Tool(rawValue: name) else {
                reply = Self.error(id: id, code: -32602, message: "Unknown tool: \(params["name"] ?? "none")")
                break
            }
            reply = Self.result(id: id, await call(tool, arguments: params["arguments"] as? [String: Any] ?? [:]))
        default:
            reply = Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
        return Self.encode(reply)
    }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": [
                "name": "scrobblekit-listening-history",
                "title": "ScrobbleKit listening history",
                "version": ScrobbleCore.version,
            ],
            "instructions": """
                Reads the user's public ListenBrainz listening history (every device that scrobbles \
                there, including ScrobbleKit for Apple Music). Use listening_summary for "what did I \
                listen to" questions, top_artists and top_tracks for favourites over a period, and \
                recent_listens for the exact plays. Times are in the user's local time zone. \
                ListenBrainz's top-artist and top-track statistics update about once a day.
                """,
        ]
    }

    // MARK: Tools

    enum Tool: String, CaseIterable {
        case recentListens = "recent_listens"
        case listeningSummary = "listening_summary"
        case topArtists = "top_artists"
        case topTracks = "top_tracks"
        case listenCount = "listen_count"

        var definition: [String: Any] {
            [
                "name": rawValue,
                "title": title,
                "description": description,
                "inputSchema": inputSchema,
                "annotations": ["title": title, "readOnlyHint": true, "openWorldHint": true],
            ]
        }

        var title: String {
            switch self {
            case .recentListens: "Recent listens"
            case .listeningSummary: "Listening summary"
            case .topArtists: "Top artists"
            case .topTracks: "Top tracks"
            case .listenCount: "Listen count"
            }
        }

        var description: String {
            switch self {
            case .recentListens:
                "The user's listens between two times, newest first (default: the last 24 hours)."
            case .listeningSummary:
                "How many tracks the user played on a day or in a period so far, with the most played artists and tracks. Counted from the listens themselves, so it is current."
            case .topArtists:
                "The user's most played artists for a period, from ListenBrainz's statistics (updated about daily)."
            case .topTracks:
                "The user's most played tracks for a period, from ListenBrainz's statistics (updated about daily)."
            case .listenCount:
                "How many listens the user's ListenBrainz account has in total."
            }
        }

        var inputSchema: [String: Any] {
            let range: [String: Any] = [
                "type": "string",
                "enum": StatsRange.allCases.map(\.rawValue),
                "description": "Period. Default this_week.",
            ]
            let count: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 50, "description": "Default 10."]
            switch self {
            case .recentListens:
                return ["type": "object", "additionalProperties": false, "properties": [
                    "from": ["type": "string", "description": "ISO 8601 date or date-time. Default: 24 hours ago."],
                    "to": ["type": "string", "description": "ISO 8601 date or date-time. Default: now."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Default 50."],
                ]]
            case .listeningSummary:
                return ["type": "object", "additionalProperties": false, "properties": [
                    "day": ["type": "string", "description": "A calendar day, YYYY-MM-DD, \"today\" or \"yesterday\"."],
                    "period": [
                        "type": "string", "enum": ["this_week", "this_month"],
                        "description": "Used when no day is given. Default this_week.",
                    ],
                ]]
            case .topArtists, .topTracks:
                return ["type": "object", "additionalProperties": false, "properties": ["range": range, "count": count]]
            case .listenCount:
                return ["type": "object", "additionalProperties": false, "properties": [:]]
            }
        }
    }

    private func call(_ tool: Tool, arguments: [String: Any]) async -> [String: Any] {
        guard let user = configuration.listenbrainzUser else {
            return Self.toolResult(
                "No ListenBrainz account is set. Start scrobblekit-mcp with LISTENBRAINZ_USER set to your ListenBrainz user name (or --user NAME).",
                isError: true
            )
        }
        let history = ListeningHistory(client: client, listenbrainzUser: user) { _, _ in [] }
        let now = configuration.now()
        do {
            switch tool {
            case .recentListens:
                let to = try date(arguments["to"], endOfDay: true) ?? now
                let from = try date(arguments["from"], endOfDay: false) ?? to.addingTimeInterval(-24 * 60 * 60)
                let limit = min(500, max(1, arguments["limit"] as? Int ?? 50))
                let listens = try await client.listens(user: user, from: from, to: to, limit: limit)
                guard !listens.isEmpty else { return Self.toolResult("No listens between \(stamp(from)) and \(stamp(to)).") }
                let lines = listens.map { listen in
                    "\(stamp(listen.listenedAt)) — \(listen.track) — \(listen.artist)"
                        + (listen.album.map { " (\($0))" } ?? "")
                }
                return Self.toolResult("\(listens.count) listens, newest first:\n" + lines.joined(separator: "\n"))

            case .listeningSummary:
                let summary: ListeningSummary
                let phrase: String
                if let day = arguments["day"] as? String {
                    let date = try dayDate(day, now: now)
                    summary = try await history.summary(ofDay: date, calendar: configuration.calendar)
                    phrase = "on " + date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
                } else {
                    let range: StatsRange = (arguments["period"] as? String) == "this_month" ? .thisMonth : .thisWeek
                    summary = try await history.summary(of: range, now: now, calendar: configuration.calendar)
                    phrase = range.phrase
                }
                var text = summary.sentence(period: phrase)
                if !summary.topTracks.isEmpty {
                    text += "\nMost played tracks: " + summary.topTracks.prefix(5)
                        .map { "\($0.track) by \($0.artist) (\($0.listens))" }.joined(separator: "; ") + "."
                }
                if let latest = summary.latest {
                    text += "\nLatest: \(latest.track) by \(latest.artist) at \(stamp(latest.listenedAt))."
                }
                return Self.toolResult(text)

            case .topArtists, .topTracks:
                let range = try statsRange(arguments["range"])
                let count = min(50, max(1, arguments["count"] as? Int ?? 10))
                let text = tool == .topArtists
                    ? try await history.topArtists(range, count: count, now: now).sentence(range: range)
                    : try await history.topTracks(range, count: count, now: now).sentence(range: range)
                return Self.toolResult(text)

            case .listenCount:
                let count = try await client.listenCount(user: user)
                return Self.toolResult("\(user) has \(count) listens on ListenBrainz.")
            }
        } catch let error as ArgumentError {
            return Self.toolResult(error.message, isError: true)
        } catch {
            return Self.toolResult("ListenBrainz didn't answer: \(error)", isError: true)
        }
    }

    // MARK: Arguments

    struct ArgumentError: Error {
        let message: String
    }

    private func statsRange(_ value: Any?) throws -> StatsRange {
        guard let value else { return .thisWeek }
        guard let string = value as? String, let range = StatsRange(rawValue: string) else {
            throw ArgumentError(message: "range must be one of \(StatsRange.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return range
    }

    /// A date-time, or a plain date taken as the start (or end) of that day.
    private func date(_ value: Any?, endOfDay: Bool) throws -> Date? {
        guard let value else { return nil }
        guard let string = value as? String else { throw ArgumentError(message: "Dates must be strings.") }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: string) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: string) { return date }
        // A date-time without a time zone is local time.
        let local = DateFormatter()
        local.calendar = configuration.calendar
        local.timeZone = configuration.calendar.timeZone
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: string) { return date }
        }
        let day = try dayDate(string, now: configuration.now())
        guard endOfDay else { return day }
        return configuration.calendar.date(byAdding: .day, value: 1, to: day)!.addingTimeInterval(-1)
    }

    private func dayDate(_ string: String, now: Date) throws -> Date {
        let calendar = configuration.calendar
        switch string.lowercased() {
        case "today": return calendar.startOfDay(for: now)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        default:
            let parts = string.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { throw ArgumentError(message: "day must be YYYY-MM-DD, \"today\" or \"yesterday\".") }
            return date
        }
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = configuration.calendar
        formatter.timeZone = configuration.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: JSON-RPC

    private static func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
