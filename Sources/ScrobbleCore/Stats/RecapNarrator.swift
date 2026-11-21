import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One friendly sentence about a week of listening, written on the device by
/// Apple's on-device model. Only the counts in `ListeningSummary` go into
/// the prompt, and nothing leaves the device. Returns nil wherever the
/// model isn't there (before iOS 26 / macOS 26, Apple Intelligence off, an
/// unsupported device); the recap shows the plain counts either way.
public enum RecapNarrator {
    public static func sentence(for summary: ListeningSummary, period: String) async -> String? {
        guard summary.plays > 0 else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let session = LanguageModelSession(instructions: """
                You write one short, warm sentence (at most 25 words) about someone's music listening, \
                for a recap card in a scrobbling app. Use only the facts given. No emoji, no hashtags, \
                no quotation marks, no questions.
                """)
            do {
                let response = try await session.respond(to: prompt(for: summary, period: period))
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                Log.capture.info("On-device recap sentence unavailable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        #endif
        return nil
    }

    static func prompt(for summary: ListeningSummary, period: String) -> String {
        var lines = ["Period: \(period). Tracks played: \(summary.plays)."]
        if !summary.topArtists.isEmpty {
            lines.append("Most played artists: "
                + summary.topArtists.prefix(5).map { "\($0.name) (\($0.listens))" }.joined(separator: ", ") + ".")
        }
        if !summary.topTracks.isEmpty {
            lines.append("Most played tracks: "
                + summary.topTracks.prefix(3).map { "\($0.track) by \($0.artist) (\($0.listens))" }
                    .joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}
